import csv
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pontusm_sim.artifacts import (
    ArtifactConfig,
    RunMetadata,
    TickRecord,
    write_bundle,
)


SOURCE_HASHES = {
    "23_DTV_PontusML.zip": "2" * 64,
    "tztv-media-sec.tgz": "1" * 64,
}


def metadata(**changes):
    values = {
        "created_at": "2026-09-10T18:30:00Z",
        "model_version": 20,
        "scenario_name": "mini-static",
        "scenario_sha256": "a" * 64,
        "source_archive_hashes": SOURCE_HASHES,
        "command": ("python3", "-m", "pontusm_sim", "run", "mini.json"),
        "fidelity_caveats": ("Regional gains are supplied hardware inputs.",),
    }
    values.update(changes)
    return RunMetadata(**values)


def config():
    return ArtifactConfig(
        summary_metrics=("retention", "fcn_gain", "banner_probability"),
        region_value_name="duty",
    )


def records():
    yield TickRecord(
        tick=0,
        phase="moving",
        metrics={"retention": False, "fcn_gain": 0, "banner_probability": None},
        event="phase-start",
        checkpoint="initial",
        regions=(255, 254),
    )
    yield TickRecord(
        tick=1,
        phase="static",
        metrics={"retention": True, "fcn_gain": 3, "banner_probability": 7},
        event="retention-on",
    )
    yield TickRecord(
        tick=2,
        phase="static",
        metrics={"retention": True, "fcn_gain": 5, "banner_probability": 9},
        checkpoint="final",
        regions=(250, 249),
    )


