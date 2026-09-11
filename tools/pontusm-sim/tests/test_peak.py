import unittest

from pontusm_sim.peak import PeakAccumulator


class PeakAccumulatorTests(unittest.TestCase):
    def test_nested_37_9_cadence_matches_source_counter_order(self):
        peak = PeakAccumulator()
        columns = [80] * 32
        rows = [64] * 16
        for _ in range(340):
            self.assertEqual(peak.step(columns, rows, enabled=True), 0)
        self.assertEqual(peak.step(columns, rows, enabled=True), 4)
        self.assertEqual(peak.sample_events, 9)
        self.assertEqual(peak.window_events, 1)
        self.assertEqual(peak.result, 4)

    def test_pair_merge_uses_max_then_shift_three(self):
        peak = PeakAccumulator(sample_counter=36, window_counter=8)
        columns = [0] * 32
        rows = [0] * 16
        columns[1] = 1023
        rows[1] = 511
        result = peak.step(columns, rows, enabled=True)
        self.assertEqual(peak.column_ring[1][peak.write_index], 0)
        self.assertEqual(peak.column_ring[0][peak.write_index], 0)
        # The source stores the preceding sum, then seeds the next window.
        self.assertEqual(peak.column_sums[0], 127)
        self.assertEqual(peak.row_sums[0], 63)
        self.assertEqual(result, 0)

    def test_disabled_sampling_contributes_zero(self):
        peak = PeakAccumulator(sample_counter=36)
        peak.step([1023] * 32, [1023] * 16, enabled=False)
        self.assertEqual(peak.column_sums, [0] * 16)
        self.assertEqual(peak.row_sums, [0] * 8)


if __name__ == "__main__":
    unittest.main()
