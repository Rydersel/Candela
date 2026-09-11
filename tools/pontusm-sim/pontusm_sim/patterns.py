"""Source-visible pattern exclusions used by PontusM local protection."""

from __future__ import annotations

from dataclasses import dataclass, field

from .types import AlgorithmVersion, FrameStats


@dataclass(frozen=True)
class PatternResult:
    flat: bool
    standard: bool
    hdr_color: bool
    local_allowed: bool
    standard_counter: int
    symmetry: int


@dataclass
class PatternDetector:
    version: AlgorithmVersion
    standard_counter: int = 0
    _standard_history: list[bool] = field(default_factory=lambda: [False] * 3)
    _color_history: list[bool] = field(default_factory=lambda: [False] * 3)
    _standard: bool = False
    _hdr_color: bool = False
    _symmetry: int = 0

    @staticmethod
    def _symmetry_score(frame: FrameStats) -> int:
        column_differences = [
            abs(frame.mean_columns[index] - frame.mean_columns[31 - index])
            >> (2 if index < 6 else 0)
            for index in range(16)
        ]
        row_differences = [
            abs(frame.mean_rows[index] - frame.mean_rows[15 - index])
            >> (2 if index < 4 else 0)
            for index in range(8)
        ]
        column_second = sorted(column_differences, reverse=True)[1]
        row_second = sorted(row_differences, reverse=True)[1]
        if frame.black_probability > 0:
            current = min(column_second, row_second) >> 2
        else:
            current = min(column_second, row_second)
        return min(256, current)

    def _color_candidate(self, frame: FrameStats) -> bool:
        threshold = 900 if self.version is AlgorithmVersion.V18 else 850
        return bool(
            frame.movie_mode
            and frame.hdr
            and frame.black_probability > 450
            and frame.pattern_probability > 700
            and all(frame.max_columns[index] > threshold for index in (4, 5, 6, 15, 16, 25, 26, 27))
            and all(frame.max_columns[index] < 8 for index in (10, 21))
            and all(frame.max_rows[index] < 8 for index in (5, 10))
            and all(frame.max_rows[index] > threshold for index in (2, 13))
        )

    def step(self, frame: FrameStats, *, evaluate: bool = True) -> PatternResult:
        flat = max(
            abs(maximum - mean)
            for maximum, mean in zip(frame.max_rows, frame.mean_rows, strict=True)
        ) < 10

        if evaluate:
            current_symmetry = self._symmetry_score(frame)
            if current_symmetry > self._symmetry:
                self._symmetry = min(256, self._symmetry + 4)
            elif current_symmetry < self._symmetry:
                self._symmetry = max(0, self._symmetry - 4)

            standard_candidate = bool(
                self._symmetry <= 24
                and frame.flat_probability >= 700
                and not frame.motion
                and frame.pattern_probability >= 700
            )
            if standard_candidate or any(self._standard_history):
                self.standard_counter = min(32, self.standard_counter + 1)
            else:
                self.standard_counter = 0
            self._standard = self.standard_counter > 30
            self._standard_history = self._standard_history[1:] + [standard_candidate]

            color_candidate = self._color_candidate(frame)
            self._hdr_color = color_candidate and all(self._color_history)
            self._color_history = self._color_history[1:] + [color_candidate]

        return PatternResult(
            flat=flat,
            standard=self._standard,
            hdr_color=self._hdr_color,
            local_allowed=not (flat or self._standard or self._hdr_color),
            standard_counter=self.standard_counter,
            symmetry=self._symmetry,
        )
