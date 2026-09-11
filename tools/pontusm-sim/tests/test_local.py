import copy
import unittest

from pontusm_sim.local import AppLimiter, LocalExclusions, LocalProtection
from pontusm_sim.types import AlgorithmVersion, FrameStats, LogoBrightness


class AppLimiterTests(unittest.TestCase):
    def test_counter_attacks_releases_and_reaches_source_duty_floor(self):
        limiter = AppLimiter()
        for _ in range(600):
            count, duty = limiter.step(1, 1)
        self.assertEqual((count, duty), (512, 191))
        self.assertEqual(limiter.step(0, 1), (511, 192))


class LocalProtectionTests(unittest.TestCase):
    def test_strength_attacks_one_and_releases_sixteen(self):
        frame = FrameStats.neutral()
        model = LocalProtection(AlgorithmVersion.V20)
        first = model.step(frame, LocalExclusions(), retention_count=0)
        self.assertEqual(first.strength, 1)

        frame.capture_error = True
        model.strength = 32
        released = model.step(frame, LocalExclusions(), retention_count=0)
        self.assertEqual(released.strength, 16)

    def test_version_20_applies_menu_scaling_in_output_domain(self):
        model = LocalProtection(AlgorithmVersion.V20)
        self.assertEqual(model.apply_menu_scale(200, LogoBrightness.OFF), 219)
        self.assertEqual(model.apply_menu_scale(200, LogoBrightness.LOW), 200)
        self.assertEqual(model.apply_menu_scale(200, LogoBrightness.HIGH), 177)

    def test_version_18_off_scales_strength_not_finished_duty(self):
        frame = FrameStats.neutral()
        frame.logo_brightness = LogoBrightness.OFF
        model = LocalProtection(AlgorithmVersion.V18, strength=1024)
        result = model.step(frame, LocalExclusions(), retention_count=0)
        self.assertEqual(result.target_strength, (1024 * 170) >> 8)
        self.assertEqual(model.apply_menu_scale(200, LogoBrightness.OFF), 200)

    def test_app_counter_and_pattern_exclusions_withhold_local_strength(self):
        frame = FrameStats.neutral()
        model = LocalProtection(AlgorithmVersion.V20, strength=64)
        result = model.step(
            frame,
            LocalExclusions(standard_pattern=True),
            retention_count=0,
            app_counter=1,
        )
        self.assertFalse(result.local_allowed)
        self.assertEqual(result.target_strength, 0)
        self.assertEqual(result.strength, 48)

    def test_version_22_uses_768_knee_and_rounded_fixed_point_products(self):
        frame = FrameStats.neutral()
        frame.motion = False
        frame.pattern_probability = 769
        frame.image_mean = 256
        result = LocalProtection(AlgorithmVersion.V22).step(
            frame, LocalExclusions(), retention_count=0
        )
        self.assertEqual(result.target_strength, 1020)

        frame.pattern_probability = 0
        frame.region_gains = [0] * 225
        rounded = LocalProtection(AlgorithmVersion.V22).step(
            frame, LocalExclusions(), retention_count=0
        )
        self.assertEqual(rounded.duties[0], 255)

    def test_version_22_accepts_source_probability_endpoint_in_all_gain_modes(self):
        for mode in ("ordinary", "movie", "pc"):
            with self.subTest(mode=mode):
                frame = FrameStats.neutral()
                frame.pattern_probability = 1024
                frame.image_mean = 256
                frame.motion = False
                frame.movie_mode = mode == "movie"
                frame.pc_mode = mode == "pc"
                frame.validate()
                result = LocalProtection(AlgorithmVersion.V22).step(
                    frame, LocalExclusions(), retention_count=0
                )
                self.assertEqual(result.target_strength, 0)

    def test_version_22_dark_image_reduces_target_before_strength_filter(self):
        frame = FrameStats.neutral()
        frame.image_mean = 0
        ordinary = LocalProtection(AlgorithmVersion.V22).step(
            frame, LocalExclusions(), retention_count=0
        )
        self.assertEqual(ordinary.target_strength, 992)

        frame.movie_mode = True
        movie = LocalProtection(AlgorithmVersion.V22).step(
            frame, LocalExclusions(), retention_count=0
        )
        self.assertEqual(movie.target_strength, 960)

    def test_version_22_removes_retention_exclusion_and_adds_factory_exclusion(self):
        frame = FrameStats.neutral()
        retained = LocalProtection(AlgorithmVersion.V22).step(
            frame, LocalExclusions(), retention_count=500
        )
        self.assertTrue(retained.local_allowed)
        self.assertNotIn("retention", retained.exclusion_reasons)

        frame.factory_mode = True
        factory = LocalProtection(AlgorithmVersion.V22).step(
            frame, LocalExclusions(), retention_count=0
        )
        self.assertFalse(factory.local_allowed)
        self.assertIn("factory-mode", factory.exclusion_reasons)
        self.assertEqual(factory.target_strength, 0)

    def test_version_22_exposes_menu_selected_srp_mask_gains(self):
        model = LocalProtection(AlgorithmVersion.V22)
        self.assertEqual(model.srp_mask_gains(LogoBrightness.OFF), (196, 224))
        self.assertEqual(model.srp_mask_gains(LogoBrightness.LOW), (196, 224))
        self.assertEqual(model.srp_mask_gains(LogoBrightness.HIGH), (128, 192))

    def test_version_22_applies_published_lpc_shapes_after_menu_scaling(self):
        frame = FrameStats.neutral()
        frame.region_gains = [200] * 225
        frame.image_mean = 256
        frame.lpc_shape1_gain = 16
        frame.lpc_shape2_gain = 16
        result = LocalProtection(AlgorithmVersion.V22, strength=1024).step(
            frame, LocalExclusions(), retention_count=0
        )
        self.assertEqual(result.duties[0], 192)
        self.assertEqual(result.duties[112], 200)

    def test_version_22_row_limits_movie_and_pc_mode_output(self):
        for mode in ("movie", "pc"):
            with self.subTest(mode=mode):
                frame = FrameStats.neutral()
                frame.movie_mode = mode == "movie"
                frame.pc_mode = mode == "pc"
                frame.image_mean = 256
                frame.region_gains = [255] * 225
                frame.region_gains[105] = 0
                result = LocalProtection(AlgorithmVersion.V22, strength=1024).step(
                    frame, LocalExclusions(), retention_count=0
                )
                self.assertEqual(result.duties[106], 108)

    def test_version_22_off_uses_previous_completed_cycle_global_reduce(self):
        frame = FrameStats.neutral()
        frame.logo_brightness = LogoBrightness.OFF
        frame.image_mean = 256
        frame.region_gains = [0] * 225
        model = LocalProtection(AlgorithmVersion.V22, strength=1024)

        first_phase = model.step(
            frame, LocalExclusions(), retention_count=0, phase=0
        )
        self.assertEqual(first_phase.duties[0], 255)
        for phase in range(1, 5):
            model.step(frame, LocalExclusions(), retention_count=0, phase=phase)

        next_cycle = model.step(
            frame, LocalExclusions(), retention_count=0, phase=0
        )
        self.assertEqual(next_cycle.duties[0], 86)

    def test_invalid_phase_is_rejected_before_any_model_state_changes(self):
        model = LocalProtection(AlgorithmVersion.V22, strength=17)
        before = copy.deepcopy(model)
        with self.assertRaisesRegex(ValueError, "phase must be in 0...4"):
            model.step(
                FrameStats.neutral(), LocalExclusions(), retention_count=0, phase=5
            )
        self.assertEqual(model, before)


if __name__ == "__main__":
    unittest.main()
