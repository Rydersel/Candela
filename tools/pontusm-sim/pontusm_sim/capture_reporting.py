"""Offline comparison bundles: validate every input before rendering or writing.

The public boundary takes paths so all reported hashes describe bytes actually
loaded in this invocation. Archives are verified afresh, never through the CLI's
scenario cache. Each orbit predicate receives only its declared release's data.
"""

from collections import Counter
import csv
from dataclasses import fields, is_dataclass, replace
from enum import Enum
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
from typing import Mapping

from . import __version__
from .artifacts import BundleDigests
from .capture_compare import AlignmentRow, ComparisonStatus, compare_capture, load_hypotheses
from .observations import load_capture
from .publication import publish_tree
from .source import verify_archive


CATEGORIES = ("direct", "proxy", "context-only", "unavailable")
CAVEATS = (
    "Capture hashes bind supplied bytes; they do not establish physical provenance or real MSI validation.",
    "Consistent means the predeclared predicate survives this evidence, not implementation identity.",
    "Normal orbit equality is non-discriminating between PontusM v18, v20, and v22.",
    "Calibration is fixed by the manifest: swap axes first, then apply x/y signs. No fitting or time warping is performed.",
    "Raw MSI registers and OFF/EL events are context-only; proprietary detector and electrical compensation internals remain unavailable.",
    "No QD state predicates or QD scenarios are selected by hypothesis schema 1; scalar predicates compare observations directly.",
    "First contradiction follows hypothesis document order, then comparison-point order; separate trials have no shared chronology.",
    "In comparison.json, surviving_indices applies only to orbit_sequence; its empty array for other predicate types means not applicable, not zero orbit candidates.",
    "This tool reads local data only and does not contact hardware, use the network, or execute archive content.",
)


def _plain(value):
    if isinstance(value, Enum):
        return value.value
    if is_dataclass(value):
        return {field.name: _plain(getattr(value, field.name)) for field in fields(value)}
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_plain(item) for item in value]
    return value


