"""Command-line interface for the research-only PontusM simulator."""

from __future__ import annotations

import argparse
from dataclasses import fields, is_dataclass
from enum import Enum
from functools import lru_cache, partial
import json
from pathlib import Path
import sys
from typing import Any, Mapping

from .model import QDModel
from .publication import publish_tree
from .reporting import write_result_bundle
from .scenario import ScenarioResult, load_scenario, run_scenario
from .types import AlgorithmVersion


EXPECTED_ARCHIVE_HASHES = {
    AlgorithmVersion.V18: "057d43ac370eefc4ad4a5d0db9b2c148cb2144c9cc7e8313bcc3cdfda7b5fbb6",
    AlgorithmVersion.V20: "203116537c27d4368dee1e22a7fa5c88a11d727cdda3e024785ce80d4601bee7",
    AlgorithmVersion.V22: "517d29ac88ad5932871a5f4b4fb3f91bb410aae2af89b62d44a53b4decd0db19",
}
SCENARIO_DIRECTORY = Path(__file__).resolve().parent.parent / "scenarios"


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _plain(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if is_dataclass(value):
        return {item.name: _plain(getattr(value, item.name)) for item in fields(value)}
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))}
    if isinstance(value, (tuple, list)):
        return [_plain(item) for item in value]
    return value


@lru_cache(maxsize=6)
def _verified_source(archive: str, version: AlgorithmVersion):
    from .source import verify_archive

    return verify_archive(archive, version)


def _source_hashes(
    version: AlgorithmVersion, archive: str | None
) -> tuple[dict[str, str], tuple[str, ...]]:
    if archive is None:
        return (
            {"expected-official-archive-unverified": EXPECTED_ARCHIVE_HASHES[version]},
            (
                "No archive was supplied for this run; the manifest records the expected official archive digest but source verification was not performed.",
            ),
        )
    verification = _verified_source(str(Path(archive).resolve()), version)
    return (
        {
            Path(archive).name: verification.outer_sha256,
            Path(verification.qd_source_member).name: verification.qd_source_sha256,
            Path(verification.orbit_source_member).name: verification.orbit_source_sha256,
        },
        (),
    )


def _run_one(
    scenario_path: str | Path,
    version: AlgorithmVersion,
    output: Path,
    archive: str | None,
    command: tuple[str, ...],
) -> ScenarioResult:
    scenario = load_scenario(scenario_path)
    hashes, caveats = _source_hashes(version, archive)
    result = run_scenario(QDModel(version), scenario)
    write_result_bundle(
        result,
        output,
        source_hashes=hashes,
        command=command,
        fidelity_caveats=caveats,
    )
    if result.name == "rotation-orbit" and archive is not None:
        _write_bip_bundle(output, archive, version)
    return result


def _write_bip_bundle(
    output: Path, archive: str, version: AlgorithmVersion
) -> None:
    from .bip import BIPModel, DEFAULT_INTERVAL_TICKS

    source = _verified_source(str(Path(archive).resolve()), version)
    tables = source.orbit_tables
    model = BIPModel(
        tables["orbit_table"],
        tables["orbit_table_ew"],
        rotated=tables.get("orbit_table_32x16"),
        version=version,
    )
    events = list(model.set_enabled(True))
    events.extend(model.step(DEFAULT_INTERVAL_TICKS * 3))
    if version is not AlgorithmVersion.V18:
        events.extend(model.set_rotation(True))
        events.extend(model.step(DEFAULT_INTERVAL_TICKS * 3))
    if version is AlgorithmVersion.V22:
        events.extend(model.notify_frc_unmute(1, 0))
    events.append(model.engineering_verify(len(tables["orbit_table_ew"]) - 1))
    payload = {
        "schema_version": 1,
        "model_version": int(version),
        "source_archive_sha256": source.outer_sha256,
        "table_counts": dict(source.orbit_counts),
        "events": [_plain(event) for event in events],
        "final_state": _plain(model.snapshot()),
        "caveat": "Coordinates were parsed at runtime from the verified official archive and are not embedded in this repository.",
    }
    output.mkdir(parents=True, exist_ok=True)
    (output / "bip.json").write_bytes(_json_bytes(payload))
    lines = [
        "# PontusM BIP / Pixel-Shift Trace",
        "",
        f"- Source version: {int(version)}",
        f"- Official archive SHA-256: `{source.outer_sha256}`",
        f"- Events: {len(events)}",
        f"- Final table: `{model.snapshot().active_table.value}`",
        f"- Final index: {model.snapshot().index}",
        "",
        "The coordinates were imported from the verified archive at runtime; this report contains only the exercised positions and does not redistribute the source table.",
    ]
    (output / "bip.md").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def _comparison(old: ScenarioResult, new: ScenarioResult) -> dict[str, Any]:
    old_samples = {int(item["tick"]): item for item in old.samples}
    new_samples = {int(item["tick"]): item for item in new.samples}
    differences: list[dict[str, Any]] = []
    shared_differences: list[dict[str, Any]] = []
    largest: dict[str, Any] | None = None
    availability_metrics = {"retention_available", "fcn_available"}
    for tick in sorted(set(old_samples) & set(new_samples)):
        for metric in sorted(set(old_samples[tick]) - {"tick", "phase"}):
            before = old_samples[tick][metric]
            after = new_samples[tick][metric]
            if before == after:
                continue
            difference = {
                "tick": tick,
                "metric": metric,
                f"version_{old.version}": before,
                f"version_{new.version}": after,
            }
            differences.append(difference)
            if (
                metric not in availability_metrics
                and before is not None
                and after is not None
            ):
                shared_differences.append(difference)
            if (
                isinstance(before, (int, float))
                and not isinstance(before, bool)
                and isinstance(after, (int, float))
                and not isinstance(after, bool)
            ):
                magnitude = abs(after - before)
                if largest is None or magnitude > largest["magnitude"]:
                    largest = {**difference, "magnitude": magnitude}
    return {
        "schema_version": 1,
        "scenario": old.name,
        "versions": [old.version, new.version],
        "ticks": old.tick_count,
        "difference_count_at_recorded_ticks": len(differences),
        "first_difference": differences[0] if differences else None,
        "first_shared_difference": (
            shared_differences[0] if shared_differences else None
        ),
        "largest_numeric_difference": largest,
        "caveat": "This compares published PontusM host-side source models, not MSI MAG 341CQP firmware or unavailable OFF/EL electrical compensation.",
    }


