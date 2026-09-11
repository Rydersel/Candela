import unittest

from pontusm_sim.model import QDModel
from pontusm_sim.types import AlgorithmVersion, FrameStats, LogoBrightness


class QDModelTests(unittest.TestCase):
    def test_invalid_frame_does_not_mutate_any_observable_state(self):
        model = QDModel(AlgorithmVersion.V20)
        before = model.snapshot()
        frame = FrameStats.neutral()
        frame.mean_columns = [0] * 31
        with self.assertRaisesRegex(ValueError, "mean_columns must contain 32"):
            model.step(frame)
        self.assertEqual(model.snapshot(), before)

    def test_shared_core_outputs_match_versions(self):
        old = QDModel(AlgorithmVersion.V18)
        new = QDModel(AlgorithmVersion.V20)
        frame = FrameStats.neutral()
        frame.mean_rows = [100] * 16
        frame.max_rows = [150] * 16
        frame.max_columns = [80] * 32
        frame.spi_analog = frame.spi_threshold = 1
        for _ in range(400):
            old_result = old.step(frame)
            new_result = new.step(frame)
        self.assertEqual(old_result.retention, new_result.retention)
        self.assertEqual(old_result.retention_count, new_result.retention_count)
        self.assertEqual(old_result.fcn_gain, new_result.fcn_gain)
        self.assertEqual(old_result.curve, new_result.curve)
        self.assertEqual(old_result.anti_residue, new_result.anti_residue)

    def test_low_menu_local_map_matches_and_banner_is_v20_only(self):
        old = QDModel(AlgorithmVersion.V18)
        new = QDModel(AlgorithmVersion.V20)
        frame = FrameStats.neutral()
        frame.mean_rows = [100] * 16
        frame.max_rows = [150] * 16
        frame.region_gains = [100] * 225
        frame.logo_brightness = LogoBrightness.LOW
        for _ in range(10):
            old_result = old.step(frame)
            new_result = new.step(frame)
        self.assertEqual(old_result.region_duties, new_result.region_duties)
        self.assertFalse(old_result.banner_available)
        self.assertIsNone(old_result.policy_state)
        self.assertTrue(new_result.banner_available)
        self.assertIsNotNone(new_result.policy_state)

    def test_version_20_off_output_domain_branch_diverges_from_version_18(self):
        old = QDModel(AlgorithmVersion.V18)
        new = QDModel(AlgorithmVersion.V20)
        frame = FrameStats.neutral()
        frame.mean_rows = [100] * 16
        frame.max_rows = [150] * 16
        frame.region_gains = [0] * 225
        frame.image_mean = 512
        frame.logo_brightness = LogoBrightness.OFF
        frame.movie_mode = False
        frame.pc_mode = False
        for _ in range(100):
            old_result = old.step(frame)
            new_result = new.step(frame)
        self.assertNotEqual(old_result.region_duties, new_result.region_duties)

    def test_version_22_marks_retention_and_fcn_retired_without_running_them(self):
        model = QDModel(AlgorithmVersion.V22)
        frame = FrameStats.neutral()
        frame.mean_rows = [100] * 16
        frame.max_rows = [150] * 16
        frame.image_mean = 256
        result = model.step(frame)
        self.assertFalse(result.retention_available)
        self.assertFalse(result.fcn_available)
        self.assertFalse(result.retention)
        self.assertEqual(result.retention_count, 0)
        self.assertEqual(result.fcn_gain, 0)
        self.assertEqual(result.curve, ())
        self.assertEqual(result.local_target_strength, 1024)
        self.assertTrue(result.banner_available)

    def test_version_22_exposes_source_visible_srp_configuration(self):
        model = QDModel(AlgorithmVersion.V22)
        frame = FrameStats.neutral()
        frame.mean_rows = [100] * 16
        frame.max_rows = [150] * 16
        low = model.step(frame)
        self.assertEqual((low.srp_center_mask_gain, low.srp_board_mask_gain), (196, 224))

        frame.logo_brightness = LogoBrightness.HIGH
        high = model.step(frame)
        self.assertEqual((high.srp_center_mask_gain, high.srp_board_mask_gain), (128, 192))

    def test_legacy_versions_report_retention_and_fcn_available(self):
        for version in (AlgorithmVersion.V18, AlgorithmVersion.V20):
            result = QDModel(version).step(FrameStats.neutral())
            self.assertTrue(result.retention_available)
            self.assertTrue(result.fcn_available)
            self.assertIsNone(result.srp_center_mask_gain)
            self.assertIsNone(result.srp_board_mask_gain)


if __name__ == "__main__":
    unittest.main()
