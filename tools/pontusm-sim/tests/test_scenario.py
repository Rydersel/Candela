import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pontusm_sim.model import QDModel
from pontusm_sim.scenario import load_scenario, run_scenario
from pontusm_sim.types import AlgorithmVersion


def write(directory: str, payload: dict) -> Path:
    path = Path(directory) / "scenario.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


class ScenarioTests(unittest.TestCase):
    def test_rejects_unknown_schema_empty_phases_and_nonpositive_ticks(self):
        with TemporaryDirectory() as directory:
            base = {"schema_version": 1, "name": "tiny", "phases": []}
            with self.assertRaisesRegex(ValueError, "at least one phase"):
                load_scenario(write(directory, base))
            base["schema_version"] = 2
            with self.assertRaisesRegex(ValueError, "schema_version"):
                load_scenario(write(directory, base))
            base.update(schema_version=1, phases=[{"name": "bad", "ticks": 0}])
            with self.assertRaisesRegex(ValueError, "positive ticks"):
                load_scenario(write(directory, base))

    def test_rejects_unknown_fields_and_impossible_vector_lengths(self):
        with TemporaryDirectory() as directory:
            payload = {
                "schema_version": 1,
                "name": "tiny",
                "phases": [{"name": "bad", "ticks": 1, "inputs": {"bogus": 1}}],
            }
            with self.assertRaisesRegex(ValueError, "unknown frame input"):
                load_scenario(write(directory, payload))
            payload["phases"][0]["inputs"] = {"mean_columns": [0] * 31}
            with self.assertRaisesRegex(ValueError, "mean_columns must contain 32"):
                load_scenario(write(directory, payload))

    def test_fill_and_index_shorthand_expand_deterministically(self):
        with TemporaryDirectory() as directory:
            payload = {
                "schema_version": 1,
                "name": "tiny",
                "record_every": 1,
                "phases": [
                    {
                        "name": "one",
                        "ticks": 2,
                        "inputs": {
                            "mean_columns": {"fill": 5, "set": {"3": 9}},
                            "logo_brightness": "high",
                        },
                        "snapshots": {"2": "end"},
                    }
                ],
            }
            scenario = load_scenario(write(directory, payload))
            self.assertEqual(scenario.phases[0].frame.mean_columns[3], 9)
            self.assertEqual(scenario.phases[0].frame.mean_columns[4], 5)
            first = run_scenario(QDModel(AlgorithmVersion.V20), scenario)
            second = run_scenario(QDModel(AlgorithmVersion.V20), scenario)
            self.assertEqual(first, second)
            self.assertEqual(first.tick_count, 2)
            self.assertEqual(first.regions[0]["snapshot"], "end")

    def test_v22_local_delta_scenario_exercises_new_pipeline(self):
        scenario = load_scenario(
            Path(__file__).resolve().parents[1] / "scenarios" / "v22-local-delta.json"
        )
        v20 = run_scenario(QDModel(AlgorithmVersion.V20), scenario)
        v22 = run_scenario(QDModel(AlgorithmVersion.V22), scenario)

        def final_sample(result, phase):
            return [item for item in result.samples if item["phase"] == phase][-1]

        self.assertEqual(final_sample(v20, "pattern-knee")["local_strength"], 512)
        self.assertEqual(final_sample(v22, "pattern-knee")["local_strength"], 1020)
        self.assertEqual(
            final_sample(v22, "dark-image")["local_target_strength"], 992
        )
        self.assertLess(
            final_sample(v22, "high-menu-lpc")["minimum_region_duty"],
            final_sample(v20, "high-menu-lpc")["minimum_region_duty"],
        )
        self.assertEqual(
            final_sample(v22, "factory-exclusion")["local_target_strength"], 0
        )


if __name__ == "__main__":
    unittest.main()
