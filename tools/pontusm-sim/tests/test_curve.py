import unittest

from pontusm_sim.curve import FCNCurveController, ORIGINAL_CURVE, REDUCED_CURVE


class FCNCurveControllerTests(unittest.TestCase):
    def test_retention_arms_on_the_3500th_tick(self):
        controller = FCNCurveController()
        for _ in range(3_499):
            controller.step(True)
        self.assertEqual(controller.retention_count, 3_499)
        self.assertEqual(controller.gain, 0)

        gain, _ = controller.step(True)
        self.assertEqual(controller.retention_count, 3_500)
        self.assertEqual(gain, 1)

    def test_attack_stops_at_14400(self):
        controller = FCNCurveController(retention_count=3_500, gain=14_399)
        gain, curve = controller.step(True)
        self.assertEqual(gain, 14_400)
        self.assertEqual(curve[0], 0)
        self.assertEqual(curve[9], 2_304)
        self.assertEqual(curve[40], 9_506)

        gain, _ = controller.step(True)
        self.assertEqual(gain, 14_400)

    def test_release_is_2400_per_tick_and_resets_retention_count(self):
        controller = FCNCurveController(retention_count=3_500, gain=5_000)
        gain, _ = controller.step(False)
        self.assertEqual(controller.retention_count, 0)
        self.assertEqual(gain, 2_600)
        gain, _ = controller.step(False)
        self.assertEqual(gain, 200)
        gain, _ = controller.step(False)
        self.assertEqual(gain, 0)

    def test_zero_gain_is_the_original_curve(self):
        controller = FCNCurveController()
        _, curve = controller.step(False)
        self.assertEqual(curve, ORIGINAL_CURVE)
        self.assertEqual(len(ORIGINAL_CURVE), 41)
        self.assertEqual(len(REDUCED_CURVE), 41)

    def test_debug_gain_uses_the_same_14_bit_interpolation(self):
        controller = FCNCurveController()
        gain, curve = controller.step(False, debug_gain=8_192)
        self.assertEqual(gain, 8_192)
        self.assertEqual(curve[40], (16_383 + 8_559) // 2)


if __name__ == "__main__":
    unittest.main()
