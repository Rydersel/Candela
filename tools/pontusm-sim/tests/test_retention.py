import copy
import unittest

from pontusm_sim.retention import RetentionDetector
from pontusm_sim.types import FrameStats


def qualifying_frame() -> FrameStats:
    frame = FrameStats.neutral()
    frame.movie_mode = True
    frame.pattern_probability = 701
    frame.histogram[0] = 28_001
    frame.histogram[1] = 10_000
    frame.histogram[2] = 9_000
    frame.mean_columns[6:13] = [400] * 7
    frame.mean_columns[19:26] = [200] * 7
    frame.mean_rows = [200] * 16
    frame.hue[:3] = [51, 51, 51]
    return frame


def advance_to_second_sample(detector: RetentionDetector, frame: FrameStats) -> bool:
    result = detector.step(frame)
    for _ in range(10):
        result = detector.step(frame)
    return detector.step(frame)


class RetentionDetectorTests(unittest.TestCase):
    def test_stable_source_valid_statistics_form_a_candidate(self):
        detector = RetentionDetector()
        self.assertTrue(advance_to_second_sample(detector, qualifying_frame()))

    def test_each_source_threshold_is_strict(self):
        cases = {
            "histogram_zero": lambda frame: frame.histogram.__setitem__(0, 28_000),
            "dominant_sum": lambda frame: (
                frame.histogram.__setitem__(1, 9_000),
                frame.histogram.__setitem__(2, 9_000),
            ),
            "pattern_probability": lambda frame: setattr(frame, "pattern_probability", 700),
            "temporal_delta": lambda frame: frame.mean_columns.__setitem__(3, 7),
            "hue_max_count": lambda frame: frame.hue.__setitem__(2, 0),
            "hue_min_count": lambda frame: frame.hue.__setitem__(
                slice(3, 15), [5] * 12
            ),
            "row_flatness": lambda frame: frame.mean_rows.__setitem__(0, 400),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                frame = qualifying_frame()
                detector = RetentionDetector()
                detector.step(frame)
                for _ in range(10):
                    detector.step(frame)
                changed = copy.deepcopy(frame)
                mutate(changed)
                self.assertFalse(detector.step(changed))

    def test_candidate_is_held_for_five_later_samples(self):
        detector = RetentionDetector()
        self.assertTrue(advance_to_second_sample(detector, qualifying_frame()))
        miss = qualifying_frame()
        miss.movie_mode = False
        for held_sample in range(5):
            for _ in range(11):
                result = detector.step(miss)
            self.assertTrue(result, held_sample)
        for _ in range(11):
            result = detector.step(miss)
        self.assertFalse(result)

    def test_all_black_clears_on_the_next_retention_sample(self):
        detector = RetentionDetector()
        self.assertTrue(advance_to_second_sample(detector, qualifying_frame()))
        black = qualifying_frame()
        black.black_probability = 1023
        for _ in range(11):
            result = detector.step(black)
        self.assertFalse(result)


if __name__ == "__main__":
    unittest.main()
