"""Scenario schema, deterministic expansion, and QD runner."""

from __future__ import annotations

from dataclasses import dataclass, fields
import hashlib
import json
from pathlib import Path
from typing import Any

from .model import QDModel
from .types import FrameStats, LogoBrightness


SCHEMA_VERSION = 1
_VECTOR_LENGTHS = {
    "mean_columns": 32,
    "max_columns": 32,
    "mean_rows": 16,
    "max_rows": 16,
    "histogram": 32,
    "hue": 35,
    "region_gains": 225,
    "banner_rgb": 4,
}
_FRAME_FIELDS = {item.name for item in fields(FrameStats)}


@dataclass(frozen=True)
class ScenarioPhase:
    name: str
    ticks: int
    frame: FrameStats
    snapshots: tuple[tuple[int, str], ...] = ()


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    record_every: int
    phases: tuple[ScenarioPhase, ...]
    sha256: str
    source_path: str


@dataclass(frozen=True)
class ScenarioResult:
    name: str
    version: int
    scenario_sha256: str
    tick_count: int
    events: tuple[dict[str, Any], ...]
    samples: tuple[dict[str, Any], ...]
    regions: tuple[dict[str, Any], ...]
    phases: tuple[dict[str, Any], ...]


def _expand_vector(name: str, value: Any) -> list[Any]:
    length = _VECTOR_LENGTHS[name]
    if isinstance(value, list):
        return list(value)
    if not isinstance(value, dict) or set(value) - {"fill", "set"} or "fill" not in value:
        raise ValueError(f"{name} must be a list or fill/set object")
    fill = value["fill"]
    result = [tuple(fill) if name == "banner_rgb" else fill for _ in range(length)]
    for raw_index, replacement in value.get("set", {}).items():
        try:
            index = int(raw_index)
        except (TypeError, ValueError):
            raise ValueError(f"{name} set indexes must be integers") from None
        if not 0 <= index < length:
            raise ValueError(f"{name} set index {index} is outside 0...{length - 1}")
        result[index] = tuple(replacement) if name == "banner_rgb" else replacement
    return result


def _frame_from_inputs(inputs: Any) -> FrameStats:
    if not isinstance(inputs, dict):
        raise ValueError("phase inputs must be an object")
    unknown = set(inputs) - _FRAME_FIELDS
    if unknown:
        raise ValueError(f"unknown frame input: {sorted(unknown)[0]}")
    values: dict[str, Any] = {}
    for name, value in inputs.items():
        if name in _VECTOR_LENGTHS:
            values[name] = _expand_vector(name, value)
        elif name == "logo_brightness":
            try:
                values[name] = {
                    "off": LogoBrightness.OFF,
                    "low": LogoBrightness.LOW,
                    "high": LogoBrightness.HIGH,
                }[str(value).lower()]
            except KeyError:
                raise ValueError("logo_brightness must be off, low, or high") from None
        else:
            values[name] = value
    frame = FrameStats(**values)
    frame.validate()
    return frame


