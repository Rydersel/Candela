"""Deterministic MSI artifacts with explicit reconstruction provenance."""

from dataclasses import replace
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pontusm_sim.msi_reporting import write_msi_bundle
from pontusm_sim.msi_scenario import load_msi_scenario, run_msi_scenario


ROOT = Path(__file__).resolve().parents[1]


class MSIReportingTests(unittest.TestCase):
    def result(self, name="off-early-done"):
        return run_msi_scenario(load_msi_scenario(ROOT / "msi-scenarios" / f"{name}.json"))

    def test_every_artifact_is_identical_across_output_directories(self):
        result = self.result()
        with TemporaryDirectory() as directory:
            first, second = Path(directory, "one"), Path(directory, "two")
            a = write_msi_bundle(result, first, command=(
                "pontusm-sim", "msi-run", "scenario.json", "--output", str(first)))
            b = write_msi_bundle(result, second, command=(
                "pontusm-sim", "msi-run", "scenario.json", f"--output={second}"))
            self.assertEqual(set(a.files), {"manifest.json", "events.jsonl", "report.md"})
            self.assertEqual(a.files, b.files)
            for name, digest in a.files.items():
                raw = (first / name).read_bytes()
                self.assertEqual(raw, (second / name).read_bytes())
                self.assertEqual(hashlib.sha256(raw).hexdigest(), digest)
                self.assertNotIn(b"\r", raw)
                self.assertNotIn(directory.encode(), raw)
            manifest = json.loads((first / "manifest.json").read_bytes())
            self.assertEqual(manifest["created_at"], "2026-09-10T00:00:00Z")
            self.assertEqual(manifest["scenario"]["sha256"], result.scenario_sha256)
            self.assertEqual(manifest["artifact_sha256"]["events.jsonl"], a.files["events.jsonl"])
            self.assertEqual(manifest["artifact_sha256"]["report.md"], a.files["report.md"])
            self.assertIn("<output-directory>", manifest["command"])
            self.assertIn("<output-directory>", (first / "report.md").read_text())
            self.assertEqual(manifest["timing_basis"], "semantic-reconstruction")
            self.assertEqual(manifest["evidence"], "msi-source-translated")
            self.assertTrue(manifest["source_documents"])

    def test_serialized_events_preserve_register_payloads_and_event_order(self):
        result = self.result()
        with TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            write_msi_bundle(result, output)
            rows = [json.loads(line) for line in (output / "events.jsonl").read_text().splitlines()]
            self.assertEqual([row["kind"] for row in rows], [e.kind for e in result.events])
            writes = [row for row in rows if row["kind"] == "register-write"]
            self.assertEqual([(row["time_ms"], row["detail"]["write"]["register"],
                               row["detail"]["write"]["payload"]) for row in writes],
                             [(181_000, 0x0B2, [0, 0]), (181_500, 0x0C0, [0, 1])])

    def test_latent_warning_is_present_in_all_three_artifacts(self):
        with TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            write_msi_bundle(self.result("latent-el"), output)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertTrue(manifest["unreachable_in_shipped_control_flow"])
            rows = [json.loads(line) for line in (output / "events.jsonl").read_text().splitlines()]
            self.assertTrue(all(row["unreachable_in_shipped_control_flow"] for row in rows))
            report = (output / "report.md").read_text()
            self.assertIn("unreachable in shipped", report)
            self.assertIn("FW.028/FW.031/FW.035/FW.041", report)
            self.assertIn("semantic reconstruction", report)
            self.assertIn("No real MSI capture", report)
            self.assertIn("unavailable", report)

    def test_invalid_result_or_metadata_creates_no_partial_directory(self):
        result = self.result()
        with TemporaryDirectory() as directory:
            output = Path(directory, "not-created")
            for invalid, metadata in (
                (replace(result, events=()), {}),
                (replace(result, scenario=replace(result.scenario, document=b"{}")), {}),
                (result, {"artifact_epoch": ""}),
                (result, {"command": ("bad\ncommand",)}),
            ):
                with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                    write_msi_bundle(invalid, output, **metadata)
                self.assertFalse(output.exists())

    def test_existing_destination_is_refused_without_changing_its_files(self):
        with TemporaryDirectory() as directory:
            output = Path(directory, "existing")
            output.mkdir()
            preserved = output / "extra.txt"
            preserved.write_bytes(b"keep")
            with self.assertRaisesRegex(ValueError, "destination already exists"):
                write_msi_bundle(self.result(), output)
            self.assertEqual(preserved.read_bytes(), b"keep")
            self.assertEqual(list(output.iterdir()), [preserved])

    def test_caller_epoch_is_recorded_without_using_wall_clock(self):
        with TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            write_msi_bundle(self.result(), output, artifact_epoch="2020-01-01T00:00:00Z")
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["created_at"], "2020-01-01T00:00:00Z")

    def test_all_six_builtin_scenarios_cover_expected_boundary_outcomes(self):
        names = {path.stem for path in (ROOT / "msi-scenarios").glob("*.json")}
        self.assertEqual(names, {"off-early-done", "off-timeout", "off-hot-refusal",
                                 "off-abort", "latent-el", "vrr-reapply"})
        results = {name: self.result(name) for name in names}
        for name, event in (("off-early-done", "done"), ("off-timeout", "timeout"),
                            ("off-hot-refusal", "temperature-refused"), ("off-abort", "abort")):
            self.assertIn(event, [item.kind for item in results[name].events])
        self.assertEqual(results["off-hot-refusal"].final_state.destination, "power-off")
        self.assertEqual(results["off-abort"].final_state.off_run_count, 0)
        self.assertEqual(results["latent-el"].final_state.el_run_count, 1)
        self.assertEqual(len(results["vrr-reapply"].events), 18)
        self.assertTrue(all(result.final_state.state == "idle" for result in results.values()))


if __name__ == "__main__":
    unittest.main()
