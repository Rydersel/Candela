"""Strict, offline loading of authenticated observation packages.

Schema 1 channel values are preserved, never calibrated or normalized here:
phase/event labels use nonblank strings and ``none``; controls use bool/speed
0..2 and ``none``; offsets use integer ``{x, y}`` and ``px``; luminance uses
finite nonnegative numbers and ``ratio``; temperature uses uint16 and ``raw``;
registers use ``{operation: read|write, address: uint16, data: [uint8, ...]}``
and ``none``. Event labels are capture vocabulary, not inferred model events.

A SHA-256 binds the exact observation bytes to the supplied manifest; it does
not independently prove the capture's origin or establish hardware provenance.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
from types import MappingProxyType
from typing import Mapping


Scalar = str | bool | int | float
ObservationValue = Scalar | Mapping[str, Scalar | tuple[int, ...]]


@dataclass(frozen=True)
class CaptureManifest:
    schema_version: int
    capture_id: str
    device: Mapping[str, str]
    timebase: Mapping[str, str | int]
    observations: Mapping[str, str]
    calibration: Mapping[str, int | bool]
    notes: str | None = None


@dataclass(frozen=True)
class Observation:
    trial: str
    sequence: int
    time_us: int
    channel: str
    value: ObservationValue
    unit: str
    quality: str
    sources: tuple[int, ...] = ()


@dataclass(frozen=True)
class CapturePackage:
    manifest: CaptureManifest
    observations: tuple[Observation, ...]
    manifest_sha256: str
    observations_sha256: str


def _object(value: object, required: set[str], optional: set[str], label: str) -> dict:
    if type(value) is not dict:
        raise ValueError(f"{label} must be an object")
    if required - value.keys():
        raise ValueError(f"{label} is missing required fields")
    if value.keys() - required - optional:
        raise ValueError(f"{label} has unknown fields")
    return value


def _string(value: object, label: str) -> str:
    if type(value) is not str or not value.strip():
        raise ValueError(f"{label} must be a nonblank string")
    return value


def _integer(value: object, label: str, minimum: int = 0, maximum: int | None = None) -> int:
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f"{label} must be an integer in range")
    return value


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _invalid_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def _finite_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("non-finite JSON number")
    return number


def _json(raw: bytes | str, label: str) -> object:
    try:
        text = raw.decode("utf-8") if isinstance(raw, bytes) else raw
        return json.loads(text, object_pairs_hook=_unique_object,
                          parse_constant=_invalid_constant, parse_float=_finite_float)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ValueError(f"invalid {label}: {error}") from error


def _member_parts(value: object) -> tuple[str, ...]:
    path = _string(value, "observations.path")
    parts = tuple(path.split("/"))
    # POSIX relative members are portable; forbid Windows drive/separator forms.
    if "\\" in path or ":" in path or "\x00" in path or any(p in ("", ".", "..") for p in parts):
        raise ValueError("observation path must be relative without traversal")
    return parts


def _read_member(directory_fd: int, parts: tuple[str, ...], label: str) -> bytes:
    """Open each component without following links; reject FIFOs before reading.

    Directory-relative opens keep traversal inside the pinned capture directory
    even when directory names change concurrently. O_NONBLOCK prevents a raced
    replacement by a FIFO from blocking before fstat can reject it.
    """
    current_fd = os.dup(directory_fd)
    file_fd = None
    try:
        for part in parts[:-1]:
            child_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                               dir_fd=current_fd)
            os.close(current_fd)
            current_fd = child_fd
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                          dir_fd=current_fd)
        if not stat.S_ISREG(os.fstat(file_fd).st_mode):
            raise ValueError(f"{label} must be a regular file, not a symlink")
        with os.fdopen(file_fd, "rb") as stream:
            file_fd = None
            return stream.read()
    except OSError as error:
        raise ValueError(f"cannot read regular {label}: {error.strerror}") from error
    finally:
        if file_fd is not None:
            os.close(file_fd)
        os.close(current_fd)


def _manifest(payload: object) -> CaptureManifest:
    root = _object(payload, {"schema_version", "capture_id", "device", "timebase",
                             "observations", "calibration"}, {"notes"}, "manifest")
    _integer(root["schema_version"], "schema_version", 1, 1)
    _string(root["capture_id"], "capture_id")
    device = _object(root["device"], {"model", "firmware", "panel"}, set(), "device")
    for key, value in device.items():
        _string(value, f"device.{key}")
    timebase = _object(root["timebase"], {"unit", "uncertainty_us"}, set(), "timebase")
    if timebase["unit"] != "us":
        raise ValueError("timebase.unit must be us")
    _integer(timebase["uncertainty_us"], "timebase.uncertainty_us")
    observations = _object(root["observations"], {"path", "sha256"}, set(), "observations")
    _member_parts(observations["path"])
    digest = observations["sha256"]
    if type(digest) is not str or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ValueError("observations.sha256 must be 64 lowercase hex characters")
    calibration = _object(root["calibration"], {"x_sign", "y_sign", "swap_axes"}, set(), "calibration")
    for key in ("x_sign", "y_sign"):
        sign = _integer(calibration[key], f"calibration.{key}", -1, 1)
        if sign == 0:
            raise ValueError(f"calibration.{key} must be -1 or 1")
    if type(calibration["swap_axes"]) is not bool:
        raise ValueError("calibration.swap_axes must be bool")
    if "notes" in root and type(root["notes"]) is not str:
        raise ValueError("notes must be a string")
    return CaptureManifest(root["schema_version"], root["capture_id"],
        MappingProxyType(device), MappingProxyType(timebase), MappingProxyType(observations),
        MappingProxyType(calibration), root.get("notes"))


_UNITS = {
    "stimulus.phase": "none", "control.pixel_shift_enabled": "none",
    "control.pixel_shift_speed": "none", "display.offset_px": "px",
    "display.roi_luma_ratio": "ratio", "display.control_luma_ratio": "ratio",
    "display.uniform_luma_ratio": "ratio", "panel.temperature_raw": "raw",
    "panel.off_sensing_event": "none", "msi.register.transaction": "none",
}


def _channel_value(channel: str, value: object) -> ObservationValue:
    if channel in ("stimulus.phase", "panel.off_sensing_event"):
        return _string(value, f"{channel}.value")
    if channel == "control.pixel_shift_enabled":
        if type(value) is not bool:
            raise ValueError("pixel shift enabled must be bool")
    elif channel == "control.pixel_shift_speed":
        _integer(value, "pixel shift speed", 0, 2)
    elif channel == "panel.temperature_raw":
        _integer(value, "temperature raw", 0, 65535)
    elif channel == "display.offset_px":
        offsets = _object(value, {"x", "y"}, set(), "offset")
        if any(type(axis) is not int for axis in offsets.values()):
            raise ValueError("offset axes must be integers")
        return MappingProxyType(offsets)
    elif channel.endswith("luma_ratio"):
        if type(value) not in (int, float) or value < 0 or (type(value) is float and not math.isfinite(value)):
            raise ValueError("luminance ratio must be a finite nonnegative number")
    elif channel == "msi.register.transaction":
        transaction = _object(value, {"operation", "address", "data"}, set(), "register transaction")
        if transaction["operation"] not in ("read", "write"):
            raise ValueError("register operation must be read or write")
        _integer(transaction["address"], "register address", 0, 65535)
        data = transaction["data"]
        if type(data) is not list or not data:
            raise ValueError("register data must be a nonempty byte array")
        for byte in data:
            _integer(byte, "register byte", 0, 255)
        return MappingProxyType({**transaction, "data": tuple(data)})
    return value


def _observation(payload: object, prior: dict[str, dict[int, int]]) -> Observation:
    row = _object(payload, {"trial", "sequence", "time_us", "channel", "value", "unit", "quality"},
                  {"sources"}, "observation")
    trial = _string(row["trial"], "trial")
    sequence = _integer(row["sequence"], "sequence")
    time_us = _integer(row["time_us"], "time_us")
    channel = _string(row["channel"], "channel")
    if channel not in _UNITS:
        raise ValueError(f"unsupported observation channel: {channel}")
    if row["unit"] != _UNITS[channel]:
        raise ValueError(f"{channel} unit must be {_UNITS[channel]}")
    if row["quality"] not in ("measured", "decoded", "derived"):
        raise ValueError("quality must be measured, decoded, or derived")
    previous = prior.get(trial, {})
    if previous:
        last = next(reversed(previous))
        if sequence <= last:
            raise ValueError("sequence must strictly increase within each trial")
        if time_us < previous[last]:
            raise ValueError("time_us must not decrease within each trial")
    sources = row.get("sources", [])
    if type(sources) is not list:
        raise ValueError("sources must be an array")
    if row["quality"] == "derived":
        if not sources:
            raise ValueError("derived observations require sources")
        seen = set()
        for source in sources:
            _integer(source, "source sequence")
            if source in seen or source not in previous:
                raise ValueError("sources must be unique prior sequences in the same trial")
            seen.add(source)
    elif sources:
        raise ValueError("only derived observations can claim sources")
    value = _channel_value(channel, row["value"])
    return Observation(trial, sequence, time_us, channel, value, row["unit"], row["quality"], tuple(sources))


def load_capture(path: str | Path) -> CapturePackage:
    """Validate the complete capture, returning immutable evidence without writes.

    All observation bytes are hashed before UTF-8 decoding or JSON parsing. The
    manifest directory anchors member lookup; symlinks in member paths and at
    the manifest leaf are rejected. Missing or malformed input raises ValueError.
    """
    manifest_path = Path(path)
    try:
        directory_fd = os.open(manifest_path.parent.resolve(), os.O_RDONLY | os.O_DIRECTORY)
    except (OSError, ValueError, RuntimeError) as error:
        raise ValueError(f"cannot open capture directory: {error}") from error
    try:
        manifest_raw = _read_member(directory_fd, (manifest_path.name,), "capture manifest")
        manifest = _manifest(_json(manifest_raw, "manifest JSON"))
        raw = _read_member(directory_fd, _member_parts(manifest.observations["path"]), "observations")
    finally:
        os.close(directory_fd)
    digest = hashlib.sha256(raw).hexdigest()
    if digest != manifest.observations["sha256"]:
        raise ValueError("observation SHA-256 mismatch")
    if not raw:
        raise ValueError("observation stream must not be empty")
    # Split on LF only: JSON whitespace is not a license to skip blank records.
    lines = raw.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    result = []
    prior: dict[str, dict[int, int]] = {}
    for line_number, line in enumerate(lines, 1):
        row = _observation(_json(line, f"observation line {line_number}"), prior)
        prior.setdefault(row.trial, {})[row.sequence] = row.time_us
        result.append(row)
    return CapturePackage(manifest, tuple(result), hashlib.sha256(manifest_raw).hexdigest(), digest)
