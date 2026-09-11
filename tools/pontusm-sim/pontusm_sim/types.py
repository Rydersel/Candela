"""Validated inputs and immutable observable outputs for the simulator."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, IntEnum


class AlgorithmVersion(IntEnum):
    V18 = 18
    V20 = 20
    V22 = 22

    @classmethod
    def parse(cls, value: str | int) -> "AlgorithmVersion":
        try:
            return cls(int(value))
        except (TypeError, ValueError):
            raise ValueError("supported versions are 18, 20, and 22") from None


class LogoBrightness(IntEnum):
    OFF = 0
    LOW = 1
    HIGH = 2


class Fidelity(str, Enum):
    SOURCE_TRANSLATED = "source-translated"
    SOURCE_ABSTRACTED = "source-abstracted"
    UNAVAILABLE = "unavailable"


def _zeros(count: int) -> list[int]:
    return [0] * count


@dataclass
class FrameStats:
    """One nominal 20 ms set of hardware summaries consumed by PontusM."""

    mean_columns: list[int] = field(default_factory=lambda: _zeros(32))
    max_columns: list[int] = field(default_factory=lambda: _zeros(32))
    mean_rows: list[int] = field(default_factory=lambda: _zeros(16))
    max_rows: list[int] = field(default_factory=lambda: _zeros(16))
    histogram: list[int] = field(default_factory=lambda: _zeros(32))
    hue: list[int] = field(default_factory=lambda: _zeros(35))
    region_gains: list[int] = field(default_factory=lambda: [255] * 225)
    banner_rgb: list[tuple[int, int, int]] = field(
        default_factory=lambda: [(0, 0, 0)] * 4
    )

    pattern_probability: int = 0
    black_probability: int = 0
    flat_probability: int = 0
    image_mean: int = 0
    brightness: int = 1024
    osd_area: int = 0
    app_area: int = 0
    spi_analog: int = 0
    spi_threshold: int = 0
    lpc_shape1_gain: int = 0
    lpc_shape2_gain: int = 0

    movie_mode: bool = False
    pc_mode: bool = False
    hdr: bool = False
    motion: bool = True
    scene_changed: bool = False
    capture_error: bool = False
    portrait: bool = False
    dormant: bool = False
    qd_enabled: bool = True
    local_feature_enabled: bool = True
    factory_mode: bool = False
    logo_brightness: LogoBrightness = LogoBrightness.LOW

    @classmethod
    def neutral(cls) -> "FrameStats":
        return cls()

    def validate(self) -> None:
        vectors = (
            ("mean_columns", self.mean_columns, 32, 0, 1023),
            ("max_columns", self.max_columns, 32, 0, 1023),
            ("mean_rows", self.mean_rows, 16, 0, 1023),
            ("max_rows", self.max_rows, 16, 0, 1023),
            ("histogram", self.histogram, 32, 0, 0xFFFF_FFFF),
            ("hue", self.hue, 35, 0, 1023),
            ("region_gains", self.region_gains, 225, 0, 255),
        )
        for name, values, length, low, high in vectors:
            if len(values) != length:
                raise ValueError(f"{name} must contain {length} values")
            if any(not isinstance(value, int) or not low <= value <= high for value in values):
                raise ValueError(f"{name} values must be integers in {low}...{high}")

        if len(self.banner_rgb) != 4:
            raise ValueError("banner_rgb must contain 4 RGB triples")
        for triple in self.banner_rgb:
            if len(triple) != 3 or any(
                not isinstance(value, int) or not 0 <= value <= 1023 for value in triple
            ):
                raise ValueError("banner_rgb values must be four RGB triples in 0...1023")

        scalars = (
            ("pattern_probability", self.pattern_probability, 0, 1024),
            ("black_probability", self.black_probability, 0, 1023),
            ("flat_probability", self.flat_probability, 0, 1024),
            ("image_mean", self.image_mean, 0, 1023),
            ("brightness", self.brightness, 0, 1024),
            ("osd_area", self.osd_area, 0, 0xFFFF_FFFF),
            ("app_area", self.app_area, 0, 0xFFFF_FFFF),
            ("spi_analog", self.spi_analog, 0, 0xFFFF_FFFF),
            ("spi_threshold", self.spi_threshold, 0, 0xFFFF_FFFF),
            ("lpc_shape1_gain", self.lpc_shape1_gain, 0, 256),
            ("lpc_shape2_gain", self.lpc_shape2_gain, 0, 256),
        )
        for name, value, low, high in scalars:
            if not isinstance(value, int) or not low <= value <= high:
                raise ValueError(f"{name} must be an integer in {low}...{high}")

        if not isinstance(self.logo_brightness, LogoBrightness):
            raise ValueError("logo_brightness must be Off, Low, or High")

        boolean_fields = (
            "movie_mode",
            "pc_mode",
            "hdr",
            "motion",
            "scene_changed",
            "capture_error",
            "portrait",
            "dormant",
            "qd_enabled",
            "local_feature_enabled",
            "factory_mode",
        )
        for name in boolean_fields:
            if not isinstance(getattr(self, name), bool):
                raise ValueError(f"{name} must be boolean")


@dataclass(frozen=True)
class QDOutputs:
    tick: int
    flat: bool
    standard_pattern: bool
    hdr_color_pattern: bool
    retention: bool
    retention_available: bool
    retention_count: int
    local_strength: int
    local_target_strength: int
    app_counter: int
    app_duty: int
    anti_residue: int
    fcn_gain: int
    fcn_available: bool
    curve: tuple[int, ...]
    region_duties: tuple[int, ...]
    srp_center_mask_gain: int | None
    srp_board_mask_gain: int | None
    banner_available: bool
    banner_probability: int | None
    banner_history: int | None
    screen_saver_off: bool | None
    isp_off: bool | None
    policy_state: int | None


@dataclass(frozen=True)
class QDStateSnapshot:
    tick: int
    retention_count: int
    fcn_gain: int
    local_strength: int
    app_counter: int
    anti_residue: int
    banner_probability: int | None
    banner_history: int | None
