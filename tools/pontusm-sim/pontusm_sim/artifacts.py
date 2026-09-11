"""Deterministic, provenance-rich output bundles for simulator runs."""

from __future__ import annotations

import csv
import hashlib
import io
import json
import math
import os
import re
import shlex
from dataclasses import dataclass
from typing import Iterable, Mapping

from . import __version__
from .publication import publish_files
from .types import AlgorithmVersion


Scalar = str | int | float | bool | None

_ARTIFACT_NAMES = (
    "manifest.json",
    "trace.jsonl",
    "summary.csv",
    "regions.csv",
    "report.md",
)
_SHA256_PATTERN = re.compile(r"[0-9a-fA-F]{64}")
_PONTUSM_CAVEAT = (
    "This is a PontusM source reconstruction and not an implementation claim "
    "about the MSI MAG 341CQP."
)
_OFF_EL_CAVEAT = (
    "OFF/EL electrical compensation remains unavailable because the required "
    "panel-side implementation is outside the published source boundary."
)


@dataclass(frozen=True)
class RunMetadata:
    """Caller-supplied provenance that must not depend on the host environment."""

    created_at: str
    model_version: AlgorithmVersion | int
    scenario_name: str
    scenario_sha256: str
    source_archive_hashes: Mapping[str, str]
    command: tuple[str, ...] = ()
    fidelity_caveats: tuple[str, ...] = ()
    schema_version: int = 1
    tool_version: str = __version__


@dataclass(frozen=True)
class ArtifactConfig:
    """Stable column selection and naming for a bundle."""

    summary_metrics: tuple[str, ...]
    region_value_name: str = "region_value"


@dataclass(frozen=True)
class TickRecord:
    """One tick's scalar summary and optional sparse diagnostic data."""

    tick: int
    phase: str
    metrics: Mapping[str, Scalar]
    event: str | None = None
    checkpoint: str | None = None
    regions: tuple[int, ...] | None = None


@dataclass(frozen=True)
class BundleDigests:
    """SHA-256 digest of every emitted artifact, keyed by file name."""

    files: Mapping[str, str]


def write_bundle(
    output_directory: str | os.PathLike[str],
    metadata: RunMetadata,
    config: ArtifactConfig,
    records: Iterable[TickRecord],
) -> BundleDigests:
    """Validate and write one deterministic five-file artifact bundle."""

    validated_metadata = _validate_metadata(metadata)
    _validate_config(config)
    materialized_records = tuple(records)
    _validate_records(materialized_records, config)

    aggregates = _aggregates(materialized_records, config.summary_metrics)
    caveats = (_PONTUSM_CAVEAT, _OFF_EL_CAVEAT, *metadata.fidelity_caveats)
    contents = {
        "manifest.json": _json_document(
            {
                "aggregates": aggregates,
                "command": list(metadata.command),
                "config": {
                    "region_value_name": config.region_value_name,
                    "summary_metrics": list(config.summary_metrics),
                    "trace_policy": "events-and-checkpoints",
                },
                "created_at": metadata.created_at,
                "fidelity_caveats": list(caveats),
                "model_version": int(validated_metadata),
                "scenario": {
                    "name": metadata.scenario_name,
                    "sha256": metadata.scenario_sha256.lower(),
                },
                "schema_version": metadata.schema_version,
                "source_archive_hashes": {
                    name: digest.lower()
                    for name, digest in sorted(metadata.source_archive_hashes.items())
                },
                "tool_version": metadata.tool_version,
            }
        ),
        "trace.jsonl": _trace_jsonl(materialized_records),
        "summary.csv": _summary_csv(materialized_records, config.summary_metrics),
        "regions.csv": _regions_csv(materialized_records, config.region_value_name),
        "report.md": _report(
            metadata,
            validated_metadata,
            config,
            aggregates,
            caveats,
        ),
    }

    publish_files(contents, output_directory)

    return BundleDigests(
        files={
            name: hashlib.sha256(contents[name]).hexdigest()
            for name in _ARTIFACT_NAMES
        }
    )


