import unittest

from pontusm_sim.orbits import OrbitInventory, parse_orbit_tables
from pontusm_sim.types import AlgorithmVersion


FIXTURE = """
static struct ORBIT orbit_table[] = {
    { 0, 0 }, { 1, -1 },
};
static struct ORBIT orbit_table_24x16[] = {
    { 24, 16 },
};
static struct ORBIT orbit_table_32x16[] = {
    { 32, -16 }, { 0, 0 },
};
static struct ORBIT orbit_table_ew[] = {
    { -1, 1 },
};
"""


class OrbitParserTests(unittest.TestCase):
    def test_parses_named_arrays_as_immutable_data(self):
        inventory = parse_orbit_tables(FIXTURE, AlgorithmVersion.V20)
        self.assertIsInstance(inventory, OrbitInventory)
        self.assertEqual(inventory.normal, ((0, 0), (1, -1)))
        self.assertEqual(inventory.rotated, ((32, -16), (0, 0)))
        self.assertEqual(inventory.engineering, ((-1, 1),))
        self.assertEqual(inventory.unused_24x16, ((24, 16),))

    def test_strict_expected_counts_are_enforced(self):
        with self.assertRaisesRegex(ValueError, "orbit_table expected 1956"):
            parse_orbit_tables(
                FIXTURE,
                AlgorithmVersion.V20,
                expected_counts={"orbit_table": 1956},
            )

    def test_rejects_duplicate_names_malformed_values_and_missing_tables(self):
        duplicate = FIXTURE + "struct ORBIT orbit_table[] = {{0,0}};"
        with self.assertRaisesRegex(ValueError, "duplicate orbit table"):
            parse_orbit_tables(duplicate, AlgorithmVersion.V20)
        malformed = "struct ORBIT orbit_table[] = {{0,0}, SOME_MACRO};"
        with self.assertRaisesRegex(ValueError, "malformed initializer"):
            parse_orbit_tables(malformed, AlgorithmVersion.V18)
        with self.assertRaisesRegex(ValueError, "no recognized orbit tables"):
            parse_orbit_tables("int main(void) { return 0; }", AlgorithmVersion.V18)

    def test_rejects_coordinates_outside_declared_bound(self):
        source = "struct ORBIT orbit_table[] = {{65, 0}};"
        with self.assertRaisesRegex(ValueError, "outside -64...64"):
            parse_orbit_tables(source, AlgorithmVersion.V18)


if __name__ == "__main__":
    unittest.main()
