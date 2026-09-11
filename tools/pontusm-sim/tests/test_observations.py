"""Synthetic evidence exercises strict, read-only capture loading."""

import copy
from dataclasses import FrozenInstanceError
import hashlib
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pontusm_sim.observations import CaptureManifest, Observation, CapturePackage, load_capture


def manifest(raw):
    return {
        "schema_version": 1, "capture_id": "synthetic-template-test",
        "device": {"model": "MSI MAG 341CQP", "firmware": "FW.041", "panel": "QMC340CC01-D01"},
        "timebase": {"unit": "us", "uncertainty_us": 1000},
        "observations": {"path": "observations.jsonl", "sha256": hashlib.sha256(raw).hexdigest()},
        "calibration": {"x_sign": 1, "y_sign": -1, "swap_axes": False},
        "notes": "synthetic-template; no hardware evidence",
    }


def observation(**changes):
    return {"trial": "trial-1", "sequence": 0, "time_us": 0,
            "channel": "display.offset_px", "value": {"x": -3, "y": 2},
            "unit": "px", "quality": "measured", **changes}


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "capture.json"

    def write(self, records=None, *, raw=None, payload=None):
        if raw is None:
            raw = ("\n".join(json.dumps(r) for r in (
                [observation()] if records is None else records)) + "\n").encode()
        (self.root / "observations.jsonl").write_bytes(raw)
        self.path.write_text(json.dumps(manifest(raw) if payload is None else payload), encoding="utf-8")
        return self.path

    def test_valid_capture_preserves_order_values_and_exact_evidence(self):
        records = [observation(), observation(trial="trial-2", time_us=800),
                   observation(sequence=2, time_us=0, quality="derived", sources=[0])]
        path = self.write(records)
        before = (path.read_bytes(), (self.root / "observations.jsonl").read_bytes())
        result = load_capture(str(path))
        self.assertIsInstance(result, CapturePackage)
        self.assertIsInstance(result.manifest, CaptureManifest)
        self.assertIsInstance(result.observations[0], Observation)
        self.assertEqual([r.sequence for r in result.observations], [0, 0, 2])
        self.assertEqual([r.time_us for r in result.observations], [0, 800, 0])
        self.assertEqual(result.observations[0].value, {"x": -3, "y": 2})
        self.assertEqual(result.observations[2].sources, (0,))
        self.assertEqual(result.manifest.calibration["y_sign"], -1)
        self.assertEqual(result.manifest_sha256, hashlib.sha256(before[0]).hexdigest())
        self.assertEqual(result.observations_sha256, hashlib.sha256(before[1]).hexdigest())
        self.assertEqual(before, (path.read_bytes(), (self.root / "observations.jsonl").read_bytes()))

    def test_results_are_recursively_immutable(self):
        package = load_capture(self.write([observation(channel="msi.register.transaction",
            value={"operation": "write", "address": 112, "data": [1, 255]}, unit="none")]))
        with self.assertRaises(FrozenInstanceError):
            package.manifest.capture_id = "changed"
        with self.assertRaises(FrozenInstanceError):
            package.observations[0].time_us = 1
        with self.assertRaises(TypeError):
            package.manifest.device["model"] = "changed"
        with self.assertRaises(TypeError):
            package.observations[0].value["address"] = 1
        self.assertIsInstance(package.observations, tuple)
        self.assertEqual(package.observations[0].value["data"], (1, 255))

    def test_all_channels_accept_valid_boundary_values(self):
        values = [
            ("stimulus.phase", "still", "none"),
            ("control.pixel_shift_enabled", False, "none"),
            ("control.pixel_shift_speed", 2, "none"),
            ("display.offset_px", {"x": 0, "y": -4}, "px"),
            ("display.roi_luma_ratio", 0, "ratio"),
            ("display.control_luma_ratio", 1.5, "ratio"),
            ("display.uniform_luma_ratio", 0.875, "ratio"),
            ("panel.temperature_raw", 65535, "raw"),
            ("panel.off_sensing_event", "done", "none"),
            ("msi.register.transaction", {"operation": "read", "address": 65535, "data": [0]}, "none"),
        ]
        records = [observation(sequence=i, time_us=i, channel=c, value=v, unit=u,
                               quality="decoded") for i, (c, v, u) in enumerate(values)]
        self.assertEqual(len(load_capture(self.write(records)).observations), 10)

    def test_hash_must_match_exact_bytes_before_json_parsing(self):
        raw = b"this is invalid JSON\xff\n"
        payload = manifest(raw)
        payload["observations"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            load_capture(self.write(raw=raw, payload=payload))
        self.write()
        with (self.root / "observations.jsonl").open("ab") as stream:
            stream.write(b" ")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            load_capture(self.path)

    def test_hash_requires_lowercase_64_hex_characters(self):
        raw = (json.dumps(observation()) + "\n").encode()
        valid = manifest(raw)
        self.assertEqual(len(load_capture(self.write(raw=raw, payload=valid)).observations), 1)
        for bad in (valid["observations"]["sha256"].upper(), "g" * 64, "0" * 63, 123, None):
            payload = manifest(raw)
            payload["observations"]["sha256"] = bad
            with self.subTest(hash=bad), self.assertRaisesRegex(
                    ValueError, r"observations\.sha256 must be 64 lowercase hex characters"):
                load_capture(self.write(raw=raw, payload=payload))

    def test_member_path_rejects_absolute_traversal_and_ambiguous_components(self):
        raw = (json.dumps(observation()) + "\n").encode()
        (self.root / "a").mkdir()
        for bad in (str(self.root / "observations.jsonl"), "../x", "a/../observations.jsonl", "./observations.jsonl",
                    "a//x", "", ".", "a\\x", "C:\\x", "x\x00"):
            payload = manifest(raw)
            payload["observations"]["path"] = bad
            with self.subTest(path=bad), self.assertRaises(ValueError):
                load_capture(self.write(raw=raw, payload=payload))

    def test_regular_nested_member_is_supported(self):
        self.write()
        (self.root / "nested").mkdir()
        (self.root / "observations.jsonl").rename(self.root / "nested" / "records.jsonl")
        payload = json.loads(self.path.read_text())
        payload["observations"]["path"] = "nested/records.jsonl"
        self.path.write_text(json.dumps(payload))
        self.assertEqual(len(load_capture(self.path).observations), 1)

    def test_symlink_member_and_parent_rejected_even_when_target_is_inside(self):
        for directory_link in (False, True):
            with self.subTest(parent=directory_link):
                self.write()
                actual = self.root / ("actual-dir" if directory_link else "actual.jsonl")
                if directory_link:
                    actual.mkdir()
                    (self.root / "observations.jsonl").rename(actual / "records.jsonl")
                    (self.root / "link").symlink_to(actual, target_is_directory=True)
                    member = "link/records.jsonl"
                else:
                    (self.root / "observations.jsonl").rename(actual)
                    (self.root / "observations.jsonl").symlink_to(actual)
                    member = "observations.jsonl"
                payload = json.loads(self.path.read_text())
                payload["observations"]["path"] = member
                self.path.write_text(json.dumps(payload))
                with self.assertRaises(ValueError):
                    load_capture(self.path)
                if not directory_link:
                    (self.root / "observations.jsonl").unlink()

    def test_manifest_symlink_and_nonregular_inputs_rejected(self):
        self.write()
        link = self.root / "capture-link.json"
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            load_capture(link)
        with self.assertRaises(ValueError):
            load_capture(self.root)
        member = self.root / "observations.jsonl"
        member.unlink()
        member.mkdir()
        with self.assertRaises(ValueError):
            load_capture(self.path)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires named pipes")
    def test_fifo_is_rejected_without_blocking(self):
        self.write()
        member = self.root / "observations.jsonl"
        member.unlink()
        os.mkfifo(member)
        with self.assertRaises(ValueError):
            load_capture(self.path)

    def test_missing_files_raise_value_error(self):
        with self.assertRaises(ValueError):
            load_capture(self.path)
        self.write()
        (self.root / "observations.jsonl").unlink()
        with self.assertRaises(ValueError):
            load_capture(self.path)

    def test_duplicate_json_keys_are_rejected_in_both_files(self):
        self.write()
        self.path.write_text(self.path.read_text().replace('"schema_version": 1',
            '"schema_version": 1, "schema_version": 1'))
        with self.assertRaises(ValueError):
            load_capture(self.path)
        for raw in (json.dumps(observation()).replace('"x": -3', '"x": -3, "x": 8'),
                    json.dumps(observation()).replace('"sequence": 0', '"sequence": 0, "sequence": 1')):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                load_capture(self.write(raw=(raw + "\n").encode()))

    def test_unknown_manifest_fields_rejected_at_every_level(self):
        for level in ("root", "device", "timebase", "observations", "calibration"):
            self.write()
            payload = json.loads(self.path.read_text())
            (payload if level == "root" else payload[level])["extra"] = 1
            self.path.write_text(json.dumps(payload))
            with self.subTest(level=level), self.assertRaises(ValueError):
                load_capture(self.path)

    def test_missing_manifest_fields_rejected_at_every_level(self):
        raw = (json.dumps(observation()) + "\n").encode()
        original = manifest(raw)
        for level in ("root", "device", "timebase", "observations", "calibration"):
            for key in (original if level == "root" else original[level]):
                if key == "notes":
                    continue
                payload = copy.deepcopy(original)
                del (payload if level == "root" else payload[level])[key]
                with self.subTest(level=level, key=key), self.assertRaises(ValueError):
                    load_capture(self.write(raw=raw, payload=payload))

    def test_manifest_types_ranges_and_units_are_strict(self):
        raw = (json.dumps(observation()) + "\n").encode()
        cases = [(None, "schema_version", True), (None, "schema_version", 2),
                 (None, "capture_id", " "), (None, "notes", []), (None, "device", []),
                 ("device", "model", 3), ("device", "firmware", ""),
                 ("timebase", "unit", "ms"), ("timebase", "uncertainty_us", -1),
                 ("timebase", "uncertainty_us", True), ("timebase", "uncertainty_us", 1.0),
                 ("calibration", "x_sign", True), ("calibration", "x_sign", 0),
                 ("calibration", "y_sign", 1.0), ("calibration", "swap_axes", 0)]
        for level, key, value in cases:
            payload = manifest(raw)
            (payload if level is None else payload[level])[key] = value
            with self.subTest(level=level, key=key, value=value), self.assertRaises(ValueError):
                load_capture(self.write(raw=raw, payload=payload))

    def test_required_observation_fields_and_unknown_fields(self):
        for key in observation():
            record = observation()
            del record[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                load_capture(self.write([record]))
        with self.assertRaises(ValueError):
            load_capture(self.write([observation(extra=1)]))

    def test_observation_types_and_quality_are_strict(self):
        for key, value in (("trial", " "), ("trial", 1), ("sequence", True),
                           ("sequence", -1), ("sequence", 0.5), ("time_us", True),
                           ("time_us", -1), ("time_us", 0.0), ("quality", "inferred"),
                           ("quality", []), ("channel", "unknown"), ("channel", {}),
                           ("unit", None)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                load_capture(self.write([observation(**{key: value})]))

    def test_sequences_strictly_increase_and_times_never_decrease_per_trial(self):
        for record in (observation(sequence=5, time_us=10), observation(sequence=4, time_us=11),
                       observation(sequence=6, time_us=9)):
            with self.subTest(record=record), self.assertRaises(ValueError):
                load_capture(self.write([observation(sequence=5, time_us=10),
                    observation(trial="other"), record]))

    def test_derived_requires_nonempty_unique_prior_sources_in_same_trial(self):
        for sources in (None, [], [1], [2], [0, 0], [True], [-1], [0.0], "0"):
            derived = observation(sequence=1, time_us=1, quality="derived")
            if sources is not None:
                derived["sources"] = sources
            with self.subTest(sources=sources), self.assertRaises(ValueError):
                load_capture(self.write([observation(), derived]))
        with self.assertRaises(ValueError):
            load_capture(self.write([observation(trial="other"),
                observation(sequence=1, quality="derived", sources=[0])]))

    def test_nonderived_cannot_claim_source_sequences(self):
        for quality in ("measured", "decoded"):
            with self.subTest(quality=quality), self.assertRaises(ValueError):
                load_capture(self.write([observation(),
                    observation(sequence=1, quality=quality, sources=[0])]))

    def test_channels_reject_wrong_shapes_ranges_and_units(self):
        cases = {
            "stimulus.phase": ("none", ["", " ", 1, {}]),
            "control.pixel_shift_enabled": ("none", [0, 1, "true"]),
            "control.pixel_shift_speed": ("none", [True, -1, 3, 1.0]),
            "display.offset_px": ("px", [[0, 0], {"x": 1}, {"x": True, "y": 0},
                {"x": 0.5, "y": 1}, {"x": 0, "y": 1, "z": 0}]),
            "display.roi_luma_ratio": ("ratio", [-0.1, True, "1", float("inf"), float("nan")]),
            "display.control_luma_ratio": ("ratio", [-1, {}]),
            "display.uniform_luma_ratio": ("ratio", [False, []]),
            "panel.temperature_raw": ("raw", [-1, 65536, True, 640.0]),
            "panel.off_sensing_event": ("none", ["", [], 1]),
            "msi.register.transaction": ("none", [[], {"operation": "erase", "address": 0, "data": [0]},
                {"operation": "write", "address": True, "data": [0]},
                {"operation": "write", "address": 65536, "data": [0]},
                {"operation": "write", "address": 0, "data": []},
                {"operation": "write", "address": 0, "data": [256]},
                {"operation": "write", "address": 0, "data": [True]},
                {"operation": "write", "address": 0, "data": [0], "extra": 1}]),
        }
        for channel, (unit, values) in cases.items():
            for value in values:
                with self.subTest(channel=channel, value=value), self.assertRaises(ValueError):
                    load_capture(self.write([observation(channel=channel, value=value, unit=unit)]))
        for unit in ("none", "pixel", "pixels", "PX"):
            with self.subTest(unit=unit), self.assertRaises(ValueError):
                load_capture(self.write([observation(unit=unit)]))

    def test_complete_stream_is_validated_and_malformed_json_is_rejected(self):
        valid = json.dumps(observation()).encode()
        for raw in (b"", b"\n", b"{}\n", b"[]\n", valid + b"\n\n", valid + b"\n{broken\n",
                    valid + b"\nnull\n", valid + b"\n\xff", b"\xef\xbb\xbf" + valid,
                    valid + b" trailing", valid + b"\n" + json.dumps(observation(sequence=1, extra=2)).encode()):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                load_capture(self.write(raw=raw))

    def test_synthetic_template_authenticates_and_labels_33_positions(self):
        path = Path(__file__).resolve().parents[1] / "capture-templates/pixel-shift/capture.json"
        package = load_capture(path)
        self.assertIn("synthetic-template", package.manifest.capture_id)
        self.assertIn("synthetic-template", package.manifest.notes)
        positions = [row for row in package.observations if row.channel == "display.offset_px"]
        self.assertEqual(len(positions), 33)
        self.assertEqual(positions[0].value, positions[-1].value)

    def test_optional_notes_can_be_absent_and_no_final_newline_is_required(self):
        raw = json.dumps(observation()).encode()
        payload = manifest(raw)
        del payload["notes"]
        package = load_capture(self.write(raw=raw, payload=payload))
        self.assertIsNone(package.manifest.notes)
        self.assertEqual(len(package.observations), 1)

    def test_nonfinite_numbers_and_malformed_manifest_are_rejected(self):
        for raw in (b"[]", b"null", b"\xff", b"{", b"\xef\xbb\xbf{}", b'{"x": 1e999}'):
            self.write()
            self.path.write_bytes(raw)
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                load_capture(self.path)
        for number in ("1e999", "-Infinity", "NaN"):
            raw = json.dumps(observation(channel="display.roi_luma_ratio", value=1.5, unit="ratio"))
            with self.subTest(number=number), self.assertRaises(ValueError):
                load_capture(self.write(raw=raw.replace('"value": 1.5', '"value": ' + number).encode()))


if __name__ == "__main__":
    unittest.main()
