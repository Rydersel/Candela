"""Hand-calculated synthetic evidence; no physical capture or official tables."""

from dataclasses import replace
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pontusm_sim.capture_compare import load_hypotheses, compare_capture
from pontusm_sim.observations import CaptureManifest, CapturePackage, Observation, load_capture
from pontusm_sim.types import AlgorithmVersion


def row(sequence, time, value, channel="display.uniform_luma_ratio", quality="measured"):
    unit = "none" if channel in ("stimulus.phase", "panel.off_sensing_event") else "ratio"
    return Observation("trial", sequence, time, channel, value, unit, quality)


def capture(rows, uncertainty=0, **calibration):
    return CapturePackage(CaptureManifest(1, "synthetic-test", {},
        {"unit": "us", "uncertainty_us": uncertainty}, {},
        {"x_sign": 1, "y_sign": 1, "swap_axes": False, **calibration}), tuple(rows), "a"*64, "b"*64)


def predicate(kind, **fields):
    return {"id": "example", "type": kind, "trial": "trial",
            "accepted_qualities": ["measured"], **fields}


class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "hypotheses.json"

    def load(self, *predicates, **root):
        self.path.write_text(json.dumps({"schema_version": 1, "hypotheses": list(predicates), **root}))
        return load_hypotheses(self.path)

    def compare(self, rows, item, uncertainty=0, **kwargs):
        return compare_capture(capture(rows, uncertainty), self.load(item), **kwargs)

    def status(self, rows, item, expected, uncertainty=0):
        result = self.compare(rows, item, uncertainty)
        self.assertEqual(result.results[0].status, expected)
        return result.results[0]

    def test_cadence_inclusive_bounds_and_uncertainty_crossing(self):
        p = predicate("cadence_interval", channel="display.uniform_luma_ratio", sequences=[0, 1],
                      minimum_us=90, maximum_us=110)
        for time, uncertainty, expected in [(90, 0, "consistent"), (110, 0, "consistent"),
                (89, 0, "contradicted"), (111, 0, "contradicted"),
                (100, 5, "consistent"), (90, 1, "indeterminate"),
                (88, 1, "indeterminate"), (87, 1, "contradicted")]:
            with self.subTest(time=time, uncertainty=uncertainty):
                self.status([row(0, 0, 1), row(1, time, 1)], p, expected, uncertainty)

    def test_missing_or_unaccepted_quality_never_becomes_contradiction(self):
        p = predicate("cadence_interval", channel="display.uniform_luma_ratio", sequences=[0, 1, 2],
                      minimum_us=90, maximum_us=110)
        self.status([row(0, 0, 1), row(1, 500, 1)], p, "indeterminate")
        rows = [row(0, 0, 1), row(1, 500, 1), row(2, 600, 1, quality="decoded")]
        self.status(rows, p, "indeterminate")
        p["accepted_qualities"].append("decoded")
        self.status(rows, p, "contradicted")

    def test_event_windows_require_coverage_and_include_both_boundaries(self):
        p = predicate("event_window", channel="stimulus.phase", event="target", present=True,
            start_us=10, end_us=20, coverage_sequences=[0, 2])
        for time, uncertainty, expected in [(10, 0, "consistent"), (20, 0, "consistent"),
                (9, 0, "contradicted"), (21, 0, "contradicted"),
                (10, 1, "indeterminate"), (9, 1, "indeterminate"), (8, 1, "contradicted")]:
            with self.subTest(time=time, uncertainty=uncertainty):
                self.status([row(0, 0, "coverage.complete.start", "stimulus.phase"),
                    row(1, time, "target", "stimulus.phase"),
                    row(2, 30, "coverage.complete.end", "stimulus.phase")], p, expected, uncertainty)
        p["present"] = False
        self.status([row(0, 0, "coverage.complete.start", "stimulus.phase"),
                     row(2, 30, "coverage.complete.end", "stimulus.phase")], p, "consistent")
        self.status([row(0, 0, "start", "stimulus.phase")], p, "indeterminate")
        self.status([row(0, 11, "start", "stimulus.phase"), row(2, 30, "end", "stimulus.phase")], p, "indeterminate")

    def test_event_absence_requires_coverage_from_the_same_channel(self):
        p = predicate("event_window", channel="stimulus.phase", event="target", present=False,
            start_us=10, end_us=20, coverage_sequences=[0, 2])
        self.status([row(0, 0, 1), row(2, 30, 1)], p, "indeterminate")
        result = self.status([row(0, 0, "coverage.complete.start", "stimulus.phase"),
            row(2, 30, "coverage.complete.end", "stimulus.phase")], p, "consistent")
        self.assertIn("supplied channel log", " ".join(result.notes))

    def test_event_ordinary_bracketing_rows_never_establish_complete_coverage(self):
        rows = [row(0, 0, "ordinary-start", "stimulus.phase"),
                row(2, 30, "ordinary-end", "stimulus.phase")]
        for present in (True, False):
            p = predicate("event_window", channel="stimulus.phase", event="target", present=present,
                start_us=10, end_us=20, coverage_sequences=[0, 2])
            with self.subTest(present=present):
                self.status(rows, p, "indeterminate")
                self.status([rows[0], row(1, 15, "target", "stimulus.phase"), rows[1]], p, "indeterminate")

    def test_event_incomplete_reversed_nested_and_unaccepted_sentinels_are_indeterminate(self):
        p = predicate("event_window", channel="stimulus.phase", event="target", present=False,
            start_us=10, end_us=20, coverage_sequences=[0, 2])
        start = row(0, 0, "coverage.complete.start", "stimulus.phase")
        end = row(2, 30, "coverage.complete.end", "stimulus.phase")
        for rows in ([start, replace(end, value="ordinary-end")],
                     [replace(start, value="ordinary-start"), end],
                     [replace(start, value=end.value), replace(end, value=start.value)],
                     [start, replace(end, quality="decoded")],
                     [start, row(1, 15, "coverage.complete.start", "stimulus.phase"), end],
                     [start, row(1, 15, "coverage.complete.end", "stimulus.phase"), end]):
            with self.subTest(rows=rows):
                self.status(rows, p, "indeterminate")

    def test_event_completeness_sentinels_cannot_be_target_events(self):
        for event in ("coverage.complete.start", "coverage.complete.end"):
            p = predicate("event_window", channel="stimulus.phase", event=event, present=True,
                start_us=10, end_us=20, coverage_sequences=[0, 2])
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.load(p)

    def test_conjunctive_cadence_definitive_falsifier_wins_over_uncertainty(self):
        p = predicate("cadence_interval", channel="display.uniform_luma_ratio", sequences=[0, 1, 2],
                      minimum_us=90, maximum_us=110)
        for times, points, expected in [
                ([0, 200, 290], ["contradicted", "indeterminate"], "contradicted"),
                ([0, 90, 290], ["indeterminate", "contradicted"], "contradicted"),
                ([0, 100, 190], ["consistent", "indeterminate"], "indeterminate"),
                ([0, 100, 200], ["consistent", "consistent"], "consistent")]:
            with self.subTest(times=times):
                result = self.compare([row(i, time, 1) for i, time in enumerate(times)], p, uncertainty=1)
                self.assertEqual([point.status for point in result.alignments], points)
                self.assertEqual(result.results[0].status, expected)

    def phase_rows(self, before=1, after=1):
        return [row(0, 0, "before", "stimulus.phase"), row(1, 10, before),
                row(2, 20, "after", "stimulus.phase"), row(3, 30, after)]

    def test_phase_scalar_direction_deadband_and_value_uncertainty(self):
        p = predicate("phase_scalar", channel="display.uniform_luma_ratio", before_phase="before",
            after_phase="after", direction="increasing", tolerance=0.125, value_uncertainty=0)
        for direction, after, uncertainty, expected in [
            ("increasing", 1.125, 0, "contradicted"), ("increasing", 1.25, 0, "consistent"),
            ("decreasing", 0.875, 0, "contradicted"), ("decreasing", 0.75, 0, "consistent"),
            ("unchanged", 1.125, 0, "consistent"), ("unchanged", 0.875, 0, "consistent"),
            ("unchanged", 1.25, 0, "contradicted"), ("increasing", 1.25, 0.0625, "indeterminate"),
            ("unchanged", 1, 0.0625, "consistent"), ("unchanged", 1.125, 0.0625, "indeterminate")]:
            with self.subTest(direction=direction, after=after, uncertainty=uncertainty):
                self.status(self.phase_rows(after=after), {**p, "direction": direction,
                    "value_uncertainty": uncertainty}, expected)

    def test_phase_missing_ambiguous_and_uncertain_assignment(self):
        p = predicate("phase_scalar", channel="display.uniform_luma_ratio", before_phase="before",
            after_phase="after", direction="unchanged", tolerance=0, value_uncertainty=0)
        self.status(self.phase_rows()[:2], p, "indeterminate")
        self.status(self.phase_rows() + [row(4, 40, "before", "stimulus.phase"), row(5, 50, 1)], p, "indeterminate")
        rows = self.phase_rows()
        rows[1] = replace(rows[1], time_us=19)
        self.status(rows, p, "indeterminate", 1)

    def test_phase_scalar_reversed_marker_order_is_indeterminate(self):
        p = predicate("phase_scalar", channel="display.uniform_luma_ratio", before_phase="before",
            after_phase="after", direction="increasing", tolerance=0, value_uncertainty=0)
        for before, after in ((1, 2), (2, 1)):
            rows = [row(0, 0, "after", "stimulus.phase"), row(1, 10, after),
                    row(2, 20, "before", "stimulus.phase"), row(3, 30, before)]
            with self.subTest(before=before, after=after):
                self.status(rows, p, "indeterminate")

    def test_roi_control_delta_is_control_minus_roi_and_inclusive(self):
        p = predicate("roi_control_delta", roi_sequence=0, control_sequence=1,
            minimum_delta=0.25, value_uncertainty=0, maximum_skew_us=2)
        rows = [row(0, 0, 0.5, "display.roi_luma_ratio"),
                row(1, 0, 0.75, "display.control_luma_ratio")]
        self.status(rows, p, "consistent")
        self.status(rows, {**p, "minimum_delta": 0.5}, "contradicted")
        self.status(rows, {**p, "value_uncertainty": 0.125}, "indeterminate")
        self.status(rows, p, "consistent", 1)
        self.status([rows[0], replace(rows[1], time_us=1)], p, "indeterminate", 1)

    def test_strict_schema_unknown_fields_types_and_duplicate_ids(self):
        p = predicate("context", channel="msi.register.transaction")
        for fields in ({"schema_version": True}, {"schema_version": 2}, {"unexpected": 1}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.load(p, **fields)
        for patch in ({"extra": 1}, {"type": "eval"}, {"type": []}, {"trial": 1},
                {"accepted_qualities": []}, {"accepted_qualities": ["inferred"]},
                {"accepted_qualities": ["measured", "measured"]}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.load({**p, **patch})
        with self.assertRaises(ValueError):
            self.load(p, p)
        self.path.write_text('{"schema_version":1,"schema_version":1,"hypotheses":[]}')
        with self.assertRaises(ValueError):
            load_hypotheses(self.path)

    def orbit(self, sequences, **fields):
        return predicate("orbit_sequence", sequences=sequences, orbit="normal", version=20,
                         coordinates="absolute", **fields)

    def positions(self, *points):
        return [row(i, i*10, {"x": x, "y": y}, "display.offset_px") for i, (x, y) in enumerate(points)]

    def test_orbit_zero_one_multiple_and_complete_survivor_sets(self):
        table = {"orbit_table": ((0, 0), (1, 0), (0, 0), (0, 1))}
        for positions, survivors, expected in [([(9, 9)], (), "contradicted"),
                ([(1, 0)], (1,), "consistent"), ([(0, 0)], (0, 2), "indeterminate")]:
            with self.subTest(positions=positions):
                result = self.compare(self.positions(*positions), self.orbit([0]), orbit_tables=table)
                self.assertEqual(result.results[0].surviving_indices, survivors)
                self.assertEqual(result.results[0].status, expected)

    def test_orbit_alignment_marks_only_the_later_prefix_eliminating_all_candidates(self):
        table = {"orbit_table": ((0, 0), (1, 0), (0, 0), (0, 1))}
        for coordinates in ("absolute", "relative"):
            with self.subTest(coordinates=coordinates):
                p = {**self.orbit([0, 1, 2, 3]), "coordinates": coordinates}
                result = self.compare(self.positions((0, 0), (1, 0), (9, 9), (0, 1)),
                    p, orbit_tables=table)
                self.assertEqual([a.status for a in result.alignments],
                    ["indeterminate", "consistent", "contradicted", "contradicted"])
                first = next(a for a in result.alignments if a.status == "contradicted")
                self.assertEqual(first.sequences, (2,))
                self.assertEqual(result.results[0].status, "contradicted")
                self.assertEqual(result.results[0].surviving_indices, ())

    def test_orbit_final_unique_survivor_is_not_overridden_by_ambiguous_early_prefix(self):
        table = {"orbit_table": ((0, 0), (1, 0), (0, 0), (0, 1))}
        for coordinates in ("absolute", "relative"):
            with self.subTest(coordinates=coordinates):
                p = {**self.orbit([0, 1]), "coordinates": coordinates}
                result = self.compare(self.positions((0, 0), (1, 0)), p, orbit_tables=table)
                self.assertEqual([a.status for a in result.alignments], ["indeterminate", "consistent"])
                self.assertEqual(result.results[0].status, "consistent")
                self.assertEqual(result.results[0].surviving_indices, (0,))

    def test_orbit_expected_coordinates_are_disclosed_only_at_first_eliminating_prefix(self):
        table = {"orbit_table": ((0, 0), (1, 0), (0, 0), (0, 1))}
        result = self.compare(self.positions((0, 0), (1, 0), (9, 9), (0, 0)),
                              self.orbit([0, 1, 2, 3]), orbit_tables=table)
        expected = [json.loads(row.expected) for row in result.alignments]
        self.assertEqual([point.get("coordinate_options") for point in expected],
                         [None, None, [[0, 0]], None])
        self.assertEqual([point["candidate_count_before"] for point in expected], [4, 2, 1, 0])
        self.assertEqual([point["candidate_count_after"] for point in expected], [2, 1, 0, 0])
        self.assertEqual(expected[2]["candidate_starts_before"], [0])
        self.assertEqual(expected[2]["candidate_starts_after"], [])
        self.assertEqual(expected[2]["table"], "orbit_table")
        self.assertEqual(expected[2]["version"], 20)
        self.assertEqual(expected[2]["coordinates"], "absolute")
        self.assertEqual(expected[2]["position_in_sequence"], 2)
        self.assertEqual(result.alignments[2].observed, "(9, 9)")
        self.assertEqual(result.alignments[2].status, "contradicted")
        self.assertEqual(result.results[0].surviving_indices, ())

    def test_relative_alignment_observed_and_expected_use_the_same_displacement_coordinates(self):
        table = {"orbit_table": ((0, 0), (1, 0), (2, 0), (2, 1))}
        p = {**self.orbit([0, 1, 2]), "coordinates": "relative"}
        result = self.compare(self.positions((8, 9), (9, 9), (10, 9)), p, orbit_tables=table)
        expected = [json.loads(row.expected) for row in result.alignments]
        self.assertEqual([row.observed for row in result.alignments], ["(0, 0)", "(1, 0)", "(2, 0)"])
        self.assertTrue(all("coordinate_options" not in point for point in expected))
        self.assertEqual([point["candidate_count_after"] for point in expected], [4, 2, 1])
        self.assertTrue(all(point["coordinates"] == "relative" for point in expected))
        self.assertEqual(result.results[0].surviving_indices, (0,))

    def test_large_orbit_candidate_sets_are_counted_without_dumping_start_coordinate_mappings(self):
        table = {"orbit_table": ((0, 0),) * 12}
        result = self.compare(self.positions((0, 0)), self.orbit([0]), orbit_tables=table)
        expected = json.loads(result.alignments[0].expected)
        self.assertNotIn("coordinate_options", expected)
        self.assertEqual(expected["candidate_count_before"], 12)
        self.assertEqual(expected["candidate_count_after"], 12)
        self.assertNotIn("candidate_starts_before", expected)
        self.assertNotIn("candidate_starts_after", expected)
        self.assertEqual(result.results[0].surviving_indices, tuple(range(12)))

    def test_successful_full_table_length_sequence_reveals_no_expected_source_coordinates(self):
        table = {"orbit_table": ((0, 0), (1, 0), (0, 0), (0, 1))}
        for coordinates in ("absolute", "relative"):
            with self.subTest(coordinates=coordinates):
                p = {**self.orbit([0, 1, 2, 3]), "coordinates": coordinates}
                result = self.compare(self.positions((0, 0), (1, 0), (0, 0), (0, 1)),
                                      p, orbit_tables=table)
                self.assertEqual(result.results[0].status, "consistent")
                self.assertEqual(result.results[0].surviving_indices, (0,))
                expected = [json.loads(row.expected) for row in result.alignments]
                self.assertTrue(all("coordinate_options" not in point for point in expected))
                self.assertEqual([point["candidate_count_after"] for point in expected],
                                 [2, 1, 1, 1] if coordinates == "absolute" else [4, 1, 1, 1])

    def test_relative_mismatch_exposes_only_eliminating_displacement_options(self):
        table = {"orbit_table": ((0, 0), (1, 0), (2, 0), (2, 1))}
        p = {**self.orbit([0, 1, 2, 3]), "coordinates": "relative"}
        result = self.compare(self.positions((8, 9), (9, 9), (17, 18), (8, 9)), p,
                              orbit_tables=table)
        expected = [json.loads(row.expected) for row in result.alignments]
        self.assertEqual([point.get("coordinate_options") for point in expected],
                         [None, None, [[1, 1], [2, 0]], None])
        self.assertEqual(result.alignments[2].observed, "(9, 9)")

    def test_many_eliminating_predicates_share_one_source_mapping_disclosure_budget(self):
        table = ((0, 0), (1, 2), (2, 4), (3, 6), (4, 8), (5, 10), (6, 12), (7, 14))
        rows = self.positions(*table, (99, 99))
        predicates = [{**self.orbit(list(range(8))), "id": "successful"}]
        # Without a global budget, these reveal every successive table entry.
        predicates.extend({**self.orbit([i, 8]), "id": f"probe-{i}"} for i in range(8))
        predicates.append({**self.orbit([0, 8]), "id": "rotation-probe", "orbit": "rotation"})
        hypotheses = self.load(*predicates)
        tables = {"orbit_table": table, "orbit_table_32x16": table}
        result = compare_capture(capture(rows), hypotheses, orbit_tables=tables)
        disclosed = [(r.hypothesis_id, r.sequences, json.loads(r.expected)["coordinate_options"])
                     for r in result.alignments if "coordinate_options" in json.loads(r.expected)]
        self.assertEqual(disclosed, [("probe-0", (8,), [[1, 2]])])
        self.assertEqual(result.results[0].status, "consistent")
        self.assertTrue(all(r.status == "contradicted" for r in result.results[1:]))
        later = [r for r in result.alignments if r.hypothesis_id == "probe-7"]
        self.assertEqual([json.loads(r.expected)["candidate_count_after"] for r in later], [1, 0])
        self.assertEqual(compare_capture(capture(rows), hypotheses, orbit_tables=tables), result)

    def test_unaccepted_orbit_evidence_does_not_consume_disclosure_budget(self):
        rows = self.positions((0, 0), (99, 99))
        p = self.orbit([0, 1])
        hypotheses = self.load({**p, "id": "unaccepted", "accepted_qualities": ["decoded"]},
                               {**p, "id": "accepted"})
        result = compare_capture(capture(rows), hypotheses,
                                 orbit_tables={"orbit_table": ((0, 0), (1, 2))})
        self.assertEqual(result.results[0].status, "indeterminate")
        disclosed = [r for r in result.alignments if "coordinate_options" in r.expected]
        self.assertEqual([r.hypothesis_id for r in disclosed], ["accepted"])
        self.assertEqual(json.loads(disclosed[0].expected)["coordinate_options"], [[1, 2]])

    def test_version_bound_tables_skip_other_release_without_spending_disclosure(self):
        rows = self.positions((0, 0), (99, 99))
        for version in (
            18,
            20,
            22,
            AlgorithmVersion.V18,
            AlgorithmVersion.V20,
            AlgorithmVersion.V22,
        ):
            with self.subTest(version=version):
                other = 20 if version == 18 else 18
                p = self.orbit([0, 1])
                hypotheses = self.load({**p, "id": "wrong-release", "version": other},
                                       {**p, "id": "bound-release", "version": int(version)},
                                       {**p, "id": "later-bound", "version": int(version)})
                result = compare_capture(capture(rows), hypotheses,
                    orbit_tables={"orbit_table": ((0, 0), (1, 2))}, orbit_table_version=version)
                self.assertEqual(result.results[0].status, "indeterminate")
                self.assertEqual(result.results[0].category, "unavailable")
                self.assertIn(f"v{other}", result.results[0].reason)
                self.assertIn(f"v{int(version)}", result.results[0].reason)
                self.assertEqual(result.results[0].surviving_indices, ())
                disclosed = [r for r in result.alignments if "coordinate_options" in r.expected]
                self.assertEqual([r.hypothesis_id for r in disclosed], ["bound-release"])
                self.assertEqual(json.loads(disclosed[0].expected)["coordinate_options"], [[1, 2]])
                self.assertTrue(all(r.status == "contradicted" for r in result.results[1:]))

    def test_source_version_binding_is_strictly_validated_before_evidence(self):
        hypotheses = self.load(self.orbit([0]))
        tables = {"orbit_table": ((0, 0),)}
        for version in (True, False, "18", 18.0, 19, -1, [], {}):
            with self.subTest(version=version), self.assertRaises(ValueError):
                compare_capture(None, hypotheses, orbit_tables=tables, orbit_table_version=version)
        with self.assertRaisesRegex(ValueError, "orbit_tables"):
            compare_capture(None, hypotheses, orbit_table_version=18)

    def test_orbit_wraparound_and_only_manifest_calibration(self):
        table = {"orbit_table": ((0, 0), (1, 0), (0, 1))}
        rows = self.positions((0, 1), (0, 0), (1, 0), (0, 1))
        result = self.compare(rows, self.orbit([0, 1, 2, 3]), orbit_tables=table)
        self.assertEqual(result.results[0].surviving_indices, (2,))
        rows = self.positions((0, -1))
        hypothesis = self.load(self.orbit([0]))
        calibrated = compare_capture(capture(rows, swap_axes=True, x_sign=-1), hypothesis, orbit_tables=table)
        self.assertEqual(calibrated.results[0].surviving_indices, (1,))
        unchanged = compare_capture(capture(rows), hypothesis, orbit_tables=table)
        self.assertEqual(unchanged.results[0].status, "contradicted")

    def test_relative_positions_do_not_search_translation_or_skip_candidates(self):
        table = {"orbit_table": ((0, 0), (1, 0), (2, 0), (2, 1))}
        p = {**self.orbit([0, 1]), "coordinates": "relative"}
        result = self.compare(self.positions((8, 9), (9, 9)), p, orbit_tables=table)
        self.assertEqual(result.results[0].surviving_indices, (0, 1))
        self.assertEqual(result.results[0].status, "indeterminate")

    def test_normal_orbit_v18_v20_is_explicitly_non_discriminating(self):
        p = self.orbit([0, 1])
        hypotheses = self.load({**p, "id": "v18", "version": 18}, {**p, "id": "v20"})
        result = compare_capture(capture(self.positions((0, 0), (1, 0))), hypotheses,
            orbit_tables={"orbit_table": ((0, 0), (1, 0), (0, 1))})
        self.assertEqual([r.surviving_indices for r in result.results], [(0,), (0,)])
        for item in result.results:
            self.assertIn("non-discriminating", " ".join(item.notes))
            self.assertIn("v18", " ".join(item.notes))
            self.assertIn("v20", " ".join(item.notes))

    def test_version_22_normal_and_rotation_orbits_are_accepted(self):
        normal = self.load({**self.orbit([0]), "version": 22})
        rotation = self.load(
            {**self.orbit([0]), "version": 22, "orbit": "rotation"}
        )
        tables = {"orbit_table": ((0, 0),), "orbit_table_32x16": ((0, 0),)}
        self.assertEqual(
            compare_capture(
                capture(self.positions((0, 0))),
                normal,
                orbit_tables=tables,
                orbit_table_version=22,
            ).results[0].status,
            "consistent",
        )
        self.assertEqual(
            compare_capture(
                capture(self.positions((0, 0))),
                rotation,
                orbit_tables=tables,
                orbit_table_version=AlgorithmVersion.V22,
            ).results[0].status,
            "consistent",
        )

    def test_orbit_missing_quality_missing_table_and_rotation_version(self):
        rows = self.positions((0, 0))
        p = self.orbit([0, 1])
        self.status(rows, p, "indeterminate")
        result = self.compare([replace(rows[0], quality="derived")], self.orbit([0]),
            orbit_tables={"orbit_table": ((0, 0), (1, 0))})
        self.assertEqual(result.results[0].status, "indeterminate")
        self.assertEqual(result.results[0].surviving_indices, ())
        p = {**self.orbit([0]), "orbit": "rotation"}
        result = self.compare(rows, p, orbit_tables={"orbit_table_32x16": ((0, 0), (1, 0))})
        self.assertEqual(result.results[0].status, "consistent")
        with self.assertRaises(ValueError):
            self.load({**p, "version": 18})

    def test_raw_register_and_off_el_predicates_are_context_only(self):
        for channel in ("msi.register.transaction", "panel.off_sensing_event"):
            for p in (predicate("context", channel=channel),
                predicate("cadence_interval", channel=channel, sequences=[0, 1], minimum_us=0, maximum_us=2),
                predicate("event_window", channel=channel, event="done", present=True,
                    start_us=0, end_us=1, coverage_sequences=[0, 1]),
                predicate("phase_scalar", channel=channel, before_phase="before", after_phase="after",
                    direction="increasing", tolerance=0, value_uncertainty=0)):
                with self.subTest(channel=channel, kind=p["type"]):
                    item = self.status([row(0, 0, "done", channel)], p, "indeterminate")
                    self.assertEqual(item.category, "context-only")

    def test_numeric_register_joins_expressions_model_fields_and_unknown_selectors_rejected(self):
        p = predicate("phase_scalar", channel="msi.register.transaction", before_phase="before",
            after_phase="after", direction="unchanged", tolerance=0, value_uncertainty=0)
        for patch in ({"pontusm_field": "app_duty"}, {"field": "data.0"},
                      {"expression": "register == app_duty"}, {"scenario": "arbitrary"}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.load({**p, **patch})
        for patch in ({"version": True}, {"version": "20"}, {"orbit": "best_fit"},
                      {"coordinates": "infer"}, {"sequences": [0, True]}, {"sequences": [1, 0]},
                      {"x_sign": -1}, {"offset": [1, 2]}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.load({**self.orbit([0]), **patch})

    def test_decimal_boundaries_are_exact(self):
        p = predicate("roi_control_delta", roi_sequence=0, control_sequence=1,
            minimum_delta=0.2, value_uncertainty=0, maximum_skew_us=0)
        self.status([row(0, 0, 0.1, "display.roi_luma_ratio"),
                     row(1, 0, 0.3, "display.control_luma_ratio")], p, "consistent")

    def test_large_finite_values_do_not_overflow(self):
        huge = 10**400
        p = predicate("phase_scalar", channel="display.uniform_luma_ratio", before_phase="before",
            after_phase="after", direction="unchanged", tolerance=huge, value_uncertainty=0)
        self.status(self.phase_rows(before=huge, after=huge), p, "consistent")

    def test_all_predicate_fields_required_and_numeric_types_strict(self):
        examples = [self.orbit([0]), predicate("cadence_interval", channel="display.offset_px",
            sequences=[0, 1], minimum_us=0, maximum_us=10),
            predicate("event_window", channel="stimulus.phase", event="x", present=False,
                start_us=0, end_us=10, coverage_sequences=[0, 1]),
            predicate("phase_scalar", channel="display.uniform_luma_ratio", before_phase="a",
                after_phase="b", direction="unchanged", tolerance=0, value_uncertainty=0),
            predicate("roi_control_delta", roi_sequence=0, control_sequence=1,
                minimum_delta=0, value_uncertainty=0, maximum_skew_us=0),
            predicate("context", channel="panel.off_sensing_event")]
        numeric = {"minimum_us", "maximum_us", "start_us", "end_us", "tolerance",
            "value_uncertainty", "minimum_delta", "roi_sequence", "control_sequence", "maximum_skew_us", "version"}
        for example in examples:
            for key in example:
                invalid = dict(example)
                del invalid[key]
                with self.subTest(kind=example["type"], missing=key), self.assertRaises(ValueError):
                    self.load(invalid)
                if key in numeric:
                    for value in (True, -1, "0", [], float("nan"), float("inf")):
                        with self.subTest(kind=example["type"], key=key, value=value), self.assertRaises(ValueError):
                            self.load({**example, key: value})

    def test_invalid_later_hypothesis_rejected_before_capture_evaluation(self):
        hypotheses = self.load(self.orbit([0]))
        invalid = replace(hypotheses, hypotheses=(*hypotheses.hypotheses,
            {"id": "bad", "type": "expression", "value": "anything"}))
        with self.assertRaises(ValueError):
            compare_capture(None, invalid)

    def test_valid_replaced_hypotheses_cannot_retain_stale_source_hash(self):
        hypotheses = self.load(self.orbit([0]))
        for patch in ({"id": "replaced-id"}, {"sequences": (0, 1)}, {"version": 18}):
            stale = replace(hypotheses, hypotheses=({**hypotheses.hypotheses[0], **patch},))
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                compare_capture(capture(self.positions((0, 0), (1, 0))), stale)

    def test_hypothesis_notes_and_digest_are_revalidated_and_bound(self):
        hypotheses = self.load(self.orbit([0]), notes="original")
        for patch in ({"notes": "changed"}, {"notes": None}, {"notes": []},
                      {"sha256": "0"*64}, {"sha256": True}, {"sha256": "A"*64}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                compare_capture(capture(self.positions((0, 0))), replace(hypotheses, **patch))

    def test_hypothesis_integrity_preserves_exact_source_bytes_including_whitespace(self):
        hypotheses = self.load(self.orbit([0]))
        original = self.path.read_bytes()
        pretty = json.dumps(json.loads(original), indent=2).encode() + b"\n"
        self.path.write_bytes(pretty)
        formatted = load_hypotheses(self.path)
        self.assertEqual(formatted.source_bytes, pretty)
        self.assertEqual(formatted.sha256, hashlib.sha256(pretty).hexdigest())
        self.assertNotEqual(formatted.sha256, hypotheses.sha256)
        result = compare_capture(capture(self.positions((0, 0))), formatted)
        self.assertEqual(result.hypotheses_sha256, hashlib.sha256(pretty).hexdigest())
        for patch in ({"source_bytes": original}, {"source_bytes": bytearray(pretty)},
                      {"source_bytes": b""}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                compare_capture(capture(self.positions((0, 0))), replace(formatted, **patch))

    def test_trial_local_selectors_and_phase_means_use_all_samples(self):
        p = predicate("phase_scalar", channel="display.uniform_luma_ratio", before_phase="before",
            after_phase="after", direction="unchanged", tolerance=0, value_uncertainty=0)
        rows = [row(0, 0, "before", "stimulus.phase"), row(1, 10, 0), row(2, 15, 2),
            row(3, 20, "after", "stimulus.phase"), row(4, 30, 1),
            replace(row(4, 30, 100), trial="other")]
        self.status(rows, p, "consistent")
        self.status([r for r in rows if r.trial == "other"], p, "indeterminate")

    def test_malformed_orbit_data_fails_validation_before_evidence(self):
        hypotheses = self.load(self.orbit([0]))
        for tables in ({"orbit_table": ()}, {"orbit_table": ((True, 1),)},
                       {"orbit_table": [[0, 1]]}, {"arbitrary": ((0, 1),)}):
            with self.subTest(tables=tables), self.assertRaises(ValueError):
                compare_capture(None, hypotheses, orbit_tables=tables)

    def test_synthetic_template_loads_and_emits_only_predicate_results(self):
        root = Path(__file__).resolve().parents[1] / "capture-templates/pixel-shift"
        hypotheses = load_hypotheses(root / "hypotheses.json")
        result = compare_capture(load_capture(root / "capture.json"), hypotheses)
        self.assertIn("synthetic", hypotheses.notes)
        self.assertEqual(len(result.results), 3)
        self.assertEqual([r.status for r in result.results], ["indeterminate", "indeterminate", "consistent"])
        self.assertEqual(len(result.alignments), 34)
        self.assertTrue(all(a.hypothesis_id in {r.id for r in result.results} for a in result.alignments))


if __name__ == "__main__":
    unittest.main()