def _write_comparison(
    output: Path,
    old: ScenarioResult,
    new: ScenarioResult,
    *,
    stem: str = "comparison",
) -> None:
    comparison = _comparison(old, new)
    output.mkdir(parents=True, exist_ok=True)
    (output / f"{stem}.json").write_bytes(_json_bytes(comparison))
    first = comparison["first_difference"]
    first_shared = comparison["first_shared_difference"]
    largest = comparison["largest_numeric_difference"]
    lines = [
        "# PontusM Version Comparison",
        "",
        f"- Versions: {old.version} -> {new.version}",
        f"- Scenario: `{old.name}`",
        f"- Simulated ticks: {old.tick_count}",
        f"- Differences at recorded ticks: {comparison['difference_count_at_recorded_ticks']}",
        f"- First difference: `{json.dumps(first, sort_keys=True)}`",
        f"- First shared-field difference: `{json.dumps(first_shared, sort_keys=True)}`",
        f"- Largest numeric difference: `{json.dumps(largest, sort_keys=True)}`",
        "",
        "This compares published PontusM host-side source models. It is not a claim about MSI MAG 341CQP firmware, and OFF/EL electrical compensation remains unavailable.",
    ]
    (output / f"{stem}.md").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pontusm-sim",
        description="Research-only Samsung PontusM OLED protection simulator",
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(
        dest="command", required=True,
        parser_class=partial(argparse.ArgumentParser, allow_abbrev=False),
    )
    verify = commands.add_parser("verify-source", help="verify and inspect an official source archive")
    verify.add_argument("archive")
    verify.add_argument("--version", required=True, choices=("18", "20", "22"))

    run = commands.add_parser("run", help="run one scenario")
    run.add_argument("scenario")
    run.add_argument("--version", required=True, choices=("18", "20", "22"))
    run.add_argument("--output", required=True)
    run.add_argument("--archive")

    msi = commands.add_parser(
        "msi-run", help="run one offline MSI boundary scenario",
        description="Run an offline MSI boundary semantic reconstruction; no monitor connection.",
    )
    msi.add_argument("scenario")
    msi.add_argument("--output", required=True)
    msi.add_argument("--artifact-epoch", default="2026-09-10T00:00:00Z")

    capture = commands.add_parser(
        "compare-capture", help="compare an offline capture against predeclared hypotheses",
        description="Compare validated local evidence offline; no camera, monitor, or network connection.",
    )
    capture.add_argument("capture")
    capture.add_argument("--hypotheses", required=True)
    capture.add_argument("--archive-18")
    capture.add_argument("--archive-20")
    capture.add_argument("--archive-22")
    capture.add_argument("--output", required=True)
    capture.add_argument("--artifact-epoch", default="2026-09-10T00:00:00Z")

    compare = commands.add_parser("compare", help="compare one scenario across versions")
    compare.add_argument("scenario")
    compare.add_argument("--output", required=True)
    compare.add_argument("--archive-18")
    compare.add_argument("--archive-20")
    compare.add_argument("--archive-22")
    compare.add_argument("--from-version", choices=("18", "20", "22"), default="18")
    compare.add_argument("--to-version", choices=("18", "20", "22"), default="20")

    all_parser = commands.add_parser("run-all", help="run every built-in scenario for all versions")
    all_parser.add_argument("--output", required=True)
    all_parser.add_argument("--archive-18")
    all_parser.add_argument("--archive-20")
    all_parser.add_argument("--archive-22")
    return parser


