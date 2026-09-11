"""Deterministic artifacts for synthetic MSI boundary scenarios only."""

from collections import Counter
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import shlex

from . import __version__
from .artifacts import BundleDigests
from .msi_scenario import MSIScenarioResult, run_msi_scenario
from .publication import publish_files


SOURCE_DOCUMENTS = (
    "docs/evidence/oled-protection/firmware-boundary.md",
    "tools/pontusm-sim/docs/msi-source-map.md",
)
TIMING_CAVEAT = (
    "Timing is a semantic reconstruction, not cycle-accurate firmware timing: "
    "counter > N uses (N + 1) seconds; strict >500 and >550 tick guards use "
    "501 and 551 ms; blocking 500-tick waits use 500 ms. CPU and polling latency "
    "are not modeled. Deadlines precede actions at equal times; actions keep list order."
)
LATENT_WARNING = (
    "Latent EL is unreachable in shipped FW.028/FW.031/FW.035/FW.041 control flow. "
    "The explicit analysis entry assumes initial power-low and video-muted conditions; "
    "it is not a production monitor action."
)
CAVEATS = (
    "No real MSI capture or hardware validation is represented. Inputs are synthetic scenario values.",
    TIMING_CAVEAT,
    "OFF/EL electrical compensation and detector internals remain unavailable below the proprietary panel boundary.",
    "Source-document references identify the research basis; this run does not authenticate firmware archives or source documents.",
    "The model targets FW.041; the research records unchanged panel ABI, sensing waits, and reachability across FW.028/FW.031/FW.035/FW.041.",
    "MSI register payloads are not mapped to PontusM internal fields. Configuration readback annotations are contracts, not observed successful replies.",
)


def _json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")


def _command(arguments):
    if not isinstance(arguments, tuple) or any(
            not isinstance(item, str) or not item or "\n" in item or "\r" in item
            for item in arguments):
        raise ValueError("command must be a tuple of nonempty single-line strings")
    if not arguments:
        return ("python3", "-m", "pontusm_sim", "msi-run", "<scenario-json>",
                "--output", "<output-directory>")
    normalized = []
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


def write_msi_bundle(
    result: MSIScenarioResult,
    output_directory: str | Path,
    *,
    command: tuple[str, ...] = (),
    artifact_epoch: str = "2026-09-10T00:00:00Z",
) -> BundleDigests:
    """Validate and render all bytes before creating the destination directory.

    Replaying the immutable source document validates caller-created results as
    well as loaded ones. The manifest hashes the two other artifacts; its own
    digest is returned to the caller, avoiding a self-referential manifest hash.
    """
    if not isinstance(result, MSIScenarioResult):
        raise ValueError("result must be an MSIScenarioResult")
    if run_msi_scenario(result.scenario) != result:
        raise ValueError("result does not match its validated scenario")
    if (not isinstance(artifact_epoch, str) or not artifact_epoch.strip()
            or "\n" in artifact_epoch or "\r" in artifact_epoch):
        raise ValueError("artifact_epoch must be a nonempty single-line string")
    command = _command(command)
    latent = result.final_state.unreachable_in_shipped_control_flow
    caveats = CAVEATS + ((LATENT_WARNING,) if latent else ())
    events = []
    for event in result.events:
        row = asdict(event)
        row["detail"] = dict(row["detail"])
        row["unreachable_in_shipped_control_flow"] = latent
        row["timing_basis"] = "semantic-reconstruction"
        events.append(row)
    event_bytes = b"".join(_json_bytes(row) for row in events)
    counts = dict(sorted(Counter(event.kind for event in result.events).items()))
    # Escape arbitrary scenario names without allowing them to add report lines.
    name = json.dumps(result.name, ensure_ascii=True).replace("`", "\\`")
    lines = [
        "# MSI Panel-Care Boundary Scenario", "",
        f"- Scenario: `{name}`",
        f"- Input SHA-256: `{result.scenario_sha256}`",
        f"- Firmware semantic target: FW.{result.scenario.firmware}",
        f"- Artifact epoch: {artifact_epoch}",
        f"- Events: {len(events)}; final semantic time: {result.final_state.time_ms} ms",
        f"- Final state: {result.final_state.state}",
        "- Evidence: msi-source-translated", "",
        "## Interpretation", "",
        *[f"- {caveat}" for caveat in caveats], "",
        "## Event coverage", "",
        "| Event | Count |", "| --- | ---: |",
        *[f"| {kind} | {count} |" for kind, count in counts.items()], "",
        "## Source documents", "",
        *[f"- `{source}`" for source in SOURCE_DOCUMENTS], "",
        "## Reproduction", "", f"    {shlex.join(command)}", "",
    ]
    report_bytes = "\n".join(lines).encode("utf-8")
    contents = {"events.jsonl": event_bytes, "report.md": report_bytes}
    manifest = {
        "schema_version": 1,
        "tool_version": __version__,
        "created_at": artifact_epoch,
        "scenario": {"name": result.name, "sha256": result.scenario_sha256,
                     "input": json.loads(result.scenario.document)},
        "firmware": result.scenario.firmware,
        "evidence": "msi-source-translated",
        "timing_basis": "semantic-reconstruction",
        "unreachable_in_shipped_control_flow": latent,
        "source_documents": list(SOURCE_DOCUMENTS),
        "fidelity_caveats": list(caveats),
        "command": list(command),
        "event_counts": counts,
        "final_state": asdict(result.final_state),
        "configured_settings": asdict(result.settings),
        "vrr_active": result.vrr_active,
        "artifact_sha256": {name: hashlib.sha256(raw).hexdigest()
                            for name, raw in contents.items()},
    }
    contents["manifest.json"] = _json_bytes(manifest)
    publish_files(contents, output_directory)
    return BundleDigests(files={name: hashlib.sha256(raw).hexdigest()
                                for name, raw in contents.items()})
