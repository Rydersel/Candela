import unittest

from pontusm_sim.patterns import PatternDetector
from pontusm_sim.types import AlgorithmVersion, FrameStats


def color_frame(threshold_value: int) -> FrameStats:
    frame = FrameStats.neutral()
    frame.movie_mode = True
    frame.hdr = True
    frame.black_probability = 451
    frame.pattern_probability = 701
    for index in (4, 5, 6, 15, 16, 25, 26, 27):
        frame.max_columns[index] = threshold_value
    for index in (10, 21):
        frame.max_columns[index] = 7
    for index in (5, 10):
        frame.max_rows[index] = 7
    for index in (2, 13):
        frame.max_rows[index] = threshold_value
    return frame


class PatternDetectorTests(unittest.TestCase):
    def test_flat_requires_every_absolute_row_difference_below_ten(self):
        detector = PatternDetector(AlgorithmVersion.V20)
        frame = FrameStats.neutral()
        frame.mean_rows = [100] * 16
        frame.max_rows = [109] * 16
        self.assertTrue(detector.step(frame).flat)
        frame.max_rows[3] = 110
        self.assertFalse(detector.step(frame).flat)

    def test_hdr_color_requires_four_evaluations_and_version_threshold(self):
        old = PatternDetector(AlgorithmVersion.V18)
        new = PatternDetector(AlgorithmVersion.V20)
        frame = color_frame(851)
        for _ in range(3):
            self.assertFalse(new.step(frame).hdr_color)
        self.assertTrue(new.step(frame).hdr_color)
        for _ in range(4):
            self.assertFalse(old.step(frame).hdr_color)

        old_frame = color_frame(901)
        for _ in range(3):
            old.step(old_frame)
        self.assertTrue(old.step(old_frame).hdr_color)

    def test_standard_pattern_sets_after_counter_exceeds_thirty(self):
        detector = PatternDetector(AlgorithmVersion.V20)
        frame = FrameStats.neutral()
        frame.mean_columns = [300] * 32
        frame.mean_rows = [300] * 16
        frame.flat_probability = 700
        frame.pattern_probability = 700
        frame.motion = False
        for _ in range(30):
            self.assertFalse(detector.step(frame).standard)
        self.assertTrue(detector.step(frame).standard)
        self.assertEqual(detector.step(frame, evaluate=False).standard_counter, 31)


if __name__ == "__main__":
    unittest.main()