def _validate_metadata(metadata: RunMetadata) -> AlgorithmVersion:
    if not isinstance(metadata, RunMetadata):
        raise TypeError("metadata must be RunMetadata")
    if not isinstance(metadata.created_at, str) or not metadata.created_at:
        raise ValueError("created_at must be supplied by the caller")
    if not isinstance(metadata.scenario_name, str) or not metadata.scenario_name:
        raise ValueError("scenario_name must be a non-empty string")
    _validate_sha256("scenario_sha256", metadata.scenario_sha256)
    if not metadata.source_archive_hashes:
        raise ValueError("source_archive_hashes must not be empty")
    for name, digest in metadata.source_archive_hashes.items():
        if not isinstance(name, str) or not name:
            raise ValueError("source archive names must be non-empty strings")
        _validate_sha256(f"source archive {name!r}", digest)
    if (
        not isinstance(metadata.schema_version, int)
        or isinstance(metadata.schema_version, bool)
        or metadata.schema_version < 1
    ):
        raise ValueError("schema_version must be a positive integer")
    if not isinstance(metadata.tool_version, str) or not metadata.tool_version:
        raise ValueError("tool_version must be a non-empty string")
    _validate_strings("command", metadata.command, allow_empty=True)
    _validate_strings("fidelity_caveats", metadata.fidelity_caveats, allow_empty=True)
    if any("\n" in argument or "\r" in argument for argument in metadata.command):
        raise ValueError("command arguments must not contain line breaks")
    return AlgorithmVersion.parse(metadata.model_version)


def _validate_config(config: ArtifactConfig) -> None:
    if not isinstance(config, ArtifactConfig):
        raise TypeError("config must be ArtifactConfig")
    _validate_strings("summary_metrics", config.summary_metrics, allow_empty=False)
    if len(set(config.summary_metrics)) != len(config.summary_metrics):
        raise ValueError("summary_metrics must be unique")
    if not isinstance(config.region_value_name, str) or not config.region_value_name:
        raise ValueError("region_value_name must be a non-empty string")
    fixed_columns = {"tick", "phase", "checkpoint", "region_index"}
    if config.region_value_name in fixed_columns:
        raise ValueError("region_value_name must not duplicate a fixed CSV column")


def _validate_records(records: tuple[TickRecord, ...], config: ArtifactConfig) -> None:
    if not records:
        raise ValueError("records must not be empty")

    expected_metrics = set(config.summary_metrics)
    previous_tick: int | None = None
    for record in records:
        if not isinstance(record, TickRecord):
            raise TypeError("records must contain TickRecord values")
        if (
            not isinstance(record.tick, int)
            or isinstance(record.tick, bool)
            or record.tick < 0
        ):
            raise ValueError("tick must be a non-negative integer")
        if previous_tick is not None and record.tick <= previous_tick:
            raise ValueError("record ticks must be strictly increasing")
        previous_tick = record.tick
        if not isinstance(record.phase, str) or not record.phase:
            raise ValueError("phase must be a non-empty string")
        if set(record.metrics) != expected_metrics:
            raise ValueError("record metrics must exactly match summary_metrics")
        for name in config.summary_metrics:
            _validate_scalar(f"metric {name!r}", record.metrics[name])
        for name, value in (("event", record.event), ("checkpoint", record.checkpoint)):
            if value is not None and (not isinstance(value, str) or not value):
                raise ValueError(f"{name} must be a non-empty string or None")
        if record.regions is not None:
            for value in record.regions:
                if not isinstance(value, int) or isinstance(value, bool):
                    raise ValueError("region values must be integers")


def _validate_sha256(name: str, digest: object) -> None:
    if not isinstance(digest, str) or _SHA256_PATTERN.fullmatch(digest) is None:
        raise ValueError(f"{name} must be a 64-character hexadecimal SHA-256")


def _validate_strings(name: str, values: object, *, allow_empty: bool) -> None:
    if not isinstance(values, tuple):
        raise ValueError(f"{name} must be a tuple")
    if not allow_empty and not values:
        raise ValueError(f"{name} must not be empty")
    if any(not isinstance(value, str) or not value for value in values):
        raise ValueError(f"{name} must contain non-empty strings")


def _validate_scalar(name: str, value: object) -> None:
    if value is not None and not isinstance(value, (str, int, float, bool)):
        raise ValueError(f"{name} must be a JSON scalar")
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError(f"{name} must be finite")


