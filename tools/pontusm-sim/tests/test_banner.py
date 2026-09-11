import unittest

from pontusm_sim.banner import BannerDetector
from pontusm_sim.types import AlgorithmVersion, FrameStats


def qualifying_banner() -> FrameStats:
    frame = FrameStats.neutral()
    frame.max_columns = [821] * 32
    frame.max_rows = [901] * 16
    frame.banner_rgb = [(500, 500, 500)] * 4
    return frame


class BannerDetectorTests(unittest.TestCase):
    def test_probability_attacks_caps_and_releases(self):
        detector = BannerDetector()
        frame = qualifying_banner()
        for _ in range(900):
            result = detector.step(frame)
        self.assertEqual(result.raw_probability, 800)
        frame.max_rows = [0] * 16
        self.assertEqual(detector.step(frame).raw_probability, 799)

    def test_pattern_probability_discount_is_source_linear(self):
        detector = BannerDetector(raw_probability=800)
        frame = qualifying_banner()
        frame.flat_probability = 775
        # Linear 650...900 -> 0...512 gives 256, halving the raw count.
        self.assertEqual(detector.step(frame).probability, 400)

    def test_history_samples_on_401_counter_cycle_and_tracks_zero_run(self):
        detector = BannerDetector()
        frame = qualifying_banner()
        first = detector.step(frame)
        self.assertEqual((first.history_count, first.zero_run), (0, 1))
        for _ in range(400):
            detector.step(frame)
        sampled = detector.step(frame)
        self.assertEqual((sampled.history_count, sampled.zero_run), (1, 0))

    def test_reset_can_fill_or_clear_the_180_slot_history(self):
        detector = BannerDetector()
        detector.reset(fill=True)
        self.assertEqual(detector.history_count, 180)
        detector.reset(fill=False)
        self.assertEqual(detector.history_count, 0)

    def test_version_22_does_not_suppress_probability_for_retention_count(self):
        frame = qualifying_banner()
        old = BannerDetector(AlgorithmVersion.V20, raw_probability=500)
        new = BannerDetector(AlgorithmVersion.V22, raw_probability=500)
        self.assertEqual(old.step(frame, retention_count=401).probability, 0)
        self.assertEqual(new.step(frame, retention_count=401).probability, 501)

    def test_rgb_spread_delay_is_sampled_every_200_calculation_ticks(self):
        detector = BannerDetector(AlgorithmVersion.V22)
        frame = qualifying_banner()
        detector.step(frame)
        detector.step(frame)  # Counter 1 records the initial zero spread.

        frame.banner_rgb = [(500, 550, 500)] * 4
        for _ in range(198):
            before_boundary = detector.step(frame)
        self.assertEqual(detector.calculation_counter, 200)
        self.assertTrue(all(before_boundary.boxes_detected))

        at_counter_200 = detector.step(frame)
        self.assertTrue(all(at_counter_200.boxes_detected))
        sampled_at_201 = detector.step(frame)
        self.assertEqual(detector.rgb_delay_differences, [50] * 4)
        self.assertFalse(any(sampled_at_201.boxes_detected))


if __name__ == "__main__":
    unittest.main()