def load_scenario(path: str | Path) -> Scenario:
    source = Path(path)
    raw = source.read_bytes()
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid scenario JSON: {error}") from None
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"schema_version must be {SCHEMA_VERSION}")
    name = payload.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("scenario name must be non-empty")
    raw_phases = payload.get("phases")
    if not isinstance(raw_phases, list) or not raw_phases:
        raise ValueError("scenario must contain at least one phase")
    record_every = payload.get("record_every", 100)
    if not isinstance(record_every, int) or record_every <= 0:
        raise ValueError("record_every must be a positive integer")

    phases: list[ScenarioPhase] = []
    for raw_phase in raw_phases:
        if not isinstance(raw_phase, dict):
            raise ValueError("each phase must be an object")
        unknown = set(raw_phase) - {"name", "ticks", "inputs", "snapshots"}
        if unknown:
            raise ValueError(f"unknown phase field: {sorted(unknown)[0]}")
        phase_name = raw_phase.get("name")
        ticks = raw_phase.get("ticks")
        if not isinstance(phase_name, str) or not phase_name:
            raise ValueError("phase name must be non-empty")
        if not isinstance(ticks, int) or ticks <= 0:
            raise ValueError("phase must have positive ticks")
        raw_snapshots = raw_phase.get("snapshots", {})
        if not isinstance(raw_snapshots, dict):
            raise ValueError("phase snapshots must be an object")
        snapshots: list[tuple[int, str]] = []
        for raw_tick, label in raw_snapshots.items():
            try:
                tick = int(raw_tick)
            except (TypeError, ValueError):
                raise ValueError("snapshot offsets must be integers") from None
            if not 1 <= tick <= ticks or not isinstance(label, str) or not label:
                raise ValueError("snapshot offsets must be in-phase with non-empty labels")
            snapshots.append((tick, label))
        phases.append(
            ScenarioPhase(
                name=phase_name,
                ticks=ticks,
                frame=_frame_from_inputs(raw_phase.get("inputs", {})),
                snapshots=tuple(sorted(snapshots)),
            )
        )
    return Scenario(
        name=name,
        description=str(payload.get("description", "")),
        record_every=record_every,
        phases=tuple(phases),
        sha256=hashlib.sha256(raw).hexdigest(),
        source_path=str(source),
    )


def _sample(output: Any, phase: str) -> dict[str, Any]:
    return {
        "tick": output.tick,
        "phase": phase,
        "flat": output.flat,
        "standard_pattern": output.standard_pattern,
        "hdr_color_pattern": output.hdr_color_pattern,
        "retention": output.retention,
        "retention_available": output.retention_available,
        "retention_count": output.retention_count,
        "local_strength": output.local_strength,
        "local_target_strength": output.local_target_strength,
        "minimum_region_duty": min(output.region_duties),
        "app_counter": output.app_counter,
        "app_duty": output.app_duty,
        "anti_residue": output.anti_residue,
        "fcn_gain": output.fcn_gain,
        "fcn_available": output.fcn_available,
        "srp_center_mask_gain": output.srp_center_mask_gain,
        "srp_board_mask_gain": output.srp_board_mask_gain,
        "banner_probability": output.banner_probability,
        "banner_history": output.banner_history,
        "screen_saver_off": output.screen_saver_off,
        "isp_off": output.isp_off,
        "policy_state": output.policy_state,
    }


def run_scenario(model: QDModel, scenario: Scenario) -> ScenarioResult:
    events: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    regions: list[dict[str, Any]] = []
    phase_records: list[dict[str, Any]] = []
    previous_flags: tuple[Any, ...] | None = None

    for phase in scenario.phases:
        phase_start = model.tick + 1
        snapshots = dict(phase.snapshots)
        events.append({"tick": phase_start, "event": "phase-start", "phase": phase.name})
        for offset in range(1, phase.ticks + 1):
            output = model.step(phase.frame)
            flags = (
                output.flat,
                output.standard_pattern,
                output.hdr_color_pattern,
                output.retention,
                output.screen_saver_off,
                output.isp_off,
            )
            changed = previous_flags is not None and flags != previous_flags
            if changed:
                events.append(
                    {
                        "tick": output.tick,
                        "event": "protection-change",
                        "phase": phase.name,
                        "state": list(flags),
                    }
                )
            previous_flags = flags
            if (
                output.tick % scenario.record_every == 0
                or offset == 1
                or offset == phase.ticks
                or offset in snapshots
                or changed
            ):
                samples.append(_sample(output, phase.name))
            if offset in snapshots:
                regions.append(
                    {
                        "tick": output.tick,
                        "phase": phase.name,
                        "snapshot": snapshots[offset],
                        "duties": list(output.region_duties),
                    }
                )
        events.append({"tick": model.tick, "event": "phase-end", "phase": phase.name})
        phase_records.append(
            {
                "name": phase.name,
                "start_tick": phase_start,
                "end_tick": model.tick,
                "ticks": phase.ticks,
            }
        )

    return ScenarioResult(
        name=scenario.name,
        version=int(model.version),
        scenario_sha256=scenario.sha256,
        tick_count=model.tick,
        events=tuple(events),
        samples=tuple(samples),
        regions=tuple(regions),
        phases=tuple(phase_records),
    )
