from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pontusm_sim.model import QDModel
from pontusm_sim.reporting import DEFAULT_METRICS, write_result_bundle
from pontusm_sim.scenario import Scenario, ScenarioPhase, run_scenario
from pontusm_sim.types import AlgorithmVersion, FrameStats


class ReportingAdapterTests(unittest.TestCase):
    def test_scenario_result_writes_all_artifacts_with_snapshot_regions(self):
        scenario = Scenario(
            name="tiny",
            description="",
            record_every=1,
            phases=(
                ScenarioPhase(
                    "phase",
                    2,
                    FrameStats.neutral(),
                    snapshots=((2, "final"),),
                ),
            ),
            sha256="a" * 64,
            source_path="tiny.json",
        )
        result = run_scenario(QDModel(AlgorithmVersion.V20), scenario)
        with TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            digests = write_result_bundle(
                result,
                output,
                source_hashes={"fixture": "b" * 64},
                command=("pontusm-sim", "run"),
            )
            self.assertEqual(len(digests.files), 5)
            summary = (output / "summary.csv").read_text()
            regions = (output / "regions.csv").read_text()
            self.assertIn(DEFAULT_METRICS[0], summary)
            self.assertIn("final", regions)
            self.assertEqual(len(regions.splitlines()), 226)


if __name__ == "__main__":
    unittest.main()