class ArtifactWriterTests(unittest.TestCase):
    def test_writes_byte_identical_complete_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory, "first")
            second = Path(directory, "second")
            first_digests = write_bundle(first, metadata(), config(), records())
            second_digests = write_bundle(second, metadata(), config(), records())

            expected_names = {
                "manifest.json",
                "trace.jsonl",
                "summary.csv",
                "regions.csv",
                "report.md",
            }
            self.assertEqual({path.name for path in Path(first).iterdir()}, expected_names)
            self.assertEqual(set(first_digests.files), expected_names)
            self.assertEqual(first_digests.files, second_digests.files)

            for name in expected_names:
                first_bytes = (Path(first) / name).read_bytes()
                second_bytes = (Path(second) / name).read_bytes()
                self.assertEqual(first_bytes, second_bytes, name)
                self.assertEqual(
                    first_digests.files[name], hashlib.sha256(first_bytes).hexdigest()
                )
                self.assertFalse(first_bytes.startswith(b"\xef\xbb\xbf"), name)
                self.assertNotIn(b"\r\n", first_bytes, name)

    def test_manifest_contains_stable_provenance_config_and_aggregates(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            write_bundle(output, metadata(), config(), records())
            raw = (output / "manifest.json").read_text(encoding="utf-8")
            manifest = json.loads(raw)

        self.assertTrue(raw.endswith("\n"))
        self.assertEqual(manifest["created_at"], "2026-09-10T18:30:00Z")
        self.assertEqual(manifest["model_version"], 20)
        self.assertEqual(manifest["scenario"]["name"], "mini-static")
        self.assertEqual(manifest["scenario"]["sha256"], "a" * 64)
        self.assertEqual(manifest["source_archive_hashes"], SOURCE_HASHES)
        self.assertEqual(manifest["config"]["summary_metrics"], [
            "retention",
            "fcn_gain",
            "banner_probability",
        ])
        self.assertEqual(manifest["aggregates"]["record_count"], 3)
        self.assertEqual(manifest["aggregates"]["first_tick"], 0)
        self.assertEqual(manifest["aggregates"]["last_tick"], 2)
        self.assertEqual(
            manifest["aggregates"]["metrics"]["fcn_gain"],
            {"final": 5, "maximum": 5, "minimum": 0},
        )
        self.assertEqual(
            manifest["aggregates"]["metrics"]["retention"],
            {"false_count": 1, "final": True, "true_count": 2},
        )
        self.assertLess(
            raw.index('"23_DTV_PontusML.zip"'),
            raw.index('"tztv-media-sec.tgz"'),
        )

    def test_trace_csv_regions_and_report_have_explicit_stable_shapes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            write_bundle(output, metadata(), config(), records())
            output_path = output

            trace = [
                json.loads(line)
                for line in (output_path / "trace.jsonl").read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            summary = list(
                csv.reader(
                    io.StringIO(
                        (output_path / "summary.csv").read_text(encoding="utf-8")
                    )
                )
            )
            regions = list(
                csv.reader(
                    io.StringIO(
                        (output_path / "regions.csv").read_text(encoding="utf-8")
                    )
                )
            )
            report = (output_path / "report.md").read_text(encoding="utf-8")

        self.assertEqual([item["tick"] for item in trace], [0, 1, 2])
        self.assertNotIn("regions", trace[0])
        self.assertEqual(
            summary,
            [
                ["tick", "phase", "retention", "fcn_gain", "banner_probability"],
                ["0", "moving", "false", "0", ""],
                ["1", "static", "true", "3", "7"],
                ["2", "static", "true", "5", "9"],
            ],
        )
        self.assertEqual(
            regions,
            [
                ["tick", "phase", "checkpoint", "region_index", "duty"],
                ["0", "moving", "initial", "0", "255"],
                ["0", "moving", "initial", "1", "254"],
                ["2", "static", "final", "0", "250"],
                ["2", "static", "final", "1", "249"],
            ],
        )
        self.assertIn("PontusM source reconstruction", report)
        self.assertIn("not an implementation claim about the MSI MAG 341CQP", report)
        self.assertIn("OFF/EL electrical compensation remains unavailable", report)
        self.assertIn("Regional gains are supplied hardware inputs.", report)
        self.assertIn("| fcn_gain | 0 | 5 | 5 |", report)

    def test_rejects_invalid_input_before_creating_partial_artifacts(self):
        bad_records = [
            TickRecord(
                tick=1,
                phase="first",
                metrics={
                    "retention": False,
                    "fcn_gain": 0,
                    "banner_probability": None,
                },
            ),
            TickRecord(
                tick=1,
                phase="duplicate",
                metrics={
                    "retention": True,
                    "fcn_gain": 1,
                    "banner_probability": None,
                },
            ),
        ]
        with tempfile.TemporaryDirectory() as output:
            with self.assertRaisesRegex(ValueError, "strictly increasing"):
                write_bundle(output, metadata(), config(), bad_records)
            self.assertEqual(list(Path(output).iterdir()), [])

        with tempfile.TemporaryDirectory() as output:
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                write_bundle(
                    output,
                    metadata(source_archive_hashes={"archive.zip": "not-a-hash"}),
                    config(),
                    records(),
                )
            self.assertEqual(list(Path(output).iterdir()), [])

    def test_refuses_existing_or_symlink_destinations_without_changing_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "existing"
            existing.mkdir()
            preserved = existing / "bip.json"
            preserved.write_bytes(b"archive-backed artifact")
            with self.assertRaisesRegex(ValueError, "destination already exists"):
                write_bundle(existing, metadata(), config(), records())
            self.assertEqual(preserved.read_bytes(), b"archive-backed artifact")

            target = root / "target"
            target.mkdir()
            symlink = root / "symlink"
            symlink.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "destination already exists"):
                write_bundle(symlink, metadata(), config(), records())
            self.assertTrue(symlink.is_symlink())
            self.assertEqual(list(target.iterdir()), [])

    def test_mid_write_failure_leaves_no_destination_or_staging_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "bundle"
            before = set(root.iterdir())
            original = Path.write_bytes
            calls = 0

            def fail_second_write(path, raw):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("injected write failure")
                return original(path, raw)

            with mock.patch.object(Path, "write_bytes", fail_second_write):
                with self.assertRaisesRegex(OSError, "injected write failure"):
                    write_bundle(output, metadata(), config(), records())
            self.assertFalse(output.exists())
            self.assertEqual(set(root.iterdir()), before)


if __name__ == "__main__":
    unittest.main()
