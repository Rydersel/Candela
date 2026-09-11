"""Source-translated PontusM RTINGS-style retention classifier."""

from __future__ import annotations

from dataclasses import dataclass, field

from .types import FrameStats


@dataclass
class RetentionDetector:
    """The version-18 and version-20 function bodies are source-identical."""

    sample_counter: int = 0
    previous_columns: list[int] = field(default_factory=lambda: [0] * 32)
    candidate_history: list[bool] = field(default_factory=lambda: [False] * 5)
    retention: bool = False

    def step(self, frame: FrameStats) -> bool:
        if self.sample_counter == 0:
            histogram = frame.histogram
            dominant = 1
            dominant_value = 0
            for index in range(1, 32):
                if histogram[index] > dominant_value:
                    dominant_value = histogram[index]
                    dominant = index

            if dominant == 1:
                dominant_sum = histogram[1] + histogram[2]
            elif dominant == 31:
                dominant_sum = histogram[31] + histogram[30]
            elif histogram[dominant - 1] > histogram[dominant + 1]:
                dominant_sum = histogram[dominant] + histogram[dominant - 1]
            else:
                dominant_sum = histogram[dominant] + histogram[dominant + 1]

            mean_left = sum(frame.mean_columns[6:13]) >> 3
            mean_right = sum(frame.mean_columns[19:26]) >> 2
            mean_difference_threshold = 0 if mean_left < 200 else (mean_right >> 4) + 30
            mean_lr_difference = abs(mean_left - mean_right)

            hue_max_count = sum(value > 50 for value in frame.hue)
            hue_min_count = sum(value < 5 for value in frame.hue)
            flat_row_max = max(frame.mean_rows)
            flat_row_min = min(frame.mean_rows)

            temporal_column_max = max(
                abs(self.previous_columns[index] - frame.mean_columns[index])
                for index in range(3, 29)
            )
            for index in range(3, 29):
                self.previous_columns[index] = frame.mean_columns[index]

            candidate = (
                frame.movie_mode
                and histogram[0] > 28_000
                and dominant_sum > 18_000
                and frame.pattern_probability > 700
                and mean_lr_difference < mean_difference_threshold
                and (flat_row_max >> 1) < flat_row_min
                and temporal_column_max < 7
                and hue_max_count > 2
                and hue_min_count > 20
            )

            if frame.black_probability == 1023:
                self.retention = False
            else:
                self.retention = candidate or any(self.candidate_history)
            self.candidate_history = self.candidate_history[1:] + [candidate]

        self.sample_counter = self.sample_counter + 1 if self.sample_counter < 10 else 0
        return self.retention
