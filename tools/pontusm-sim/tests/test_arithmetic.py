import unittest

from pontusm_sim.arithmetic import clamp, linear_interpolate, u32


class ArithmeticTests(unittest.TestCase):
    def test_clamp_holds_values_inside_an_inclusive_range(self):
        self.assertEqual(clamp(-1, 0, 10), 0)
        self.assertEqual(clamp(5, 0, 10), 5)
        self.assertEqual(clamp(11, 0, 10), 10)

    def test_clamp_rejects_a_reversed_range(self):
        with self.assertRaisesRegex(ValueError, "low must not exceed high"):
            clamp(1, 2, 1)

    def test_u32_wraps_at_the_c_boundary(self):
        self.assertEqual(u32(0x1_0000_0001), 1)
        self.assertEqual(u32(-1), 0xFFFF_FFFF)

    def test_linear_interpolate_clamps_both_ends_and_truncates(self):
        self.assertEqual(linear_interpolate(5, 10, 20, 100, 200), 100)
        self.assertEqual(linear_interpolate(15, 10, 20, 100, 200), 150)
        self.assertEqual(linear_interpolate(25, 10, 20, 100, 200), 200)
        self.assertEqual(linear_interpolate(1, 0, 3, 0, 10), 3)

    def test_linear_interpolate_rejects_an_empty_input_range(self):
        with self.assertRaisesRegex(ValueError, "input range"):
            linear_interpolate(5, 10, 10, 0, 1)


if __name__ == "__main__":
    unittest.main()