def _json_bytes(value):
    return (json.dumps(_plain(value), sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")


def _literal(value):
    # Keep user labels and notes on one report line and out of Markdown syntax.
    return json.dumps(_plain(value), ensure_ascii=True).replace("`", "\\u0060")


def _csv_text(value: str) -> str:
    """Keep free text from being interpreted as spreadsheet formulas.

    JSON alignments retain the exact text; this apostrophe belongs only to the
    spreadsheet-facing CSV representation, including negative observed strings.
    """
    if value.startswith(("\t", "\r", "\n")) or value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def write_capture_comparison(
    capture_path: str | Path,
    hypotheses_path: str | Path,
    output_directory: str | Path,
    *,
    archive_18: str | Path | None = None,
    archive_20: str | Path | None = None,
    archive_22: str | Path | None = None,
    artifact_epoch: str = "2026-09-10T00:00:00Z",
) -> BundleDigests:
    """Write manifest.json, comparison.json, aligned.csv, and report.md.

    All validation and serialization completes before staging. The destination
    must be absent; the complete staged directory is atomically published using
    a native no-replace rename, with no non-atomic fallback.
    Missing archives yield release-specific indeterminate orbit results. The
    returned manifest digest avoids a self-referential hash inside the manifest.
    """
    destination = Path(output_directory).absolute()
    if os.path.lexists(destination):
        raise ValueError(f"output destination already exists: {destination}")
    if (type(artifact_epoch) is not str or not artifact_epoch.strip()
            or "\n" in artifact_epoch or "\r" in artifact_epoch):
        raise ValueError("artifact_epoch must be a nonempty single-line string")
    capture_path, hypotheses_path = Path(capture_path).absolute(), Path(hypotheses_path).absolute()
    capture = load_capture(capture_path)
    hypotheses = load_hypotheses(hypotheses_path)
    archives = {version: Path(path).absolute() for version, path in
                ((18, archive_18), (20, archive_20), (22, archive_22)) if path is not None}
    sources = {version: verify_archive(path, version) for version, path in archives.items()}
    baseline = compare_capture(capture, hypotheses)
    by_version = {version: compare_capture(capture, hypotheses, orbit_tables=source.orbit_tables,
                                         orbit_table_version=source.version)
                  for version, source in sources.items()}
    results, alignments = [], []
    for index, predicate in enumerate(hypotheses.hypotheses):
        evaluation = baseline
        missing = None
        if predicate["type"] == "orbit_sequence":
            version = predicate["version"]
            name = "orbit_table" if predicate["orbit"] == "normal" else "orbit_table_32x16"
            if version not in sources:
                missing = f"authenticated PontusM v{version} {name} unavailable: --archive-{version} was not supplied"
            elif name not in sources[version].orbit_tables:
                missing = f"authenticated PontusM v{version} {name} unavailable in the verified archive"
            else:
                evaluation = by_version[version]
        result = evaluation.results[index]
        points = [row for row in evaluation.alignments if row.hypothesis_id == result.id]
        if missing is not None:
            result = replace(result, category="unavailable", status=ComparisonStatus.INDETERMINATE,
                             reason=missing, surviving_indices=())
            points = [AlignmentRow(result.id, result.trial, result.evidence_sequences,
                                   "", missing, ComparisonStatus.INDETERMINATE)]
        results.append(result)
        alignments.extend(points)

    referenced = {(r.trial, sequence) for r in results for sequence in r.evidence_sequences}
    counts = {
        "observations": len(capture.observations),
        "referenced_observations": len(referenced),
        "unreferenced_observations": len(capture.observations) - len(referenced),
        "by_channel": dict(sorted(Counter(r.channel for r in capture.observations).items())),
        "by_quality": dict(sorted(Counter(r.quality for r in capture.observations).items())),
        "hypotheses_by_category": {category: sum(r.category == category for r in results)
                                   for category in CATEGORIES},
        "hypotheses_by_status": {status.value: sum(r.status == status for r in results)
                                 for status in ComparisonStatus},
        "alignment_points": len(alignments),
    }
    first = next((row for row in alignments if row.status == ComparisonStatus.CONTRADICTED), None)
    comparison = {
        "schema_version": 1, "capture_id": capture.manifest.capture_id,
        "hypotheses_sha256": hypotheses.sha256,
        "hypotheses": json.loads(hypotheses.source_bytes),
        "results": [{**_plain(result), "evidence_count": len(result.evidence_sequences)} for result in results],
        "alignments": _plain(alignments),
        "evidence_counts": counts, "first_contradiction": _plain(first),
    }
    command = ["python3", "-m", "pontusm_sim", "compare-capture", str(capture_path),
               "--hypotheses", str(hypotheses_path)]
    for version, path in archives.items():
        command.extend((f"--archive-{version}", str(path)))
    command.extend(("--output", "<output-directory>", f"--artifact-epoch={artifact_epoch}"))
    provenance = {str(version): {
        "version": int(source.version), "outer_sha256": source.outer_sha256,
        "archive_members": list(source.archive_members), "archive_hashes": dict(source.archive_hashes),
        "qd_source_member": source.qd_source_member, "qd_source_sha256": source.qd_source_sha256,
        "orbit_source_member": source.orbit_source_member, "orbit_source_sha256": source.orbit_source_sha256,
        "orbit_counts": dict(source.orbit_counts), "warnings": list(source.warnings),
    } for version, source in sources.items()}
    csv_stream = io.StringIO(newline="")
    writer = csv.writer(csv_stream, lineterminator="\n", quoting=csv.QUOTE_ALL)
    writer.writerow(("hypothesis_id", "trial", "sequences", "observed", "expected", "status"))
    for row in alignments:
        writer.writerow(tuple(_csv_text(value) for value in
            (row.hypothesis_id, row.trial, json.dumps(row.sequences),
             row.observed, row.expected, row.status.value)))
    lines = ["# Capture comparison", "", f"Capture: `{_literal(capture.manifest.capture_id)}`",
             f"Artifact epoch: {artifact_epoch}", "",
             f"Capture manifest SHA-256: `{capture.manifest_sha256}`",
             f"Observation SHA-256: `{capture.observations_sha256}`",
             f"Hypotheses SHA-256: `{hypotheses.sha256}`",
             f"Fixed calibration: `{_literal(capture.manifest.calibration)}`", "",
             "## Evidence coverage", "", f"`{_literal(counts)}`", "",
             "Evidence counts count referenced trial/sequence pairs once across hypotheses; per-hypothesis counts include all selected evidence regardless of accepted quality.", "",
             f"First contradiction: `{_literal(first)}`", ""]
    for category in CATEGORIES:
        lines.extend((f"## {category}", ""))
        selected = [result for result in results if result.category == category]
        if not selected:
            lines.extend(("No hypotheses in this section.", ""))
        for result in selected:
            survivor_text = (f"`{_literal(result.surviving_indices)}`"
                             if result.type == "orbit_sequence" else "not applicable")
            lines.extend((f"- `{_literal(result.id)}`: {result.status.value}; {_literal(result.reason)}",
                f"  Evidence ({len(result.evidence_sequences)}): `{_literal(result.evidence_sequences)}`; surviving indices: {survivor_text}.",
                *[f"  {_literal(note)}" for note in result.notes], ""))
    lines.extend(("Proprietary panel detector internals, OFF/EL electrical sensing, and compensation maps are unavailable.", "",
                  "## Source provenance", "", f"`{_literal(provenance)}`", "",
                  "## Interpretation", "", *[f"- {caveat}" for caveat in CAVEATS], "",
                  "## Reproduction", "", f"    {shlex.join(command)}", ""))
    contents = {"comparison.json": _json_bytes(comparison),
                "aligned.csv": csv_stream.getvalue().encode("utf-8"),
                "report.md": "\n".join(lines).encode("utf-8")}
    manifest = {
        "schema_version": 1, "tool_version": __version__, "created_at": artifact_epoch,
        "capture": {"id": capture.manifest.capture_id, "manifest_sha256": capture.manifest_sha256,
                    "observations_sha256": capture.observations_sha256, "notes": capture.manifest.notes},
        "device": dict(capture.manifest.device), "timebase": dict(capture.manifest.timebase),
        "calibration": dict(capture.manifest.calibration), "hypotheses_sha256": hypotheses.sha256,
        "sources": provenance, "selected_source_versions": sorted({p["version"] for p in
                    hypotheses.hypotheses if p["type"] == "orbit_sequence"}),
        "verified_source_versions": sorted(sources), "selected_scenarios": [],
        "evidence": {"capture": "observed", "orbit_predictions": "pontusm-source-translated",
                     "panel_internals": "unavailable"},
        "evidence_counts": counts, "fidelity_caveats": CAVEATS, "command": command,
        "artifact_sha256": {name: hashlib.sha256(raw).hexdigest() for name, raw in contents.items()},
    }
    contents["manifest.json"] = _json_bytes(manifest)
    def render(staging: Path) -> None:
        staging.mkdir()
        for name, raw in contents.items():
            (staging / name).write_bytes(raw)

    publish_tree(destination, render)
    return BundleDigests(files={name: hashlib.sha256(raw).hexdigest() for name, raw in contents.items()})
