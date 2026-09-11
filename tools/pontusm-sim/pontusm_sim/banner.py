"""Version-20/22 lower-screen banner detector (named CNN in the source)."""

from __future__ import annotations

from dataclasses import dataclass, field

from .arithmetic import linear_interpolate
from .types import AlgorithmVersion, FrameStats


@dataclass(frozen=True)
class BannerResult:
    feature_available: bool
    raw_probability: int
    probability: int
    history_count: int
    zero_run: int
    geometry_qualified: bool
    boxes_detected: tuple[bool, ...]


@dataclass
class BannerDetector:
    version: AlgorithmVersion = AlgorithmVersion.V20
    raw_probability: int = 0
    calculation_counter: int = 0
    previous_apl_minima: list[int] = field(default_factory=lambda: [0] * 4)
    apl_cumulative: list[int] = field(default_factory=lambda: [0] * 4)
    previous_rgb_spreads: list[int] = field(default_factory=lambda: [0] * 4)
    rgb_delay_differences: list[int] = field(default_factory=lambda: [0] * 4)
    history: list[bool] = field(default_factory=lambda: [False] * 180)
    zero_run: int = 0

    def __post_init__(self) -> None:
        self.version = AlgorithmVersion.parse(self.version)
        if self.version is AlgorithmVersion.V18:
            raise ValueError("banner detection is unavailable for version 18")

    @property
    def history_count(self) -> int:
        return sum(self.history)

    def reset(self, *, fill: bool = False) -> None:
        self.history[:] = [fill] * 180
        self.calculation_counter = 0
        self.zero_run = 0

    def step(
        self,
        frame: FrameStats,
        *,
        retention_count: int = 0,
        hdr_color: bool = False,
        standard_pattern: bool = False,
    ) -> BannerResult:
        columns = sum(frame.max_columns[index] > 820 for index in range(2, 30))
        rows = sum(frame.max_rows[index] > 900 for index in range(11, 15))
        geometry = columns >= 26 and rows >= 2

        minima = [min(rgb) for rgb in frame.banner_rgb]
        if self.calculation_counter % 80 == 1:
            for index, minimum in enumerate(minima):
                difference = abs(minimum - self.previous_apl_minima[index])
                self.previous_apl_minima[index] = minimum
                self.apl_cumulative[index] = (
                    min(200, self.apl_cumulative[index] + 10)
                    if difference < 5
                    else 0
                )

        spreads = [
            max(abs(red - green), abs(green - blue), abs(blue - red))
            for red, green, blue in frame.banner_rgb
        ]
        if self.calculation_counter % 200 == 1:
            for index, spread in enumerate(spreads):
                self.rgb_delay_differences[index] = abs(
                    spread - self.previous_rgb_spreads[index]
                )
                self.previous_rgb_spreads[index] = spread

        rgb_threshold = 25 if frame.movie_mode else 110
        boxes = tuple(
            minimum + cumulative > 460
            and spread < rgb_threshold
            and delay < 20
            for minimum, cumulative, spread, delay in zip(
                minima,
                self.apl_cumulative,
                spreads,
                self.rgb_delay_differences,
                strict=True,
            )
        )
        if geometry and any(boxes):
            self.raw_probability = min(800, self.raw_probability + 1)
        else:
            self.raw_probability = max(0, self.raw_probability - 1)

        combined_flat_black = min(
            1024, frame.flat_probability + frame.black_probability
        )
        discount = linear_interpolate(combined_flat_black, 650, 900, 0, 512)
        probability = (self.raw_probability * (512 - discount)) >> 9
        if (
            self.version is not AlgorithmVersion.V22 and retention_count > 400
        ) or hdr_color:
            probability = 0
        if frame.black_probability == 0 and standard_pattern:
            probability = 0

        if self.calculation_counter == 0:
            first = probability > 400
            self.history[1:] = self.history[:-1]
            self.history[0] = first
            if first:
                self.zero_run = 0
            else:
                self.zero_run = min(180, self.zero_run + 1)

        self.calculation_counter = (
            self.calculation_counter + 1
            if self.calculation_counter < 400
            else 0
        )
        return BannerResult(
            feature_available=True,
            raw_probability=self.raw_probability,
            probability=probability,
            history_count=self.history_count,
            zero_run=self.zero_run,
            geometry_qualified=geometry,
            boxes_detected=boxes,
        )
