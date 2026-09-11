"""Synthetic capture/archive integration; never a real MSI observation."""

from contextlib import redirect_stderr, redirect_stdout
import csv
import ctypes
import errno
import hashlib
import io
import json
import os
import sys
from pathlib import Path
import tarfile
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

from pontusm_sim.capture_reporting import write_capture_comparison
from pontusm_sim import publication, source
from pontusm_sim.types import AlgorithmVersion


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def fixture(directory):
    rows = [
        {"trial": "trial", "sequence": i, "time_us": i * 10,
         "channel": "display.offset_px", "value": {"x": x, "y": y},
         "unit": "px", "quality": "measured"}
        for i, (x, y) in enumerate(((0, 0), (0, -1), (0, 0)))
    ]
    rows.append({"trial": "trial", "sequence": 3, "time_us": 30,
        "channel": "panel.off_sensing_event", "value": "done",
        "unit": "none", "quality": "decoded"})
    raw = b"".join((json.dumps(r) + "\n").encode() for r in rows)
    Path(directory, "observations.jsonl").write_bytes(raw)
    manifest = {"schema_version": 1, "capture_id": "synthetic-report",
        "device": {"model": "synthetic", "firmware": "none", "panel": "none"},
        "timebase": {"unit": "us", "uncertainty_us": 0},
        "observations": {"path": "observations.jsonl", "sha256": sha(raw)},
        "calibration": {"x_sign": -1, "y_sign": 1, "swap_axes": True},
        "notes": "synthetic fixture, no hardware"}
    capture = Path(directory, "capture.json")
    capture.write_text(json.dumps(manifest, indent=2) + "\n")
    common = {"trial": "trial", "accepted_qualities": ["measured"]}
    orbit = {**common, "type": "orbit_sequence", "orbit": "normal",
             "coordinates": "absolute", "sequences": [0, 1]}
    predicates = [
        {**orbit, "id": "v18", "version": 18},
        {**orbit, "id": "v20", "version": 20},
        {**orbit, "id": "ambiguous", "version": 18, "sequences": [0]},
        {**common, "id": "cadence", "type": "cadence_interval",
         "channel": "display.offset_px", "sequences": [0, 1, 2],
         "minimum_us": 1, "maximum_us": 5},
        {**common, "id": "context", "type": "context",
         "channel": "panel.off_sensing_event", "accepted_qualities": ["decoded"]},
        {**orbit, "id": "rotation-v20", "version": 20, "orbit": "rotation"},
    ]
    hypotheses = Path(directory, "hypotheses.json")
    hypotheses.write_text(json.dumps({"schema_version": 1, "hypotheses": predicates,
                                     "notes": "synthetic hypotheses"}, indent=2))
    return capture, hypotheses


def archive_fixture(directory, version):
    """Release-shaped ZIP/ZIP/ZIP and ZIP/TGZ fixtures, never official data."""
    def zipped(members):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            for name, raw in members.items():
                archive.writestr(name, raw)
        return stream.getvalue()

    def tarred(members):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, raw in members.items():
                member = tarfile.TarInfo(name)
                member.size = len(raw)
                archive.addfile(member, io.BytesIO(raw))
        return stream.getvalue()

    qd = f"u32 QD_burn_in_ver = {version};".encode()
    table = (b"static struct ORBIT orbit_table[] = {\n"
             + (b"{0,0},{1,0},{0,0},{0,1}" if version == 18 else b"{9,9},{8,9}")
             + b"\n};")
    table += b"\nstatic struct ORBIT orbit_table_ew[] = {{-1,0}};\n"
    expectations = [source._OrbitExpectation("orbit_table", 4 if version == 18 else 2,
        source.OrbitBounds(0, 1, 0, 1) if version == 18 else source.OrbitBounds(8, 9, 9, 9)),
        source._OrbitExpectation("orbit_table_ew", 1, source.OrbitBounds(-1, -1, 0, 0))]
    if version == 18:
        qd_member = "tztv-media-sec/sdp_pqe_frc/frc/pontusm/QD_burn_in.c"
        orbit_member = "tztv-media-sec/sdp_pqe_dp/dp/pontusm/bip_orbit_table.h"
        media = zipped({qd_member: qd, orbit_member: table})
        nested = zipped({"tztv-media-oscarp_pontusm.zip": media})
        outer = zipped({"22_SmartMonitor_PontusM.zip": nested})
        layers = (source._ArchiveLayer("22_SmartMonitor_PontusM.zip", sha(nested)),
                  source._ArchiveLayer("tztv-media-oscarp_pontusm.zip", sha(media)))
    else:
        table += (b"static struct ORBIT orbit_table_24x16[] = {{0,0}};\n"
                  b"static struct ORBIT orbit_table_32x16[] = {{0,0},{1,0},{0,2}};\n")
        expectations.extend((
            source._OrbitExpectation("orbit_table_24x16", 1, source.OrbitBounds(0, 0, 0, 0)),
            source._OrbitExpectation("orbit_table_32x16", 3, source.OrbitBounds(0, 1, 0, 2))))
        qd_member = "tztv-media-sec/sdp_pqe_frc/pontusm/QD_burn_in.c"
        orbit_member = "tztv-media-sec/sdp_pqe_dp/pontusm/bip_orbit_table.c"
        media = tarred({qd_member: qd, orbit_member: table})
        outer = zipped({"23_DTV_PontusML/tztv-media-sec.tgz": media})
        layers = (source._ArchiveLayer("23_DTV_PontusML/tztv-media-sec.tgz", sha(media)),)
    path = Path(directory, f"v{version}.zip")
    path.write_bytes(outer)
    spec = source._ReleaseSpec(sha(outer), layers, qd_member, sha(qd), orbit_member,
                              sha(table), version, tuple(expectations), ())
    return path, spec


class CaptureReportingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.capture, self.hypotheses = fixture(self.directory)
        self.a18, s18 = archive_fixture(self.directory, 18)
        self.a20, s20 = archive_fixture(self.directory, 20)
        self.a22, s22 = archive_fixture(self.directory, 22)
        self.specs = {
            AlgorithmVersion.V18: s18,
            AlgorithmVersion.V20: s20,
            AlgorithmVersion.V22: s22,
        }
        self.catalog = patch.dict(source._RELEASE_SPECS, self.specs)
        self.catalog.start()
        self.addCleanup(self.catalog.stop)

    def write(self, destination="out", **kwargs):
        output = self.directory / destination
        digests = write_capture_comparison(self.capture, self.hypotheses, output, **kwargs)
        return output, digests

    def test_four_artifacts_are_identical_across_destinations_and_hash_exact_inputs(self):
        first, digests = self.write("one", archive_18=self.a18, archive_20=self.a20)
        second, _ = self.write("two", archive_18=self.a18, archive_20=self.a20)
        names = {"manifest.json", "comparison.json", "aligned.csv", "report.md"}
        self.assertEqual({p.name for p in first.iterdir()}, names)
        for name in names:
            raw = (first / name).read_bytes()
            self.assertEqual(raw, (second / name).read_bytes())
            self.assertEqual(digests.files[name], sha(raw))
        manifest = json.loads((first / "manifest.json").read_text())
        self.assertEqual(manifest["capture"]["manifest_sha256"], sha(self.capture.read_bytes()))
        self.assertEqual(manifest["capture"]["observations_sha256"],
                         sha((self.directory / "observations.jsonl").read_bytes()))
        self.assertEqual(manifest["hypotheses_sha256"], sha(self.hypotheses.read_bytes()))
        self.assertEqual(manifest["calibration"], {"x_sign": -1, "y_sign": 1, "swap_axes": True})
        for version in (18, 20):
            provenance = manifest["sources"][str(version)]
            spec = self.specs[AlgorithmVersion(version)]
            self.assertEqual(provenance["outer_sha256"], spec.outer_sha256)
            self.assertEqual(provenance["archive_hashes"],
                             {layer.member_suffix: layer.sha256 for layer in spec.archive_layers})
            self.assertEqual(provenance["qd_source_sha256"], spec.qd_source_sha256)
            self.assertEqual(provenance["orbit_source_sha256"], spec.orbit_source_sha256)
        for name, digest in manifest["artifact_sha256"].items():
            self.assertEqual(digest, sha((first / name).read_bytes()))

    def test_version_22_archive_is_verified_and_recorded(self):
        output, _ = self.write(archive_22=self.a22)
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertEqual(manifest["verified_source_versions"], [22])
        self.assertEqual(
            manifest["sources"]["22"]["outer_sha256"],
            self.specs[AlgorithmVersion.V22].outer_sha256,
        )

    def test_report_keeps_all_results_counts_survivors_first_contradiction_and_sections(self):
        output, _ = self.write(archive_18=self.a18)
        report = (output / "report.md").read_text()
        comparison = json.loads((output / "comparison.json").read_text())
        for section in ("direct", "proxy", "context-only", "unavailable"):
            self.assertIn(f"## {section}\n", report)
        results = {r["id"]: r for r in comparison["results"]}
        self.assertEqual(results["v18"]["surviving_indices"], [0])
        self.assertEqual(results["ambiguous"]["surviving_indices"], [0, 2])
        self.assertEqual(results["ambiguous"]["status"], "indeterminate")
        self.assertEqual(results["cadence"]["evidence_count"], 3)
        self.assertEqual(comparison["evidence_counts"]["observations"], 4)
        self.assertEqual(comparison["evidence_counts"]["referenced_observations"], 4)
        self.assertEqual(comparison["first_contradiction"]["hypothesis_id"], "cadence")
        self.assertEqual(comparison["first_contradiction"]["sequences"], [0, 1])
        self.assertIn("[0, 2]", report)
        self.assertNotIn('"score"', (output / "comparison.json").read_text())
        self.assertIn("non-discriminating", report)
        with (output / "aligned.csv").open(newline="") as stream:
            rows = list(csv.DictReader(stream))
        self.assertEqual(len(rows), 8)
        self.assertEqual([r["status"] for r in rows if r["hypothesis_id"] == "cadence"],
                         ["contradicted", "contradicted"])

    def test_zero_one_or_both_archives_never_cross_satisfy_declared_versions(self):
        for versions in ((), (18,), (20,), (18, 20)):
            with self.subTest(versions=versions):
                output, _ = self.write("out-" + str(versions),
                    **{f"archive_{v}": getattr(self, f"a{v}") for v in versions})
                payload = json.loads((output / "comparison.json").read_text())
                results = {r["id"]: r for r in payload["results"]}
                self.assertEqual(results["v18"]["status"], "consistent" if 18 in versions else "indeterminate")
                self.assertEqual(results["v20"]["status"], "contradicted" if 20 in versions else "indeterminate")
                self.assertEqual(results["rotation-v20"]["status"], "consistent" if 20 in versions else "indeterminate")
                self.assertEqual(results["rotation-v20"]["surviving_indices"], [0] if 20 in versions else [])
                if 20 not in versions:
                    self.assertIn("orbit_table_32x16", results["rotation-v20"]["reason"])
                for version in (18, 20):
                    if version not in versions:
                        item = results[f"v{version}"]
                        self.assertEqual(item["category"], "unavailable")
                        self.assertIn(f"v{version}", item["reason"])
                        self.assertIn(f"--archive-{version}", item["reason"])
                        self.assertIn("orbit_table", item["reason"])
                self.assertEqual(results["cadence"]["status"], "contradicted")
                self.assertEqual(results["context"]["category"], "context-only")

    def test_human_report_marks_non_orbit_survivor_indices_not_applicable(self):
        output, _ = self.write(archive_18=self.a18, archive_20=self.a20)
        report = (output / "report.md").read_text()
        results = {r["id"]: r for r in json.loads((output / "comparison.json").read_text())["results"]}
        for name in ("cadence", "context"):
            with self.subTest(predicate=name):
                paragraph = next(p for p in report.split("\n\n") if p.startswith(f'- `"{name}"`'))
                self.assertIn("surviving indices: not applicable", paragraph)
                self.assertNotIn("surviving indices: `[]`", paragraph)
                self.assertEqual(results[name]["surviving_indices"], [])
        for name, expected in (("v18", "[0]"), ("ambiguous", "[0, 2]"), ("v20", "[]")):
            with self.subTest(orbit=name):
                paragraph = next(p for p in report.split("\n\n") if p.startswith(f'- `"{name}"`'))
                self.assertIn(f"surviving indices: `{expected}`", paragraph)
                self.assertNotIn("not applicable", paragraph)

    def test_validation_failure_never_creates_output_or_changes_existing_files(self):
        for failure in ("capture", "hypotheses", "archive", "epoch"):
            with self.subTest(failure=failure), TemporaryDirectory() as directory:
                capture, hypotheses = fixture(directory)
                args = {}
                if failure == "capture":
                    Path(directory, "observations.jsonl").write_text("tampered")
                elif failure == "hypotheses":
                    hypotheses.write_text('{"schema_version":1,"hypotheses":[]}')
                elif failure == "archive":
                    args = {"archive_18": self.a18, "archive_20": capture}
                else:
                    args = {"artifact_epoch": "bad\nepoch"}
                output = Path(directory, "absent")
                with self.assertRaises(ValueError):
                    write_capture_comparison(capture, hypotheses, output, **args)
                self.assertFalse(output.exists())
                output.mkdir()
                (output / "manifest.json").write_bytes(b"keep")
                with self.assertRaises(ValueError):
                    write_capture_comparison(capture, hypotheses, output, **args)
                self.assertEqual((output / "manifest.json").read_bytes(), b"keep")

    def test_each_run_reverifies_archive_bytes_even_at_the_same_path(self):
        self.write(archive_18=self.a18)
        self.a18.write_bytes(b"changed since first run")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.write("not-created", archive_18=self.a18)
        self.assertFalse((self.directory / "not-created").exists())

    def test_preexisting_destinations_are_refused_without_overwriting_inputs_or_extras(self):
        for kind in ("empty", "files", "file", "symlink", "input-directory"):
            with self.subTest(kind=kind):
                output = self.directory / ("existing-" + kind)
                if kind == "empty":
                    output.mkdir()
                elif kind == "files":
                    output.mkdir()
                    for name in ("manifest.json", "comparison.json", "aligned.csv", "report.md", "unrelated.txt"):
                        (output / name).write_bytes(b"original " + name.encode())
                elif kind == "file":
                    output.write_bytes(b"ordinary file")
                elif kind == "symlink":
                    output.symlink_to(self.directory / "absent-target")
                else:
                    output = self.directory
                before = {str(p.relative_to(self.directory)): p.read_bytes()
                          for p in self.directory.rglob("*") if p.is_file()}
                with self.assertRaisesRegex(ValueError, "destination.*exists"):
                    write_capture_comparison(self.capture, self.hypotheses, output)
                after = {str(p.relative_to(self.directory)): p.read_bytes()
                         for p in self.directory.rglob("*") if p.is_file()}
                self.assertEqual(after, before)
                if kind == "symlink":
                    self.assertTrue(output.is_symlink())

    def test_mid_write_failure_leaves_no_destination_or_staging_directory(self):
        output = self.directory / "atomic"
        before = set(self.directory.iterdir())
        original_write = Path.write_bytes

        def write_then_fail(path, raw):
            self.assertFalse(output.exists(), "destination became visible before all files were written")
            if path.name == "aligned.csv":
                raise OSError("injected second-file write failure")
            return original_write(path, raw)

        with patch.object(Path, "write_bytes", write_then_fail):
            with self.assertRaisesRegex(OSError, "injected"):
                write_capture_comparison(self.capture, self.hypotheses, output)
        self.assertFalse(output.exists())
        self.assertEqual(set(self.directory.iterdir()), before)

    def test_publish_failure_cleans_the_complete_staging_bundle(self):
        output = self.directory / "atomic"
        before = set(self.directory.iterdir())
        def fail_publication(staging, destination):
            self.assertFalse(destination.exists())
            self.assertEqual({p.name for p in staging.iterdir()},
                             {"manifest.json", "comparison.json", "aligned.csv", "report.md"})
            raise OSError("injected publication failure")

        with patch.object(publication, "_publish", fail_publication):
            with self.assertRaisesRegex(OSError, "injected"):
                write_capture_comparison(self.capture, self.hypotheses, output)
        self.assertFalse(output.exists())
        self.assertEqual(set(self.directory.iterdir()), before)

    def test_native_publication_moves_the_whole_staged_directory(self):
        output = self.directory / "atomic"
        original_publish = publication._publish
        stage_identity = None

        def inspect_publication(staging, destination):
            nonlocal stage_identity
            self.assertFalse(destination.exists())
            stage_identity = (staging.stat().st_dev, staging.stat().st_ino)
            self.assertEqual({p.name for p in staging.iterdir()},
                             {"manifest.json", "comparison.json", "aligned.csv", "report.md"})
            original_publish(staging, destination)
            self.assertFalse(staging.exists(), "publication copied individual files instead of moving the bundle")

        with patch.object(publication, "_publish", inspect_publication):
            write_capture_comparison(self.capture, self.hypotheses, output)
        self.assertEqual((output.stat().st_dev, output.stat().st_ino), stage_identity)
        manifest = json.loads((output / "manifest.json").read_text())
        for name, digest in manifest["artifact_sha256"].items():
            self.assertEqual(sha((output / name).read_bytes()), digest)

    def test_destination_appearing_at_native_publish_is_never_replaced(self):
        native_publish = publication._publish
        for kind in ("empty-directory", "nonempty-directory", "file", "symlink"):
            with self.subTest(kind=kind):
                output = self.directory / ("raced-" + kind)
                before = set(self.directory.iterdir())
                race_identity = None

                def race(staging, destination):
                    nonlocal race_identity
                    if kind.endswith("directory"):
                        destination.mkdir()
                        if kind == "nonempty-directory":
                            (destination / "unrelated.txt").write_bytes(b"keep")
                    elif kind == "file":
                        destination.write_bytes(b"keep")
                    else:
                        destination.symlink_to(self.directory / "missing")
                    race_identity = (destination.lstat().st_dev, destination.lstat().st_ino)
                    # Hide preflight checks: the native operation must independently refuse it.
                    with patch.object(os.path, "lexists", return_value=False):
                        native_publish(staging, destination)

                with patch.object(publication, "_publish", race):
                    with self.assertRaisesRegex(ValueError, "destination.*exists"):
                        write_capture_comparison(self.capture, self.hypotheses, output)
                self.assertEqual((output.lstat().st_dev, output.lstat().st_ino), race_identity)
                self.assertEqual(set(self.directory.iterdir()), before | {output})
                if kind == "empty-directory":
                    self.assertEqual(list(output.iterdir()), [])
                elif kind == "nonempty-directory":
                    self.assertEqual((output / "unrelated.txt").read_bytes(), b"keep")
                    self.assertEqual(len(list(output.iterdir())), 1)
                elif kind == "file":
                    self.assertEqual(output.read_bytes(), b"keep")
                else:
                    self.assertTrue(output.is_symlink())

    def test_unsupported_platform_fails_without_publishing_or_leaking_stage(self):
        output = self.directory / "unsupported"
        before = set(self.directory.iterdir())
        with patch.object(sys, "platform", "unsupported-test-platform"):
            with self.assertRaisesRegex(OSError, "atomic no-replace.*unavailable"):
                write_capture_comparison(self.capture, self.hypotheses, output)
        self.assertEqual(set(self.directory.iterdir()), before)

    def test_missing_native_primitive_fails_without_fallback_or_output(self):
        output = self.directory / "unsupported-library"
        before = set(self.directory.iterdir())
        with patch.object(sys, "platform", "linux"), patch.object(ctypes, "CDLL", return_value=object()):
            with self.assertRaisesRegex(OSError, "atomic no-replace.*unavailable"):
                write_capture_comparison(self.capture, self.hypotheses, output)
        self.assertEqual(set(self.directory.iterdir()), before)

    def test_posix_native_flags_and_kernel_errors_never_fall_back(self):
        for platform in ("darwin", "linux"):
            for code in (errno.ENOSYS, errno.EINVAL, errno.EXDEV, errno.EACCES):
                with self.subTest(platform=platform, errno=code):
                    output = self.directory / "native-error"
                    before = set(self.directory.iterdir())

                    def reject(*arguments):
                        if platform == "darwin":
                            src, dst, flags = arguments
                            self.assertEqual(flags, 4)  # RENAME_EXCL, not RENAME_SWAP
                        else:
                            from_fd, src, to_fd, dst, flags = arguments
                            self.assertEqual((from_fd, to_fd, flags), (-100, -100, 1))
                        self.assertEqual(Path(os.fsdecode(src)).parents[1], output.parent)
                        self.assertEqual(os.fsdecode(dst), str(output))
                        self.assertFalse(output.exists())
                        ctypes.set_errno(code)
                        return -1

                    library = SimpleNamespace(renamex_np=reject, renameat2=reject)
                    with patch.object(sys, "platform", platform), patch.object(ctypes, "CDLL", return_value=library):
                        with self.assertRaises(OSError) as failure:
                            write_capture_comparison(self.capture, self.hypotheses, output)
                    self.assertEqual(failure.exception.errno, code)
                    self.assertEqual(set(self.directory.iterdir()), before)

    def test_windows_native_move_uses_no_copy_or_replace_flags_and_preserves_collision(self):
        output = self.directory / "windows-race"
        before = set(self.directory.iterdir())

        def collision(src, dst, flags):
            self.assertEqual(flags, 0)
            self.assertIsInstance(src, str)
            self.assertIsInstance(dst, str)
            self.assertEqual(Path(src).parents[1], output.parent)
            self.assertEqual(dst, str(output))
            output.mkdir()
            (output / "keep.txt").write_bytes(b"preserved")
            return 0

        with patch.object(sys, "platform", "win32"), \
             patch.object(ctypes, "WinDLL", return_value=SimpleNamespace(MoveFileExW=collision), create=True), \
             patch.object(ctypes, "get_last_error", return_value=183, create=True):
            with self.assertRaisesRegex(ValueError, "destination.*exists"):
                write_capture_comparison(self.capture, self.hypotheses, output)
        self.assertEqual(set(self.directory.iterdir()), before | {output})
        self.assertEqual({p.name for p in output.iterdir()}, {"keep.txt"})
        self.assertEqual((output / "keep.txt").read_bytes(), b"preserved")

    def test_cli_routes_zero_one_both_archives_through_real_verification(self):
        from pontusm_sim.cli import main
        for versions in ((), (18,), (20,), (18, 20)):
            with self.subTest(versions=versions):
                output = self.directory / ("cli-" + str(versions))
                arguments = ["compare-capture", str(self.capture), "--hypotheses", str(self.hypotheses),
                             "--output", str(output)]
                for version in versions:
                    arguments.extend((f"--archive-{version}", str(getattr(self, f"a{version}"))))
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(main(arguments), 0)
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertEqual(manifest["verified_source_versions"], list(versions))
                results = json.loads((output / "comparison.json").read_text())["results"]
                self.assertEqual(results[0]["status"], "consistent" if 18 in versions else "indeterminate")
                self.assertEqual(results[1]["status"], "contradicted" if 20 in versions else "indeterminate")
                self.assertEqual(results[-1]["status"], "consistent" if 20 in versions else "indeterminate")

    def test_both_archive_replay_preserves_release_order_rotation_and_accepted_epochs(self):
        from pontusm_sim.cli import main
        for index, epoch in enumerate(("-x", "epoch with spaces")):
            with self.subTest(epoch=epoch):
                output = self.directory / f"both-{index}"
                replay = self.directory / f"replay-{index}"
                arguments = ["compare-capture", str(self.capture), "--hypotheses", str(self.hypotheses),
                    "--archive-20", str(self.a20), "--archive-18", str(self.a18),
                    "--output", str(output), f"--artifact-epoch={epoch}"]
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(main(arguments), 0)
                manifest = json.loads((output / "manifest.json").read_text())
                command = manifest["command"]
                self.assertLess(command.index("--archive-18"), command.index("--archive-20"))
                self.assertEqual(manifest["created_at"], epoch)
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(main([str(replay) if arg == "<output-directory>" else arg
                                           for arg in command[3:]]), 0)
                self.assertIn(f"--artifact-epoch={epoch}", command)
                for name in ("manifest.json", "comparison.json", "aligned.csv", "report.md"):
                    self.assertEqual((output / name).read_bytes(), (replay / name).read_bytes())
                results = json.loads((replay / "comparison.json").read_text())["results"]
                self.assertEqual(results[-1]["surviving_indices"], [0])

    def test_csv_neutralizes_formula_prefixes_and_round_trips_other_text(self):
        labels = ("=label", "+label", "-label", "@label", "\tlabel", "\rlabel", "\nlabel",
                  "safe,\"雪\"\r\nsecond line", "safe\rcarriage-return", "  =label")
        for index, label in enumerate(labels):
            with self.subTest(label=label):
                capture, hypotheses = fixture(self.directory)
                observations = self.directory / "observations.jsonl"
                records = [json.loads(line) for line in observations.read_text().splitlines()]
                for record in records:
                    record["trial"] = label
                raw = b"".join((json.dumps(record) + "\n").encode() for record in records)
                observations.write_bytes(raw)
                manifest = json.loads(capture.read_text())
                manifest["observations"]["sha256"] = sha(raw)
                capture.write_text(json.dumps(manifest))
                document = json.loads(hypotheses.read_text())
                cadence = document["hypotheses"][3]
                cadence.update(id=label, trial=label)
                document["hypotheses"] = [cadence]
                hypotheses.write_text(json.dumps(document))
                output, _ = self.write(f"csv-{index}")
                with (output / "aligned.csv").open(newline="") as stream:
                    rows = list(csv.DictReader(stream))
                expected = label if index in (7, 8) else "'" + label
                self.assertEqual(len(rows), 2)
                self.assertEqual([row["hypothesis_id"] for row in rows], [expected, expected])
                self.assertEqual([row["trial"] for row in rows], [expected, expected])
                comparison = json.loads((output / "comparison.json").read_text())
                self.assertEqual(comparison["results"][0]["id"], label)
                self.assertEqual(comparison["alignments"][0]["hypothesis_id"], label)
                self.assertIn(json.dumps(label, ensure_ascii=True), (output / "report.md").read_text())

    def test_csv_negative_observed_text_is_safe_and_exact_value_remains_in_json(self):
        rows = [{"trial": "trial", "sequence": i, "time_us": 0, "channel": channel,
                 "value": value, "unit": "ratio", "quality": "measured"}
                for i, (channel, value) in enumerate((("display.roi_luma_ratio", 2),
                                                     ("display.control_luma_ratio", 1)))]
        raw = b"".join((json.dumps(row) + "\n").encode() for row in rows)
        (self.directory / "observations.jsonl").write_bytes(raw)
        manifest = json.loads(self.capture.read_text())
        manifest["observations"]["sha256"] = sha(raw)
        self.capture.write_text(json.dumps(manifest))
        self.hypotheses.write_text(json.dumps({"schema_version": 1, "hypotheses": [{
            "id": "negative-delta", "trial": "trial", "type": "roi_control_delta",
            "accepted_qualities": ["measured"], "roi_sequence": 0, "control_sequence": 1,
            "minimum_delta": 0, "value_uncertainty": 0, "maximum_skew_us": 0}]}))
        output, _ = self.write()
        with (output / "aligned.csv").open(newline="") as stream:
            aligned = list(csv.DictReader(stream))
        self.assertEqual(aligned[0]["observed"], "'-1")
        comparison = json.loads((output / "comparison.json").read_text())
        self.assertEqual(comparison["alignments"][0]["observed"], "-1")
        self.assertEqual(comparison["first_contradiction"]["observed"], "-1")
        self.assertIn('"observed": "-1"', (output / "report.md").read_text())

    def test_late_orbit_mismatch_reports_the_eliminating_observation(self):
        raw = (self.directory / "observations.jsonl").read_bytes()
        records = [json.loads(line) for line in raw.splitlines()]
        records[2]["value"] = {"x": 99, "y": 99}
        raw = b"".join((json.dumps(record) + "\n").encode() for record in records)
        (self.directory / "observations.jsonl").write_bytes(raw)
        manifest = json.loads(self.capture.read_text())
        manifest["observations"]["sha256"] = sha(raw)
        self.capture.write_text(json.dumps(manifest))
        document = json.loads(self.hypotheses.read_text())
        document["hypotheses"][0]["sequences"] = [0, 1, 2]
        self.hypotheses.write_text(json.dumps(document))
        output, _ = self.write(archive_18=self.a18)
        comparison = json.loads((output / "comparison.json").read_text())
        self.assertEqual(comparison["first_contradiction"]["hypothesis_id"], "v18")
        self.assertEqual(comparison["first_contradiction"]["sequences"], [2])
        expected = json.loads(comparison["first_contradiction"]["expected"])
        self.assertEqual(expected["coordinate_options"], [[0, 0]])
        self.assertEqual(expected["candidate_count_before"], 1)
        self.assertEqual(expected["candidate_count_after"], 0)
        with (output / "aligned.csv").open(newline="") as stream:
            rows = [row for row in csv.DictReader(stream) if row["hypothesis_id"] == "v18"]
        self.assertEqual([row["status"] for row in rows],
                         ["indeterminate", "consistent", "contradicted"])
        self.assertEqual(json.loads(rows[2]["expected"]), expected)
        self.assertTrue(all("coordinate_options" not in json.loads(row["expected"]) for row in rows[:2]))
        alignments = [row for row in comparison["alignments"] if row["hypothesis_id"] == "v18"]
        self.assertEqual([json.loads(row["expected"]).get("coordinate_options") for row in alignments],
                         [None, None, [[0, 0]]])

    def test_successful_full_length_artifacts_emit_no_expected_source_coordinates(self):
        observation_path = self.directory / "observations.jsonl"
        rows = [json.loads(line) for line in observation_path.read_text().splitlines()][:3]
        rows.append({**rows[0], "sequence": 3, "time_us": 30, "value": {"x": 1, "y": 0}})
        raw = b"".join((json.dumps(row) + "\n").encode() for row in rows)
        observation_path.write_bytes(raw)
        manifest = json.loads(self.capture.read_text())
        manifest["observations"]["sha256"] = sha(raw)
        self.capture.write_text(json.dumps(manifest))
        document = json.loads(self.hypotheses.read_text())
        document["hypotheses"] = [{**document["hypotheses"][0], "sequences": [0, 1, 2, 3]}]
        self.hypotheses.write_text(json.dumps(document))
        output, _ = self.write(archive_18=self.a18)
        comparison = json.loads((output / "comparison.json").read_text())
        self.assertIsNone(comparison["first_contradiction"])
        self.assertEqual(comparison["results"][0]["status"], "consistent")
        self.assertEqual(comparison["results"][0]["surviving_indices"], [0])
        self.assertEqual(len(comparison["alignments"]), 4)
        with (output / "aligned.csv").open(newline="") as stream:
            csv_rows = list(csv.DictReader(stream))
        for row in [*comparison["alignments"], *csv_rows]:
            self.assertNotIn("coordinate_options", json.loads(row["expected"]))
        self.assertNotIn("coordinate_options", (output / "report.md").read_text())

    def test_many_predicates_cannot_exceed_per_verified_version_disclosure_budget(self):
        positions = ((0, 0), (1, 0), (0, 1), (9, 9), (8, 9), (99, 99))
        rows = [{"trial": "trial", "sequence": i, "time_us": i * 10,
                 "channel": "display.offset_px", "value": {"x": x, "y": y},
                 "unit": "px", "quality": "measured"} for i, (x, y) in enumerate(positions)]
        raw = b"".join((json.dumps(row) + "\n").encode() for row in rows)
        (self.directory / "observations.jsonl").write_bytes(raw)
        manifest = json.loads(self.capture.read_text())
        manifest["observations"]["sha256"] = sha(raw)
        manifest["calibration"] = {"x_sign": 1, "y_sign": 1, "swap_axes": False}
        self.capture.write_text(json.dumps(manifest))
        base = json.loads(self.hypotheses.read_text())["hypotheses"][0]
        predicates = [{**base, "id": f"v{version}-probe-{i}", "version": version, "sequences": [i, 5]}
                      for version, indices in ((18, (0, 1, 2)), (20, (3, 4))) for i in indices]
        self.hypotheses.write_text(json.dumps({"schema_version": 1, "hypotheses": predicates}))
        output, _ = self.write(archive_18=self.a18, archive_20=self.a20)
        comparison = json.loads((output / "comparison.json").read_text())
        with (output / "aligned.csv").open(newline="") as stream:
            csv_rows = list(csv.DictReader(stream))
        for alignments in (comparison["alignments"], csv_rows):
            disclosed = [json.loads(row["expected"]) for row in alignments
                         if "coordinate_options" in json.loads(row["expected"])]
            for version in (18, 20):
                self.assertEqual(sum(point["version"] == version for point in disclosed), 1)
        self.assertEqual(json.loads(comparison["first_contradiction"]["expected"])["coordinate_options"],
                         [[0, 1], [1, 0]])
        self.assertTrue(all(result["status"] == "contradicted" for result in comparison["results"]))
        self.assertEqual(len(comparison["results"]), 5)

    def test_wrong_version_first_cannot_steal_retained_contradiction_disclosure(self):
        rows_path = self.directory / "observations.jsonl"
        rows = [json.loads(line) for line in rows_path.read_text().splitlines()]
        rows[1]["value"] = {"x": 99, "y": 99}
        raw = b"".join((json.dumps(row) + "\n").encode() for row in rows)
        rows_path.write_bytes(raw)
        manifest = json.loads(self.capture.read_text())
        manifest["observations"]["sha256"] = sha(raw)
        self.capture.write_text(json.dumps(manifest))
        base = json.loads(self.hypotheses.read_text())["hypotheses"][0]
        for version, other, expected in ((18, 20, [[0, 1], [1, 0]]), (20, 18, [[8, 9], [9, 9]])):
            with self.subTest(supplied=version):
                predicates = [{**base, "id": "missing-first", "version": other},
                              {**base, "id": "retained-first", "version": version},
                              {**base, "id": "retained-later", "version": version}]
                self.hypotheses.write_text(json.dumps({"schema_version": 1, "hypotheses": predicates}))
                output, _ = self.write(f"only-{version}", **{f"archive_{version}": getattr(self, f"a{version}")})
                comparison = json.loads((output / "comparison.json").read_text())
                first = comparison["first_contradiction"]
                self.assertEqual(first["hypothesis_id"], "retained-first")
                self.assertEqual(json.loads(first["expected"]).get("coordinate_options"), expected)
                self.assertEqual(comparison["results"][0]["status"], "indeterminate")
                self.assertEqual(comparison["results"][0]["category"], "unavailable")
                with (output / "aligned.csv").open(newline="") as stream:
                    csv_rows = list(csv.DictReader(stream))
                for alignments in (comparison["alignments"], csv_rows):
                    disclosed = [r for r in alignments if "coordinate_options" in r["expected"]]
                    self.assertEqual([r["hypothesis_id"] for r in disclosed], ["retained-first"])


if __name__ == "__main__":
    unittest.main()
