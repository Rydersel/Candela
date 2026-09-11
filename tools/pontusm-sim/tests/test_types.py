import copy
import unittest

from pontusm_sim.types import AlgorithmVersion, FrameStats, LogoBrightness


class FrameStatsTests(unittest.TestCase):
    def test_neutral_frame_has_every_source_visible_input_shape(self):
        frame = FrameStats.neutral()
        self.assertEqual(len(frame.mean_columns), 32)
        self.assertEqual(len(frame.max_columns), 32)
        self.assertEqual(len(frame.mean_rows), 16)
        self.assertEqual(len(frame.max_rows), 16)
        self.assertEqual(len(frame.histogram), 32)
        self.assertEqual(len(frame.hue), 35)
        self.assertEqual(len(frame.region_gains), 225)
        self.assertEqual(len(frame.banner_rgb), 4)
        self.assertEqual(frame.logo_brightness, LogoBrightness.LOW)
        self.assertFalse(frame.factory_mode)
        self.assertEqual(frame.lpc_shape1_gain, 0)
        self.assertEqual(frame.lpc_shape2_gain, 0)
        frame.validate()

    def test_frame_rejects_short_column_array(self):
        frame = FrameStats.neutral()
        frame.mean_columns = [0] * 31
        with self.assertRaisesRegex(ValueError, "mean_columns must contain 32"):
            frame.validate()

    def test_frame_rejects_out_of_range_values(self):
        cases = [
            ("pattern_probability", -1),
            ("pattern_probability", 1025),
            ("black_probability", 1024),
            ("image_mean", 1024),
            ("brightness", 1025),
            ("osd_area", -1),
            ("lpc_shape1_gain", 257),
            ("lpc_shape2_gain", -1),
        ]
        for field, value in cases:
            with self.subTest(field=field):
                frame = FrameStats.neutral()
                setattr(frame, field, value)
                with self.assertRaisesRegex(ValueError, field):
                    frame.validate()

    def test_frame_rejects_non_boolean_factory_mode(self):
        frame = FrameStats.neutral()
        frame.factory_mode = 1
        with self.assertRaisesRegex(ValueError, "factory_mode"):
            frame.validate()

    def test_frame_rejects_invalid_array_members_and_banner_shape(self):
        frame = FrameStats.neutral()
        frame.region_gains[12] = 256
        with self.assertRaisesRegex(ValueError, "region_gains"):
            frame.validate()

        frame = FrameStats.neutral()
        frame.banner_rgb = [(0, 0, 0)] * 3
        with self.assertRaisesRegex(ValueError, "banner_rgb must contain 4"):
            frame.validate()

        frame = FrameStats.neutral()
        frame.banner_rgb[0] = (0, -1, 0)
        with self.assertRaisesRegex(ValueError, "banner_rgb"):
            frame.validate()

    def test_neutral_returns_independent_mutable_fixtures(self):
        first = FrameStats.neutral()
        second = copy.deepcopy(first)
        first.mean_columns[0] = 99
        self.assertEqual(second.mean_columns[0], 0)

    def test_algorithm_version_parses_only_supported_releases(self):
        self.assertEqual(AlgorithmVersion.parse("18"), AlgorithmVersion.V18)
        self.assertEqual(AlgorithmVersion.parse("20"), AlgorithmVersion.V20)
        self.assertEqual(AlgorithmVersion.parse("22"), AlgorithmVersion.V22)
        with self.assertRaisesRegex(ValueError, "supported versions"):
            AlgorithmVersion.parse("19")


if __name__ == "__main__":
    unittest.main()
