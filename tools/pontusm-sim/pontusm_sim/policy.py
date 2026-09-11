"""Version-20 split screen-saver and source-labelled ISP policy bits."""

from __future__ import annotations

from dataclasses import dataclass, field

from .patterns import PatternResult
from .types import AlgorithmVersion, FrameStats


@dataclass(frozen=True)
class PolicyResult:
    feature_available: bool
    screen_saver_off: bool | None
    isp_off: bool | None
    encoded_state: int | None
    no_still_counter: int | None


@dataclass
class ProtectionPolicy:
    version: AlgorithmVersion
    no_still_phase: int = 0
    no_still_counter: int = 0
    previous_columns: list[int] = field(default_factory=lambda: [0] * 32)
    previous_rows: list[int] = field(default_factory=lambda: [0] * 16)

    def step(
        self,
        frame: FrameStats,
        patterns: PatternResult,
        retention_count: int,
        *,
        evaluate: bool = True,
    ) -> PolicyResult:
        if self.version is AlgorithmVersion.V18:
            return PolicyResult(False, None, None, None, None)
        active_retention_count = (
            0 if self.version is AlgorithmVersion.V22 else retention_count
        )
        if not evaluate:
            screen_saver_off = self.no_still_counter > 0 or active_retention_count > 400
            isp_off = (
                active_retention_count > 400
                or patterns.hdr_color
                or patterns.standard
            )
            return PolicyResult(
                True,
                screen_saver_off,
                isp_off,
                (int(screen_saver_off) << 1) + int(isp_off),
                self.no_still_counter,
            )

        if self.no_still_phase == 0:
            maximum_difference = max(
                [
                    abs(old - new)
                    for old, new in zip(
                        self.previous_columns, frame.mean_columns, strict=True
                    )
                ]
                + [
                    abs(old - new)
                    for old, new in zip(self.previous_rows, frame.mean_rows, strict=True)
                ]
            )
            self.previous_columns[:] = frame.mean_columns
            self.previous_rows[:] = frame.mean_rows
            if maximum_difference > 30 or frame.motion:
                self.no_still_counter = 30
            else:
                self.no_still_counter = max(0, self.no_still_counter - 1)
        self.no_still_phase = self.no_still_phase + 1 if self.no_still_phase < 7 else 0

        isp_off = (
            active_retention_count > 400
            or patterns.hdr_color
            or patterns.standard
        )
        screen_saver_off = active_retention_count > 400 or self.no_still_counter > 0
        return PolicyResult(
            feature_available=True,
            screen_saver_off=screen_saver_off,
            isp_off=isp_off,
            encoded_state=(int(screen_saver_off) << 1) + int(isp_off),
            no_still_counter=self.no_still_counter,
        )
