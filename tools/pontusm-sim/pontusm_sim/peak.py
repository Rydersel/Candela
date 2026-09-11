"""Nested peak accumulator used for the anti-block-residue value."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class PeakAccumulator:
    sample_counter: int = 0
    window_counter: int = 0
    write_index: int = 0
    column_sums: list[int] = field(default_factory=lambda: [0] * 16)
    row_sums: list[int] = field(default_factory=lambda: [0] * 8)
    column_ring: list[list[int]] = field(
        default_factory=lambda: [[0] * 36 for _ in range(16)]
    )
    row_ring: list[list[int]] = field(
        default_factory=lambda: [[0] * 36 for _ in range(8)]
    )
    result: int = 0
    sample_events: int = 0
    window_events: int = 0

    def step(
        self, max_columns: list[int], max_rows: list[int], *, enabled: bool
    ) -> int:
        self.sample_counter = self.sample_counter + 1 if self.sample_counter < 37 else 0
        if self.sample_counter != 37:
            return self.result

        self.sample_events += 1
        self.window_counter = self.window_counter + 1 if self.window_counter < 9 else 0
        merge_columns = [
            (max(max_columns[index * 2 : index * 2 + 2]) >> 3) if enabled else 0
            for index in range(16)
        ]
        merge_rows = [
            (max(max_rows[index * 2 : index * 2 + 2]) >> 3) if enabled else 0
            for index in range(8)
        ]

        if self.window_counter == 9:
            self.window_events += 1
            self.write_index = self.write_index + 1 if self.write_index < 35 else 0
            for index in range(16):
                self.column_ring[index][self.write_index] = self.column_sums[index]
            for index in range(8):
                self.row_ring[index][self.write_index] = self.row_sums[index]
            maximum_column = max(sum(values) for values in self.column_ring)
            maximum_row = max(sum(values) for values in self.row_ring)
            self.result = min(maximum_column, maximum_row) >> 4
            self.column_sums[:] = merge_columns
            self.row_sums[:] = merge_rows
        else:
            self.column_sums[:] = [
                total + sample for total, sample in zip(self.column_sums, merge_columns, strict=True)
            ]
            self.row_sums[:] = [
                total + sample for total, sample in zip(self.row_sums, merge_rows, strict=True)
            ]
        return self.result