def _stable_command(arguments: tuple[str, ...]) -> tuple[str, ...]:
    """Build a portable module command with stable destination metadata."""
    normalized = ["python3", "-m", "pontusm_sim"]
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--output":
            if index + 1 >= len(arguments):
                raise ValueError("--output needs a destination")
            normalized.extend(("--output", "<output-directory>"))
            index += 2
        elif argument.startswith("--output="):
            normalized.extend(("--output", "<output-directory>"))
            index += 1
        else:
            normalized.append(argument)
            index += 1
    return tuple(normalized)


def _verification_summary(verification: Any) -> dict[str, Any]:
    """Return authenticated source facts without redistributing orbit tables."""
    return {
        "version": int(verification.version),
        "outer_sha256": verification.outer_sha256,
        "archive_members": list(verification.archive_members),
        "archive_hashes": dict(verification.archive_hashes),
        "qd_source_member": verification.qd_source_member,
        "qd_source_sha256": verification.qd_source_sha256,
        "orbit_source_member": verification.orbit_source_member,
        "orbit_source_sha256": verification.orbit_source_sha256,
        "constants": dict(verification.constants),
        "orbit_counts": dict(verification.orbit_counts),
        "orbit_bounds": _plain(verification.orbit_bounds),
        "warnings": list(verification.warnings),
    }


def main(arguments: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(arguments)
    command = _stable_command(
        tuple(sys.argv[1:] if arguments is None else arguments)
    )
    try:
        if args.command == "verify-source":
            result = _verified_source(
                str(Path(args.archive).resolve()), AlgorithmVersion.parse(args.version)
            )
            sys.stdout.write(
                json.dumps(_verification_summary(result), sort_keys=True, indent=2)
                + "\n"
            )
            return 0
        if args.command == "run":
            output = Path(args.output)
            publish_tree(
                output,
                lambda staging: _run_one(
                    args.scenario,
                    AlgorithmVersion.parse(args.version),
                    staging,
                    args.archive,
                    command,
                ),
            )
            print(output)
            return 0
        if args.command == "msi-run":
            from .msi_reporting import write_msi_bundle
            from .msi_scenario import load_msi_scenario, run_msi_scenario

            scenario = load_msi_scenario(args.scenario)
            result = run_msi_scenario(scenario)
            output = Path(args.output)
            msi_command = (
                "python3", "-m", "pontusm_sim", "msi-run", args.scenario,
                "--output", "<output-directory>", f"--artifact-epoch={args.artifact_epoch}",
            )
            write_msi_bundle(result, output, command=msi_command,
                             artifact_epoch=args.artifact_epoch)
            print(output)
            return 0
        if args.command == "compare-capture":
            from .capture_reporting import write_capture_comparison

            output = Path(args.output)
            write_capture_comparison(args.capture, args.hypotheses, output,
                                     archive_18=args.archive_18, archive_20=args.archive_20,
                                     archive_22=args.archive_22,
                                     artifact_epoch=args.artifact_epoch)
            print(output)
            return 0
        if args.command == "compare":
            output = Path(args.output)
            old_version = AlgorithmVersion.parse(args.from_version)
            new_version = AlgorithmVersion.parse(args.to_version)
            if old_version == new_version:
                raise ValueError("comparison versions must differ")

            def render_comparison(staging: Path) -> None:
                old = _run_one(
                    args.scenario,
                    old_version,
                    staging / f"v{int(old_version)}",
                    getattr(args, f"archive_{int(old_version)}"),
                    command,
                )
                new = _run_one(
                    args.scenario,
                    new_version,
                    staging / f"v{int(new_version)}",
                    getattr(args, f"archive_{int(new_version)}"),
                    command,
                )
                _write_comparison(staging, old, new)

            publish_tree(output, render_comparison)
            print(output)
            return 0
        if args.command == "run-all":
            output = Path(args.output)

            def render_all(staging: Path) -> None:
                index: list[dict[str, Any]] = []
                for scenario_path in sorted(SCENARIO_DIRECTORY.glob("*.json")):
                    destination = staging / scenario_path.stem
                    results = {
                        version: _run_one(
                            scenario_path,
                            version,
                            destination / f"v{int(version)}",
                            getattr(args, f"archive_{int(version)}"),
                            command,
                        )
                        for version in AlgorithmVersion
                    }
                    _write_comparison(
                        destination,
                        results[AlgorithmVersion.V18],
                        results[AlgorithmVersion.V20],
                    )
                    _write_comparison(
                        destination,
                        results[AlgorithmVersion.V20],
                        results[AlgorithmVersion.V22],
                        stem="comparison-v20-v22",
                    )
                    index.append(
                        {
                            "name": scenario_path.stem,
                            "ticks": results[AlgorithmVersion.V18].tick_count,
                            "path": scenario_path.stem,
                        }
                    )
                staging.mkdir(parents=True, exist_ok=True)
                (staging / "index.json").write_bytes(
                    _json_bytes(
                        {
                            "schema_version": 1,
                            "scenarios": index,
                            "versions": [18, 20, 22],
                        }
                    )
                )

            publish_tree(output, render_all)
            print(output)
            return 0
    except (OSError, TypeError, ValueError) as error:
        print(f"pontusm-sim: {error}", file=sys.stderr)
        return 2
    parser.error("unknown command")
    return 2