def _aggregates(
    records: tuple[TickRecord, ...], metric_names: tuple[str, ...]
) -> dict[str, object]:
    metrics: dict[str, object] = {}
    for name in metric_names:
        values = [record.metrics[name] for record in records]
        non_null = [value for value in values if value is not None]
        final = values[-1]
        if non_null and all(isinstance(value, bool) for value in non_null):
            metrics[name] = {
                "false_count": sum(value is False for value in non_null),
                "final": final,
                "true_count": sum(value is True for value in non_null),
            }
        elif non_null and all(
            isinstance(value, (int, float)) and not isinstance(value, bool)
            for value in non_null
        ):
            metrics[name] = {
                "final": final,
                "maximum": max(non_null),
                "minimum": min(non_null),
            }
        else:
            metrics[name] = {
                "final": final,
                "non_null_count": len(non_null),
            }
    return {
        "first_tick": records[0].tick,
        "last_tick": records[-1].tick,
        "metrics": metrics,
        "record_count": len(records),
    }


def _json_document(value: object) -> bytes:
    text = json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return f"{text}\n".encode("utf-8")


def _trace_jsonl(records: tuple[TickRecord, ...]) -> bytes:
    lines: list[str] = []
    for record in records:
        if record.event is None and record.checkpoint is None:
            continue
        item: dict[str, object] = {
            "metrics": dict(record.metrics),
            "phase": record.phase,
            "tick": record.tick,
        }
        if record.event is not None:
            item["event"] = record.event
        if record.checkpoint is not None:
            item["checkpoint"] = record.checkpoint
        lines.append(
            json.dumps(
                item,
                allow_nan=False,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
        )
    text = "\n".join(lines)
    if lines:
        text += "\n"
    return text.encode("utf-8")


def _summary_csv(
    records: tuple[TickRecord, ...], metric_names: tuple[str, ...]
) -> bytes:
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerow(("tick", "phase", *metric_names))
    for record in records:
        writer.writerow(
            (
                record.tick,
                record.phase,
                *(_csv_scalar(record.metrics[name]) for name in metric_names),
            )
        )
    return stream.getvalue().encode("utf-8")


def _regions_csv(
    records: tuple[TickRecord, ...], region_value_name: str
) -> bytes:
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerow(("tick", "phase", "checkpoint", "region_index", region_value_name))
    for record in records:
        if record.regions is None:
            continue
        for index, value in enumerate(record.regions):
            writer.writerow(
                (record.tick, record.phase, record.checkpoint or "", index, value)
            )
    return stream.getvalue().encode("utf-8")


def _csv_scalar(value: Scalar) -> str | int:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return json.dumps(value, allow_nan=False)
    return value


def _report(
    metadata: RunMetadata,
    model_version: AlgorithmVersion,
    config: ArtifactConfig,
    aggregates: Mapping[str, object],
    caveats: tuple[str, ...],
) -> bytes:
    metrics = aggregates["metrics"]
    assert isinstance(metrics, dict)
    lines = [
        "# PontusM Simulation Report",
        "",
        f"- Scenario: `{_inline_code(metadata.scenario_name)}`",
        f"- Model version: {int(model_version)}",
        f"- Generated at: `{_inline_code(metadata.created_at)}`",
        f"- Records: {aggregates['record_count']}",
        f"- Tick range: {aggregates['first_tick']}–{aggregates['last_tick']}",
        "",
        "## Aggregate metrics",
        "",
        "| Metric | Minimum | Maximum | Final |",
        "| --- | ---: | ---: | ---: |",
    ]
    for name in config.summary_metrics:
        aggregate = metrics[name]
        assert isinstance(aggregate, dict)
        lines.append(
            "| "
            + " | ".join(
                (
                    _table_cell(name),
                    _table_cell(aggregate.get("minimum", "")),
                    _table_cell(aggregate.get("maximum", "")),
                    _table_cell(aggregate.get("final", "")),
                )
            )
            + " |"
        )
    lines.extend(
        (
            "",
            "## Source archives",
            "",
            "| Archive | SHA-256 |",
            "| --- | --- |",
        )
    )
    for name, digest in sorted(metadata.source_archive_hashes.items()):
        lines.append(f"| {_table_cell(name)} | `{digest.lower()}` |")
    lines.extend(("", "## Fidelity caveats", ""))
    lines.extend(f"- {_markdown_text(caveat)}" for caveat in caveats)
    lines.extend(("", "## Reproduction", ""))
    if metadata.command:
        lines.append(f"    {shlex.join(metadata.command)}")
    else:
        lines.append("Command not supplied.")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _markdown_text(value: str) -> str:
    return value.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")


def _table_cell(value: object) -> str:
    if value is None:
        text = ""
    elif isinstance(value, bool):
        text = "true" if value else "false"
    else:
        text = str(value)
    return _markdown_text(text).replace("|", "\\|")


def _inline_code(value: str) -> str:
    return _markdown_text(value).replace("`", "\\`")
