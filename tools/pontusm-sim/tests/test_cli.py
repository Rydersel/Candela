from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest import mock

from pontusm_sim.source import OrbitBounds, SourceVerification
from pontusm_sim.types import AlgorithmVersion


ROOT = Path(__file__).resolve().parents[1]


def run_cli(*arguments: str):
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(ROOT)
    return subprocess.run(
        [sys.executable, "-m", "pontusm_sim", *arguments],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


class CLITests(unittest.TestCase):
    def test_help_lists_all_commands(self):
        result = run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ("verify-source", "run", "compare", "run-all", "msi-run", "compare-capture"):
            self.assertIn(command, result.stdout)

    def test_verify_source_prints_summary_without_runtime_orbit_coordinates(self):
        verification = SourceVerification(
            version=AlgorithmVersion.V22,
            outer_sha256="a" * 64,
            archive_members=("release/media.tgz",),
            archive_hashes={"release/media.tgz": "b" * 64},
            qd_source_member="QD_burn_in.c",
            qd_source_sha256="c" * 64,
            orbit_source_member="bip_orbit_table.c",
            orbit_source_sha256="d" * 64,
            constants={"QD_burn_in_ver": 22},
            orbit_tables={"orbit_table": ((0, 0), (1, -1))},
            orbit_counts={"orbit_table": 2},
            orbit_bounds={"orbit_table": OrbitBounds(0, 1, -1, 0)},
            warnings=("fixture warning",),
        )
        stream = io.StringIO()
        with mock.patch("pontusm_sim.cli._verified_source", return_value=verification):
            with redirect_stdout(stream):
                from pontusm_sim.cli import main

                exit_code = main(["verify-source", "fixture.zip", "--version", "22"])
        document = json.loads(stream.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertNotIn("orbit_tables", document)
        self.assertEqual(document["orbit_counts"], {"orbit_table": 2})
        self.assertEqual(
            document["orbit_bounds"]["orbit_table"],
            {
                "max_horizontal": 1,
                "max_vertical": 0,
                "min_horizontal": 0,
                "min_vertical": -1,
            },
        )

    def test_msi_help_describes_offline_operation_and_rejects_hardware_flags(self):
        help_result = run_cli("msi-run", "--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("offline", help_result.stdout)
        for flag in ("--device", "--usb", "--i2c", "--uart", "--network"):
            result = run_cli("msi-run", "scenario.json", "--output", "unused", flag, "0")
            self.assertEqual(result.returncode, 2)
            self.assertIn("unrecognized arguments", result.stderr)

    def test_msi_run_writes_three_deterministic_artifacts(self):
        scenario = ROOT / "msi-scenarios" / "off-early-done.json"
        with TemporaryDirectory() as directory:
            first, second = Path(directory, "one"), Path(directory, "two")
            a = run_cli("msi-run", str(scenario), "--output", str(first))
            b = run_cli("msi-run", str(scenario), f"--output={second}")
            self.assertEqual(a.returncode, 0, a.stderr)
            self.assertEqual(b.returncode, 0, b.stderr)
            self.assertEqual(a.stdout.strip(), str(first))
            self.assertEqual({path.name for path in first.iterdir()},
                             {"manifest.json", "events.jsonl", "report.md"})
            for name in ("manifest.json", "events.jsonl", "report.md"):
                self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())

    def test_long_option_abbreviations_are_rejected_consistently(self):
        for command in ((), ("verify-source",), ("run",), ("msi-run",),
                        ("compare",), ("run-all",), ("compare-capture",)):
            with self.subTest(command=command):
                result = run_cli(*command, "--he")
                self.assertEqual(result.returncode, 2)
        scenario = ROOT / "msi-scenarios" / "off-early-done.json"
        with TemporaryDirectory() as directory:
            output = Path(directory, "not-created")
            for option in (("--out", str(output)), (f"--out={output}",)):
                with self.subTest(option=option):
                    result = run_cli("msi-run", str(scenario), *option)
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse(output.exists())

    def test_msi_recorded_module_command_reproduces_the_same_bundle(self):
        scenario = ROOT / "msi-scenarios" / "off-early-done.json"
        with TemporaryDirectory() as directory:
            first, replay = Path(directory, "first"), Path(directory, "replay")
            original = run_cli("msi-run", str(scenario), "--output", str(first),
                               "--artifact-epoch", "2020-01-01T00:00:00Z")
            self.assertEqual(original.returncode, 0, original.stderr)
            command = json.loads((first / "manifest.json").read_text())["command"]
            self.assertEqual(command[:4], ["python3", "-m", "pontusm_sim", "msi-run"])
            self.assertIn("--artifact-epoch=2020-01-01T00:00:00Z", command)
            self.assertIn("<output-directory>", command)
            environment = os.environ.copy()
            environment["PYTHONPATH"] = str(ROOT)
            rerun = subprocess.run(
                [str(replay) if item == "<output-directory>" else item for item in command],
                cwd=ROOT, env=environment, text=True, capture_output=True,
            )
            self.assertEqual(rerun.returncode, 0, rerun.stderr)
            for name in ("manifest.json", "events.jsonl", "report.md"):
                self.assertEqual((first / name).read_bytes(), (replay / name).read_bytes())

    def test_msi_recorded_epoch_replays_leading_dash_and_spaces_exactly(self):
        scenario = ROOT / "msi-scenarios" / "off-early-done.json"
        for epoch in ("-x", "epoch with spaces"):
            with self.subTest(epoch=epoch), TemporaryDirectory() as directory:
                first, replay = Path(directory, "first"), Path(directory, "replay")
                original = run_cli("msi-run", str(scenario), "--output", str(first),
                                   f"--artifact-epoch={epoch}")
                self.assertEqual(original.returncode, 0, original.stderr)
                manifest = json.loads((first / "manifest.json").read_text())
                self.assertEqual(manifest["created_at"], epoch)
                command = manifest["command"]
                environment = os.environ.copy()
                environment["PYTHONPATH"] = str(ROOT)
                rerun = subprocess.run(
                    [str(replay) if item == "<output-directory>" else item for item in command],
                    cwd=ROOT, env=environment, text=True, capture_output=True,
                )
                self.assertEqual(rerun.returncode, 0, rerun.stderr)
                self.assertEqual(command, [
                    "python3", "-m", "pontusm_sim", "msi-run", str(scenario),
                    "--output", "<output-directory>", f"--artifact-epoch={epoch}",
                ])
                for name in ("manifest.json", "events.jsonl", "report.md"):
                    self.assertEqual((first / name).read_bytes(), (replay / name).read_bytes())

    def test_msi_invalid_input_returns_two_without_partial_artifacts(self):
        with TemporaryDirectory() as directory:
            scenario = Path(directory, "invalid.json")
            output = Path(directory, "not-created")
            source = json.loads((ROOT / "msi-scenarios" / "off-early-done.json").read_text())
            source["actions"].append({"at_ms": 600_000, "action": "abort"})
            for contents in ("{", json.dumps(source)):
                scenario.write_text(contents, encoding="utf-8")
                result = run_cli("msi-run", str(scenario), "--output", str(output))
                self.assertEqual(result.returncode, 2)
                self.assertTrue(result.stderr.startswith("pontusm-sim: "))
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(output.exists())

    def test_msi_run_has_no_hardware_network_or_external_execution_dependencies(self):
        script = """
import sys
class NoHardwareImports:
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split('.')[0] in {'socket', 'serial', 'usb', 'hid', 'smbus', 'smbus2'}:
            raise RuntimeError('hardware/network import: ' + fullname)
sys.meta_path.insert(0, NoHardwareImports())
def audit(event, args):
    if event in {'socket.__new__', 'socket.connect', 'subprocess.Popen', 'os.system'}:
        raise RuntimeError('external operation: ' + event)
sys.addaudithook(audit)
from pontusm_sim.cli import main
sys.exit(main(sys.argv[1:]))
"""
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(ROOT)
        with TemporaryDirectory() as directory:
            output = Path(directory, "bundle")
            result = subprocess.run(
                [sys.executable, "-c", script, "msi-run",
                 str(ROOT / "msi-scenarios" / "off-timeout.json"),
                 "--output", str(output), "--artifact-epoch", "2020-01-01T00:00:00Z"],
                env=environment, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["created_at"], "2020-01-01T00:00:00Z")

    def test_invalid_scenario_has_concise_exit_two_contract(self):
        result = run_cli(
            "run",
            "/definitely/missing.json",
            "--version",
            "20",
            "--output",
            "/tmp/pontusm-never-created",
        )
        self.assertEqual(result.returncode, 2)
        self.assertTrue(result.stderr.startswith("pontusm-sim: "))
        self.assertNotIn("Traceback", result.stderr)

    def test_capture_comparison_canonical_command_replays_identical_four_files(self):
        template = ROOT / "capture-templates" / "pixel-shift"
        with TemporaryDirectory() as directory:
            first, second, replay = [Path(directory, name) for name in ("one", "two", "replay")]
            args = ("compare-capture", str(template / "capture.json"),
                    "--hypotheses", str(template / "hypotheses.json"))
            a = run_cli(*args, "--output", str(first), "--artifact-epoch=2020-01-01T00:00:00Z")
            b = run_cli(*args, f"--output={second}", "--artifact-epoch", "2020-01-01T00:00:00Z")
            self.assertEqual(a.returncode, 0, a.stderr)
            self.assertEqual(b.returncode, 0, b.stderr)
            manifest = json.loads((first / "manifest.json").read_text())
            self.assertEqual(manifest["created_at"], "2020-01-01T00:00:00Z")
            command = manifest["command"]
            self.assertEqual(command[:4], ["python3", "-m", "pontusm_sim", "compare-capture"])
            self.assertIn("<output-directory>", command)
            self.assertNotIn(str(first), command)
            self.assertEqual(manifest["verified_source_versions"], [])
            environment = os.environ.copy()
            environment["PYTHONPATH"] = str(ROOT)
            result = subprocess.run([str(replay) if item == "<output-directory>" else item for item in command],
                cwd=ROOT, env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ("manifest.json", "comparison.json", "aligned.csv", "report.md"):
                self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
                self.assertEqual((first / name).read_bytes(), (replay / name).read_bytes())

    def test_capture_comparison_errors_are_concise_and_create_no_partial_output(self):
        template = ROOT / "capture-templates" / "pixel-shift"
        with TemporaryDirectory() as directory:
            output = Path(directory, "not-created")
            invalid = Path(directory, "invalid.json")
            invalid.write_text("{")
            for capture, hypotheses, extra in (
                (invalid, template / "hypotheses.json", ()),
                (template / "capture.json", invalid, ()),
                (template / "capture.json", template / "hypotheses.json", ("--archive-18", str(invalid))),
                (template / "capture.json", template / "hypotheses.json", ("--archive-20", str(invalid))),
                (template / "capture.json", template / "hypotheses.json", ("--archive-22", str(invalid))),
                (template / "capture.json", template / "hypotheses.json", ("--artifact-epoch", "")),
            ):
                with self.subTest(capture=capture, hypotheses=hypotheses, extra=extra):
                    result = run_cli("compare-capture", str(capture), "--hypotheses", str(hypotheses),
                                     "--output", str(output), *extra)
                    self.assertEqual(result.returncode, 2)
                    self.assertTrue(result.stderr.startswith("pontusm-sim: "))
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertFalse(output.exists())

    def test_capture_comparison_rejects_hardware_flags_and_abbreviated_options(self):
        template = ROOT / "capture-templates" / "pixel-shift"
        help_result = run_cli("compare-capture", "--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("offline", help_result.stdout)
        with TemporaryDirectory() as directory:
            output = Path(directory, "not-created")
            for flag in ("--usb", "--device", "--ddc", "--i2c", "--uart", "--camera", "--display",
                         "--network", "--out", "--hyp", "--archive-1"):
                result = run_cli("compare-capture", str(template / "capture.json"),
                    "--hypotheses", str(template / "hypotheses.json"), "--output", str(output), flag, "0")
                self.assertEqual(result.returncode, 2)
                self.assertIn("unrecognized arguments", result.stderr)
                self.assertFalse(output.exists())

    def test_capture_comparison_runs_without_hardware_network_or_external_execution(self):
        script = """
import sys
class NoHardwareImports:
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split('.')[0] in {'socket', 'serial', 'usb', 'hid', 'smbus', 'smbus2'}:
            raise RuntimeError('hardware/network import: ' + fullname)
sys.meta_path.insert(0, NoHardwareImports())
def audit(event, args):
    if event in {'socket.__new__', 'socket.connect', 'subprocess.Popen', 'os.system'}:
        raise RuntimeError('external operation: ' + event)
sys.addaudithook(audit)
from pontusm_sim.cli import main
sys.exit(main(sys.argv[1:]))
"""
        template = ROOT / "capture-templates" / "pixel-shift"
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(ROOT)
        with TemporaryDirectory() as directory:
            output = Path(directory, "comparison")
            result = subprocess.run([sys.executable, "-c", script, "compare-capture",
                str(template / "capture.json"), "--hypotheses", str(template / "hypotheses.json"),
                "--output", str(output)], env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / "comparison.json").is_file())

    def test_capture_comparison_rejects_existing_output_with_concise_exit_two(self):
        template = ROOT / "capture-templates" / "pixel-shift"
        with TemporaryDirectory() as directory:
            output = Path(directory)
            original = output / "comparison.json"
            original.write_bytes(b"preserve me")
            result = run_cli("compare-capture", str(template / "capture.json"),
                "--hypotheses", str(template / "hypotheses.json"), "--output", str(output))
            self.assertEqual(result.returncode, 2)
            self.assertTrue(result.stderr.startswith("pontusm-sim: "))
            self.assertNotIn("Traceback", result.stderr)
            self.assertEqual(original.read_bytes(), b"preserve me")
            self.assertEqual(list(output.iterdir()), [original])

    def test_run_compare_and_run_all_create_result_paths(self):
        scenario = ROOT / "scenarios" / "motion.json"
        with TemporaryDirectory() as directory:
            single = run_cli(
                "run", str(scenario), "--version", "20", "--output", f"{directory}/one"
            )
            self.assertEqual(single.returncode, 0, single.stderr)
            self.assertEqual(single.stdout.strip(), f"{directory}/one")
            self.assertTrue(Path(directory, "one", "manifest.json").is_file())
            second = run_cli(
                "run", str(scenario), "--version", "20", "--output", f"{directory}/two"
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(
                Path(directory, "one", "manifest.json").read_bytes(),
                Path(directory, "two", "manifest.json").read_bytes(),
            )

            v22 = run_cli(
                "run", str(scenario), "--version", "22", "--output", f"{directory}/v22"
            )
            self.assertEqual(v22.returncode, 0, v22.stderr)
            v22_manifest = json.loads(Path(directory, "v22", "manifest.json").read_text())
            self.assertEqual(v22_manifest["model_version"], 22)
            first_v22_record = json.loads(
                Path(directory, "v22", "trace.jsonl").read_text().splitlines()[0]
            )
            self.assertFalse(first_v22_record["metrics"]["retention_available"])
            self.assertFalse(first_v22_record["metrics"]["fcn_available"])
            self.assertIn("local_target_strength", first_v22_record["metrics"])

            compare = run_cli("compare", str(scenario), "--output", f"{directory}/cmp")
            self.assertEqual(compare.returncode, 0, compare.stderr)
            comparison = json.loads(Path(directory, "cmp", "comparison.json").read_text())
            self.assertEqual(comparison["scenario"], "motion")

            newest = run_cli(
                "compare",
                str(scenario),
                "--from-version",
                "20",
                "--to-version",
                "22",
                "--output",
                f"{directory}/cmp22",
            )
            self.assertEqual(newest.returncode, 0, newest.stderr)
            newest_comparison = json.loads(
                Path(directory, "cmp22", "comparison.json").read_text()
            )
            self.assertEqual(newest_comparison["versions"], [20, 22])
            self.assertTrue(Path(directory, "cmp22", "v20", "manifest.json").is_file())
            self.assertTrue(Path(directory, "cmp22", "v22", "manifest.json").is_file())

            all_result = run_cli("run-all", "--output", f"{directory}/all")
            self.assertEqual(all_result.returncode, 0, all_result.stderr)
            index = json.loads(Path(directory, "all", "index.json").read_text())
            self.assertEqual(len(index["scenarios"]), 10)
            self.assertEqual(index["versions"], [18, 20, 22])
            self.assertTrue(Path(directory, "all", "motion", "v22", "manifest.json").is_file())
            self.assertTrue(
                Path(directory, "all", "motion", "comparison-v20-v22.json").is_file()
            )

    def test_qd_commands_are_canonical_and_replay_identical_output_trees(self):
        scenario = ROOT / "scenarios" / "motion.json"
        cases = (
            (("run", str(scenario), "--version", "22"), Path("manifest.json")),
            (
                (
                    "compare",
                    str(scenario),
                    "--from-version",
                    "20",
                    "--to-version",
                    "22",
                ),
                Path("v22/manifest.json"),
            ),
            (("run-all",), Path("motion/v22/manifest.json")),
        )
        for arguments, manifest_path in cases:
            with self.subTest(command=arguments[0]), TemporaryDirectory() as directory:
                first = Path(directory, "first")
                replay = Path(directory, "replay")
                original = run_cli(*arguments, "--output", str(first))
                self.assertEqual(original.returncode, 0, original.stderr)
                command = json.loads((first / manifest_path).read_text())["command"]
                self.assertEqual(command[:3], ["python3", "-m", "pontusm_sim"])
                self.assertIn("<output-directory>", command)
                self.assertNotIn(str(first), command)
                environment = os.environ.copy()
                environment["PYTHONPATH"] = str(ROOT)
                rerun = subprocess.run(
                    [str(replay) if item == "<output-directory>" else item for item in command],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(rerun.returncode, 0, rerun.stderr)
                first_files = {
                    path.relative_to(first): path.read_bytes()
                    for path in first.rglob("*")
                    if path.is_file()
                }
                replay_files = {
                    path.relative_to(replay): path.read_bytes()
                    for path in replay.rglob("*")
                    if path.is_file()
                }
                self.assertEqual(replay_files, first_files)

    def test_archive_backed_output_cannot_be_reused_without_an_archive(self):
        verification = SourceVerification(
            version=AlgorithmVersion.V22,
            outer_sha256="a" * 64,
            archive_members=("release/media.tgz",),
            archive_hashes={"release/media.tgz": "b" * 64},
            qd_source_member="QD_burn_in.c",
            qd_source_sha256="c" * 64,
            orbit_source_member="bip_orbit_table.c",
            orbit_source_sha256="d" * 64,
            constants={"QD_burn_in_ver": 22},
            orbit_tables={
                "orbit_table": ((0, 0), (1, 0)),
                "orbit_table_32x16": ((0, 0), (0, 1)),
                "orbit_table_ew": ((0, 0),),
            },
            orbit_counts={
                "orbit_table": 2,
                "orbit_table_32x16": 2,
                "orbit_table_ew": 1,
            },
            orbit_bounds={
                "orbit_table": OrbitBounds(0, 1, 0, 0),
                "orbit_table_32x16": OrbitBounds(0, 0, 0, 1),
                "orbit_table_ew": OrbitBounds(0, 0, 0, 0),
            },
            warnings=(),
        )
        from pontusm_sim.cli import main

        with TemporaryDirectory() as directory:
            output = Path(directory, "result")
            arguments = [
                "run",
                str(ROOT / "scenarios" / "rotation-orbit.json"),
                "--version",
                "22",
                "--archive",
                str(Path(directory, "fixture.zip")),
                "--output",
                str(output),
            ]
            stream = io.StringIO()
            with mock.patch("pontusm_sim.cli._verified_source", return_value=verification):
                with redirect_stdout(stream):
                    self.assertEqual(main(arguments), 0)
            self.assertTrue((output / "bip.json").is_file())
            before = {
                path.relative_to(output): path.read_bytes()
                for path in output.rglob("*")
                if path.is_file()
            }
            error = io.StringIO()
            without_archive = [item for item in arguments if item not in (
                "--archive", str(Path(directory, "fixture.zip"))
            )]
            with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", error):
                self.assertEqual(main(without_archive), 2)
            after = {
                path.relative_to(output): path.read_bytes()
                for path in output.rglob("*")
                if path.is_file()
            }
            self.assertEqual(after, before)
            self.assertIn("destination already exists", error.getvalue())

    def test_compare_failure_leaves_no_partial_output_tree(self):
        scenario = ROOT / "scenarios" / "motion.json"
        with TemporaryDirectory() as directory:
            output = Path(directory, "comparison")
            result = run_cli(
                "compare",
                str(scenario),
                "--archive-20",
                str(Path(directory, "missing.zip")),
                "--output",
                str(output),
            )
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

    def test_run_refuses_a_preexisting_symlink_destination(self):
        scenario = ROOT / "scenarios" / "motion.json"
        with TemporaryDirectory() as directory:
            target = Path(directory, "target")
            target.mkdir()
            output = Path(directory, "result")
            output.symlink_to(target, target_is_directory=True)
            result = run_cli(
                "run", str(scenario), "--version", "22", "--output", str(output)
            )
            self.assertEqual(result.returncode, 2)
            self.assertTrue(output.is_symlink())
            self.assertEqual(list(target.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
