"""Finite, offline predicates over captured evidence. No fitting or scores.

Schema 1 has a root ``schema_version``, nonempty ``hypotheses`` array, and
optional ``notes`` string. Every predicate requires id/type/trial and an explicit
nonempty ``accepted_qualities`` list (there is no implicit quality ranking).
The fields in _FIELDS below are exhaustive and required, with no expressions,
numeric register joins, arbitrary model inputs, or QD-internal field selectors.

Intervals and event windows are closed. Each timestamp has the manifest's
absolute uncertainty, so a difference has twice that bound. Phase scalars use
the arithmetic mean of all channel samples in each uniquely named phase;
increasing/decreasing strictly exceed the deadband, unchanged includes it.
``value_uncertainty`` bounds each scalar (including a phase mean) independently.
ROI attenuation is control ratio minus ROI ratio. No value uncertainty is
inferred from timestamp uncertainty. Timing ambiguity makes evidence unusable.
Scalar arithmetic uses exact rational values of each loaded number's decimal
representation, avoiding additional floating-point rounding at boundaries.

An event window requires coverage_sequences selecting the reserved string values
``coverage.complete.start`` and ``coverage.complete.end`` on the selected channel,
in that order, with no intervening completeness sentinel on that channel. These
sentinels declare continuous, complete logging of that channel over the closed
interval: the logger must emit the end sentinel only when no events were dropped
since its start sentinel. Ordinary bracketing samples cannot make this assertion.
The capture loader's hash check binds these declarations to the supplied bytes;
it does not independently verify logger truthfulness or physical instrumentation.
Both sentinels and all selected events must satisfy accepted_qualities. The
sentinels are reserved and cannot be event targets. Absence means absence in
this explicitly declared-complete log, not proof about an uninstrumented event.
Phase intervals are half-open; before must precede after in log order. Equal
timestamps use log order only when uncertainty is zero.

HypothesisSet retains immutable exact source_bytes as well as their SHA-256.
Comparison revalidates those bytes, checks the digest, and requires the current
schema/predicates/notes to match the retained document before evaluating it.

Production callers supply SourceVerification.orbit_tables together with its
version as orbit_table_version. Other-version predicates remain unavailable
without evaluating those tables or consuming their disclosure budget. Unbound
tables are supported only as caller-supplied miniature synthetic test data;
this module does not authenticate tables or establish a caller's provenance.
It swaps captured axes first, then applies the fixed x/y signs. Orbit selectors
declare each successive position explicitly; no sparse trace interpolation is
performed. Each orbit alignment reports the surviving-candidate status after
that observation's prefix; the final predicate uses the complete sequence.
Orbit expected values encode candidate counts before/after, and starts only when
each set has at most eight entries. Source-derived coordinate options have one
global disclosure budget per invocation/source-table mapping, across every
hypothesis and table name. Only the first retained eliminating prefix receives
options; surviving rows, later predicates, and subsequent zero-candidate rows
receive none. Unusable evidence does not consume the budget. Successful sequences
therefore expose no expected source coordinates. Observed values use the same
absolute/relative coordinate system as eliminating options. Complete final
survivor sets remain in PredicateResult.
No v1 predicate references QD state, so QD scenario execution is not
needed. A future QD predicate must execute a finite named scenario at every tick.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

from .observations import CapturePackage, Observation, _json, _object, _integer, _string, _UNITS
from .types import AlgorithmVersion


class ComparisonStatus(str, Enum):
    CONSISTENT = "consistent"
    CONTRADICTED = "contradicted"
    INDETERMINATE = "indeterminate"


@dataclass(frozen=True)
class HypothesisSet:
    schema_version: int
    hypotheses: tuple[Mapping[str, object], ...]
    sha256: str
    notes: str | None = None
    source_bytes: bytes = b""


@dataclass(frozen=True)
class PredicateResult:
    id: str
    type: str
    trial: str
    category: str
    status: ComparisonStatus
    reason: str
    evidence_sequences: tuple[int, ...]
    surviving_indices: tuple[int, ...] = ()
    notes: tuple[str, ...] = ()


@dataclass(frozen=True)
class AlignmentRow:
    hypothesis_id: str
    trial: str
    sequences: tuple[int, ...]
    observed: str
    expected: str
    status: ComparisonStatus


@dataclass(frozen=True)
class ComparisonResult:
    capture_id: str
    hypotheses_sha256: str
    results: tuple[PredicateResult, ...]
    alignments: tuple[AlignmentRow, ...]


_COMMON = {"id", "type", "trial", "accepted_qualities"}
_FIELDS = {
    "orbit_sequence": {"sequences", "orbit", "version", "coordinates"},
    "cadence_interval": {"channel", "sequences", "minimum_us", "maximum_us"},
    "event_window": {"channel", "event", "present", "start_us", "end_us", "coverage_sequences"},
    "phase_scalar": {"channel", "before_phase", "after_phase", "direction", "tolerance", "value_uncertainty"},
    "roi_control_delta": {"roi_sequence", "control_sequence", "minimum_delta", "value_uncertainty", "maximum_skew_us"},
    "context": {"channel"},
}
_SCALARS = {"display.roi_luma_ratio", "display.control_luma_ratio", "display.uniform_luma_ratio",
            "panel.temperature_raw"}
_CONTEXT = {"msi.register.transaction", "panel.off_sensing_event"}
_COVERAGE_SENTINELS = ("coverage.complete.start", "coverage.complete.end")


def _number(value: object, label: str) -> None:
    if type(value) not in (int, float) or value < 0 or (type(value) is float and not math.isfinite(value)):
        raise ValueError(f"{label} must be a finite nonnegative number")


def _sequences(value: object, label: str, minimum: int, exact: int | None = None) -> None:
    if type(value) is not list or len(value) < minimum or (exact is not None and len(value) != exact):
        raise ValueError(f"{label} has invalid sequence count")
    for sequence in value:
        _integer(sequence, label)
    if any(a >= b for a, b in zip(value, value[1:])):
        raise ValueError(f"{label} must strictly increase")


def _validate(payload: object) -> tuple[Mapping[str, object], ...]:
    root = _object(payload, {"schema_version", "hypotheses"}, {"notes"}, "hypotheses document")
    _integer(root["schema_version"], "schema_version", 1, 1)
    if "notes" in root and type(root["notes"]) is not str:
        raise ValueError("notes must be a string")
    items = root["hypotheses"]
    if type(items) is not list or not items:
        raise ValueError("hypotheses must be a nonempty array")
    result = []
    seen = set()
    for item in items:
        if type(item) is not dict or type(item.get("type")) is not str or item["type"] not in _FIELDS:
            raise ValueError("unknown predicate type")
        kind = item["type"]
        p = _object(item, _COMMON | _FIELDS[kind], set(), "predicate")
        for name in ("id", "trial"):
            _string(p[name], name)
        if p["id"] in seen:
            raise ValueError("duplicate hypothesis id")
        seen.add(p["id"])
        qualities = p["accepted_qualities"]
        if type(qualities) is not list or not qualities or any(
                type(q) is not str or q not in ("measured", "decoded", "derived") for q in qualities):
            raise ValueError("accepted_qualities must explicitly select known qualities")
        if len(set(qualities)) != len(qualities):
            raise ValueError("duplicate accepted quality")
        if "channel" in p and (type(p["channel"]) is not str or p["channel"] not in _UNITS):
            raise ValueError("unsupported predicate channel")
        if kind == "orbit_sequence":
            _integer(p["version"], "version", 18, 22)
            if p["version"] not in (18, 20, 22):
                raise ValueError("version must be 18, 20, or 22")
            if type(p["orbit"]) is not str or p["orbit"] not in ("normal", "rotation"):
                raise ValueError("orbit must be normal or rotation")
            if p["orbit"] == "rotation" and p["version"] == 18:
                raise ValueError("rotation requires version 20 or 22")
            if type(p["coordinates"]) is not str or p["coordinates"] not in ("absolute", "relative"):
                raise ValueError("coordinates must be absolute or relative")
            _sequences(p["sequences"], "sequences", 2 if p["coordinates"] == "relative" else 1)
        elif kind == "cadence_interval":
            _sequences(p["sequences"], "sequences", 2)
            for key in ("minimum_us", "maximum_us"):
                _integer(p[key], key)
            if p["minimum_us"] > p["maximum_us"]:
                raise ValueError("interval bounds are reversed")
        elif kind == "event_window":
            _string(p["event"], "event")
            if p["event"] in _COVERAGE_SENTINELS:
                raise ValueError("completeness sentinels are reserved, not target events")
            if p["channel"] not in {"stimulus.phase"} | _CONTEXT:
                raise ValueError("event_window requires a semantic event channel")
            if type(p["present"]) is not bool:
                raise ValueError("present must be bool")
            for key in ("start_us", "end_us"):
                _integer(p[key], key)
            if p["start_us"] > p["end_us"]:
                raise ValueError("event window is reversed")
            _sequences(p["coverage_sequences"], "coverage_sequences", 2, 2)
        elif kind == "phase_scalar":
            if p["channel"] not in _SCALARS | _CONTEXT:
                raise ValueError("phase_scalar requires a scalar channel")
            for key in ("before_phase", "after_phase"):
                _string(p[key], key)
            if p["before_phase"] == p["after_phase"]:
                raise ValueError("phase names must differ")
            if type(p["direction"]) is not str or p["direction"] not in ("increasing", "decreasing", "unchanged"):
                raise ValueError("unknown scalar direction")
            for key in ("tolerance", "value_uncertainty"):
                _number(p[key], key)
        elif kind == "roi_control_delta":
            for key in ("roi_sequence", "control_sequence", "maximum_skew_us"):
                _integer(p[key], key)
            if p["roi_sequence"] == p["control_sequence"]:
                raise ValueError("ROI and control sequences must differ")
            for key in ("minimum_delta", "value_uncertainty"):
                _number(p[key], key)
        elif kind == "context" and p["channel"] not in _CONTEXT:
            raise ValueError("context requires register or OFF/EL evidence")
        result.append(MappingProxyType({k: tuple(v) if type(v) is list else v for k, v in p.items()}))
    return tuple(result)


def load_hypotheses(path: str | Path) -> HypothesisSet:
    """Validate the entire strict document before exposing any predicates."""
    try:
        raw = Path(path).read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read hypotheses: {error.strerror}") from error
    payload = _json(raw, "hypotheses JSON")
    predicates = _validate(payload)
    return HypothesisSet(1, predicates, hashlib.sha256(raw).hexdigest(), payload.get("notes"), raw)


def _bound_hypotheses(hypotheses: HypothesisSet) -> tuple[Mapping[str, object], ...]:
    """Reject stale or invalid metadata and evaluate the immutable source document."""
    if (type(hypotheses) is not HypothesisSet or type(hypotheses.source_bytes) is not bytes
            or not hypotheses.source_bytes or type(hypotheses.sha256) is not str):
        raise ValueError("hypotheses require immutable source bytes and their SHA-256")
    if hashlib.sha256(hypotheses.source_bytes).hexdigest() != hypotheses.sha256:
        raise ValueError("hypotheses source SHA-256 mismatch")
    source = _json(hypotheses.source_bytes, "hypotheses JSON")
    predicates = _validate(source)
    if type(hypotheses.hypotheses) is not tuple or any(
            not isinstance(p, Mapping) for p in hypotheses.hypotheses):
        raise ValueError("hypotheses must contain immutable predicate mappings")
    payload = {"schema_version": hypotheses.schema_version,
        "hypotheses": [{k: list(v) if type(v) is tuple else v for k, v in p.items()}
                       for p in hypotheses.hypotheses]}
    if hypotheses.notes is not None:
        payload["notes"] = hypotheses.notes
    _validate(payload)
    # Canonical comparison preserves numeric types as well as every schema field.
    # The reported digest remains the exact source-byte hash, never this encoding.
    if json.dumps(payload, sort_keys=True, allow_nan=False) != json.dumps(source, sort_keys=True, allow_nan=False):
        raise ValueError("hypotheses state does not match retained source bytes")
    return predicates


def _window(low: float, high: float, minimum: float, maximum: float) -> ComparisonStatus:
    if low >= minimum and high <= maximum:
        return ComparisonStatus.CONSISTENT
    if high < minimum or low > maximum:
        return ComparisonStatus.CONTRADICTED
    return ComparisonStatus.INDETERMINATE


def _combine(statuses: list[ComparisonStatus]) -> ComparisonStatus:
    # Every point is required: one definitive falsifier disproves a conjunction.
    if ComparisonStatus.CONTRADICTED in statuses:
        return ComparisonStatus.CONTRADICTED
    if not statuses or ComparisonStatus.INDETERMINATE in statuses:
        return ComparisonStatus.INDETERMINATE
    return ComparisonStatus.CONSISTENT


def _phase(rows: list[Observation], name: str, channel: str, uncertainty: int):
    markers = [r for r in rows if r.channel == "stimulus.phase"]
    starts = [r for r in markers if r.value == name]
    if len(starts) != 1:
        return [], "missing or repeated phase"
    start = starts[0]
    end = next((r for r in markers if r.sequence > start.sequence), None)
    selected = [r for r in rows if r.channel == channel and r.sequence > start.sequence
                and (end is None or r.sequence < end.sequence)]
    evidence = [start, *([end] if end else []), *selected]
    if not selected:
        return evidence, "missing phase scalar evidence"
    if uncertainty and any(r.time_us - start.time_us <= 2 * uncertainty or
            (end is not None and end.time_us - r.time_us <= 2 * uncertainty) for r in selected):
        return evidence, "timestamp uncertainty crosses a phase boundary"
    return evidence, None


def compare_capture(capture: CapturePackage, hypotheses: HypothesisSet, *,
        orbit_tables: Mapping[str, tuple[tuple[int, int], ...]] | None = None,
        orbit_table_version: int | AlgorithmVersion | None = None) -> ComparisonResult:
    """Evaluate fully validated predicates, returning coverage and point rows.

    Revalidation also rejects malformed manually constructed HypothesisSets
    before looking at any evidence. All observation references are trial-local.
    Production table mappings must be bound to their verified source version;
    an omitted version is the synthetic caller-supplied-table API only.
    """
    predicates = _bound_hypotheses(hypotheses)
    if orbit_table_version is not None:
        if (
            type(orbit_table_version) not in (int, AlgorithmVersion)
            or orbit_table_version not in (18, 20, 22)
        ):
            raise ValueError("orbit_table_version must be 18, 20, or 22")
        if orbit_tables is None:
            raise ValueError("orbit_table_version requires orbit_tables")
    if orbit_tables is not None:
        if not isinstance(orbit_tables, Mapping):
            raise ValueError("orbit_tables must be a mapping")
        for name, table in orbit_tables.items():
            if name not in ("orbit_table", "orbit_table_24x16", "orbit_table_32x16", "orbit_table_ew"):
                raise ValueError("unknown orbit table")
            if type(table) is not tuple or not table or any(type(point) is not tuple or
                    len(point) != 2 or any(type(axis) is not int for axis in point) for point in table):
                raise ValueError("orbit tables must contain nonempty immutable integer coordinate pairs")
    results = []
    alignments = []
    coordinate_disclosure_used = False
    u = capture.manifest.timebase["uncertainty_us"]
    for p in predicates:
        rows = [r for r in capture.observations if r.trial == p["trial"]]
        by_sequence = {r.sequence: r for r in rows}
        kind = p["type"]
        evidence = []
        points = []
        reason = None
        category = "proxy"
        survivors = ()
        notes = ()
        discloses_coordinates = False
        if p.get("channel") in _CONTEXT:
            evidence = [r for r in rows if r.channel == p["channel"]]
            reason = "context-only: raw register and OFF/EL evidence cannot establish a PontusM result"
            category = "context-only"
        elif kind == "orbit_sequence":
            category = "direct"
            if p["orbit"] == "normal":
                notes = (
                    "normal orbit equality is non-discriminating between PontusM v18, v20, and v22",
                )
            evidence = [by_sequence[s] for s in p["sequences"] if s in by_sequence]
            name = "orbit_table" if p["orbit"] == "normal" else "orbit_table_32x16"
            table = (orbit_tables or {}).get(name)
            if orbit_table_version is not None and p["version"] != orbit_table_version:
                reason = (f"PontusM v{p['version']} {name} unavailable: supplied orbit tables "
                          f"are bound to v{int(orbit_table_version)}")
                category = "unavailable"
            elif len(evidence) != len(p["sequences"]) or any(r.channel != "display.offset_px" for r in evidence):
                reason = "missing required position observations"
            elif table is None:
                reason = "authenticated orbit table unavailable"
                category = "unavailable"
            else:
                calibration = capture.manifest.calibration
                observed = []
                for r in evidence:
                    x, y = r.value["x"], r.value["y"]
                    if calibration["swap_axes"]:
                        x, y = y, x
                    observed.append((x*calibration["x_sign"], y*calibration["y_sign"]))
                relative = p["coordinates"] == "relative"
                origin = observed[0] if relative else (0, 0)
                targets = [(x-origin[0], y-origin[1]) for x, y in observed]
                candidates = list(range(len(table)))
                for i, (r, target) in enumerate(zip(evidence, targets)):
                    expected = {"table": name, "version": p["version"],
                        "coordinates": p["coordinates"], "position_in_sequence": i,
                        "candidate_count_before": len(candidates)}
                    if len(candidates) <= 8:
                        expected["candidate_starts_before"] = candidates
                    remaining = []
                    options = set()
                    for start in candidates:
                        source_origin = table[start] if relative else (0, 0)
                        position = table[(start+i) % len(table)]
                        predicted = (position[0]-source_origin[0], position[1]-source_origin[1])
                        options.add(predicted)
                        if predicted == target:
                            remaining.append(start)
                    candidates = remaining
                    if (not coordinate_disclosure_used and not candidates
                            and expected["candidate_count_before"]):
                        expected["coordinate_options"] = sorted(options)
                        discloses_coordinates = True
                    expected["candidate_count_after"] = len(candidates)
                    if len(candidates) <= 8:
                        expected["candidate_starts_after"] = candidates
                    status = (ComparisonStatus.CONTRADICTED if not candidates else
                              ComparisonStatus.CONSISTENT if len(candidates) == 1 else ComparisonStatus.INDETERMINATE)
                    points.append(((r.sequence,), str(target),
                        json.dumps(expected, sort_keys=True, separators=(",", ":")), status))
                survivors = tuple(candidates)
        elif kind == "cadence_interval":
            evidence = [by_sequence[s] for s in p["sequences"] if s in by_sequence]
            if len(evidence) != len(p["sequences"]) or any(r.channel != p["channel"] for r in evidence):
                reason = "missing required channel observations"
            else:
                for a, b in zip(evidence, evidence[1:]):
                    delta = b.time_us - a.time_us
                    status = _window(delta - 2*u, delta + 2*u, p["minimum_us"], p["maximum_us"])
                    points.append(((a.sequence, b.sequence), str(delta),
                        f"[{p['minimum_us']}, {p['maximum_us']}] us", status))
        elif kind == "event_window":
            notes = ("event presence/absence describes only the supplied channel log with explicit complete-coverage sentinels; capture hashes do not independently verify logger truthfulness",)
            coverage = [by_sequence[s] for s in p["coverage_sequences"] if s in by_sequence]
            if (len(coverage) != 2 or any(r.channel != p["channel"] for r in coverage)
                    or tuple(r.value for r in coverage) != _COVERAGE_SENTINELS
                    or coverage[0].time_us + u > p["start_us"]
                    or coverage[-1].time_us - u < p["end_us"]
                    or any(r.value in _COVERAGE_SENTINELS for r in rows
                           if r.channel == p["channel"] and coverage[0].sequence < r.sequence < coverage[-1].sequence)):
                reason = "missing or ambiguous declared-complete window coverage"
                evidence = coverage
            else:
                events = [r for r in rows if r.channel == p["channel"] and
                    coverage[0].sequence <= r.sequence <= coverage[-1].sequence]
                evidence = list({r.sequence: r for r in [*coverage, *events]}.values())
                matches = [r for r in events if r.value == p["event"]]
                statuses = [_window(r.time_us-u, r.time_us+u, p["start_us"], p["end_us"]) for r in matches]
                if ComparisonStatus.CONSISTENT in statuses:
                    status = ComparisonStatus.CONSISTENT if p["present"] else ComparisonStatus.CONTRADICTED
                elif ComparisonStatus.INDETERMINATE in statuses:
                    status = ComparisonStatus.INDETERMINATE
                else:
                    status = ComparisonStatus.CONTRADICTED if p["present"] else ComparisonStatus.CONSISTENT
                points.append((tuple(r.sequence for r in matches), str(len(matches)),
                    f"event {p['event']!r} present={p['present']} in [{p['start_us']}, {p['end_us']}] us", status))
        elif kind == "phase_scalar":
            before, error_before = _phase(rows, p["before_phase"], p["channel"], u)
            after, error_after = _phase(rows, p["after_phase"], p["channel"], u)
            evidence = list({r.sequence: r for r in [*before, *after]}.values())
            reason = error_before or error_after
            if reason is None and before[0].sequence >= after[0].sequence:
                reason = "before_phase marker does not precede after_phase marker"
            if reason is None:
                values = [[Fraction(str(r.value)) for r in group if r.channel == p["channel"]] for group in (before, after)]
                delta = sum(values[1])/len(values[1]) - sum(values[0])/len(values[0])
                uncertainty = Fraction(str(p["value_uncertainty"]))
                low, high = delta - 2*uncertainty, delta + 2*uncertainty
                tolerance = Fraction(str(p["tolerance"]))
                if p["direction"] == "unchanged":
                    status = _window(low, high, -tolerance, tolerance)
                else:
                    if p["direction"] == "decreasing":
                        low, high = -high, -low
                    status = (ComparisonStatus.CONSISTENT if low > tolerance else
                              ComparisonStatus.CONTRADICTED if high <= tolerance else ComparisonStatus.INDETERMINATE)
                points.append((tuple(r.sequence for r in evidence), str(delta),
                    f"{p['direction']} with deadband {tolerance}", status))
        elif kind == "roi_control_delta":
            roi, control = by_sequence.get(p["roi_sequence"]), by_sequence.get(p["control_sequence"])
            evidence = [r for r in (roi, control) if r is not None]
            if roi is None or control is None or roi.channel != "display.roi_luma_ratio" or control.channel != "display.control_luma_ratio":
                reason = "missing required ROI/control evidence"
            elif abs(roi.time_us-control.time_us) + 2*u > p["maximum_skew_us"]:
                reason = "ROI/control timing exceeds or crosses maximum skew"
            else:
                delta = Fraction(str(control.value)) - Fraction(str(roi.value))
                uncertainty = Fraction(str(p["value_uncertainty"]))
                status = _window(delta - 2*uncertainty, delta + 2*uncertainty, Fraction(str(p["minimum_delta"])), math.inf)
                points.append(((roi.sequence, control.sequence), str(delta), f">= {p['minimum_delta']}", status))
        if reason is None and any(r.quality not in p["accepted_qualities"] for r in evidence):
            reason = "insufficient observation quality"
        if reason is not None:
            status = ComparisonStatus.INDETERMINATE
            survivors = ()
            points = [(tuple(r.sequence for r in evidence), "", reason, status)]
        else:
            if kind == "orbit_sequence":
                coordinate_disclosure_used |= discloses_coordinates
                status = points[-1][3]
                reason = f"{len(survivors)} surviving cyclic starting indices"
            else:
                status = _combine([point[3] for point in points])
                reason = {ComparisonStatus.CONSISTENT: "all required observations satisfy the predicate",
                    ComparisonStatus.CONTRADICTED: "required observations falsify the predicate",
                    ComparisonStatus.INDETERMINATE: "measurement uncertainty crosses a predicate boundary"}[status]
        results.append(PredicateResult(p["id"], kind, p["trial"], category, status, reason,
            tuple(sorted(r.sequence for r in evidence)), survivors, notes))
        alignments.extend(AlignmentRow(p["id"], p["trial"], *point) for point in points)
    return ComparisonResult(capture.manifest.capture_id, hypotheses.sha256, tuple(results), tuple(alignments))
