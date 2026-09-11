"""Strict, offline MSI timeline parsing and direct-model equivalence."""

import copy
import dataclasses
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pontusm_sim.msi import MSIPanelCareModel
from pontusm_sim.msi_scenario import load_msi_scenario, run_msi_scenario


def scenario_payload(*actions):
    return {
        "schema_version": 1,
        "name": "synthetic-off",
        "firmware": "041",
        "initial": {
            "settings": {
                "pixel_shift_enabled": True, "pixel_shift_speed": 2,
                "static_enabled": True, "static_start_seconds": 50,
                "static_required_seconds": 240, "static_level": 7,
                "boundary_level": 3, "taskbar_level": 2, "logo_level": 1,
            },
            "inputs": {"temperature_raw": 735, "done_pin": True,
                       "panel_enabled": True, "vrr_active": False},
        },
        "actions": list(actions) or [
            {"at_ms": 0, "action": "start-off", "destination": "power-save"},
            {"at_ms": 600_000, "action": "advance"},
        ],
    }


class MSIScenarioTests(unittest.TestCase):
    def load(self, payload):
        with TemporaryDirectory() as directory:
            path = Path(directory, "scenario.json")
            path.write_text(json.dumps(payload), encoding="utf-8")
            return load_msi_scenario(path)

    def test_run_preserves_exact_direct_model_events_and_snapshot(self):
        scenario = self.load(scenario_payload())
        result = run_msi_scenario(scenario)
        direct = MSIPanelCareModel()
        direct.set_inputs(temperature_raw=735, done_pin=True, panel_enabled=True)
        expected = direct.start_off(destination="power-save")
        expected += direct.advance(milliseconds=600_000)
        self.assertEqual(result.events, expected)
        self.assertEqual(result.final_state, direct.snapshot())
        self.assertEqual(result.final_state.off_run_count, 1)
        self.assertIsInstance(result.events, tuple)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            scenario.name = "changed"

    def test_hash_authenticates_exact_input_bytes(self):
        with TemporaryDirectory() as directory:
            path = Path(directory, "scenario.json")
            raw = (json.dumps(scenario_payload(), indent=2) + "\n").encode()
            path.write_bytes(raw)
            scenario = load_msi_scenario(path)
            self.assertEqual(scenario.scenario_sha256, hashlib.sha256(raw).hexdigest())

    def test_unknown_fields_rejected_at_every_schema_level(self):
        for level in ("root", "initial", "settings", "inputs", "action"):
            payload = scenario_payload()
            target = {"root": payload, "initial": payload["initial"],
                      "settings": payload["initial"]["settings"],
                      "inputs": payload["initial"]["inputs"],
                      "action": payload["actions"][0]}[level]
            target["unexpected"] = True
            with self.subTest(level=level), self.assertRaises(ValueError):
                self.load(payload)

    def test_required_fields_types_and_ranges_are_strict(self):
        original = scenario_payload()
        invalids = []
        for key, value in (("schema_version", True), ("schema_version", 2),
                           ("name", ""), ("firmware", "035"),
                           ("initial", []), ("actions", {}), ("actions", [])):
            payload = copy.deepcopy(original)
            payload[key] = value
            invalids.append(payload)
        for field, value in (("pixel_shift_speed", 3), ("static_level", 0),
                             ("boundary_level", 4)):
            payload = copy.deepcopy(original)
            payload["initial"]["settings"][field] = value
            invalids.append(payload)
        for field, value in (("temperature_raw", 65536), ("done_pin", 1),
                             ("panel_enabled", None), ("vrr_active", 0)):
            payload = copy.deepcopy(original)
            payload["initial"]["inputs"][field] = value
            invalids.append(payload)
        for key in original:
            payload = copy.deepcopy(original)
            del payload[key]
            invalids.append(payload)
        for payload in invalids:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.load(payload)

    def test_invalid_actions_are_rejected_before_execution(self):
        for action in (
            {"at_ms": -1, "action": "advance"},
            {"at_ms": True, "action": "advance"},
            {"at_ms": 1.5, "action": "advance"},
            {"at_ms": 0, "action": "start-el", "destination": "display"},
            {"at_ms": 0, "action": "start-off", "destination": []},
            {"at_ms": 0, "action": "start-off", "destination": "display",
             "factory_suppressed": 1},
            {"at_ms": 0, "action": "set-inputs", "inputs": {}},
            {"at_ms": 0, "action": "set-inputs", "inputs": {"temperature_raw": -1}},
            {"at_ms": 0, "action": "configure", "settings": {"logo_level": 4}},
            {"at_ms": 0, "action": "abort"},
        ):
            with self.subTest(action=action), self.assertRaises(ValueError):
                self.load(scenario_payload(action))

    def test_non_monotonic_actions_and_overlapping_runs_are_rejected(self):
        for actions in (
            [{"at_ms": 1, "action": "advance"}, {"at_ms": 0, "action": "advance"}],
            [{"at_ms": 0, "action": "start-off", "destination": "display"}] * 2,
        ):
            with self.subTest(actions=actions), self.assertRaises(ValueError):
                self.load(scenario_payload(*actions))

    def test_completed_or_aborted_run_cannot_be_mutated_or_restarted(self):
        mutations = [
            {"action": "set-inputs", "inputs": {"done_pin": False}},
            {"action": "configure", "settings": {"logo_level": 2}},
            {"action": "apply-settings"}, {"action": "abort"},
            {"action": "start-off", "destination": "display"},
        ]
        for mutation in mutations:
            for end in ({"at_ms": 600_000, "action": "advance"},
                        {"at_ms": 600, "action": "abort"}):
                with self.subTest(mutation=mutation, end=end), self.assertRaises(ValueError):
                    self.load(scenario_payload(
                        {"at_ms": 0, "action": "start-off", "destination": "display"},
                        end, {"at_ms": 600_001, **mutation}))

    def test_deadlines_precede_actions_and_equal_times_keep_list_order(self):
        payload = scenario_payload(
            {"at_ms": 0, "action": "start-off", "destination": "display"},
            {"at_ms": 181_000, "action": "set-inputs", "inputs": {"temperature_raw": 736}},
            {"at_ms": 181_000, "action": "set-inputs", "inputs": {"done_pin": False}},
            {"at_ms": 181_500, "action": "set-inputs", "inputs": {"done_pin": True}},
            {"at_ms": 190_000, "action": "advance"},
        )
        result = run_msi_scenario(self.load(payload))
        self.assertNotIn("temperature-refused", [e.kind for e in result.events])
        read = next(e for e in result.events if e.kind == "register-read")
        self.assertEqual(dict(read.detail)["payload"], (2, 223))
        done = next(e for e in result.events if e.kind == "done")
        self.assertEqual(done.time_ms, 181_500)
        self.assertEqual(result.final_state.off_run_count, 1)

    def test_vrr_reapply_and_configure_preserve_configured_levels(self):
        payload = scenario_payload(
            {"at_ms": 0, "action": "apply-settings"},
            {"at_ms": 1, "action": "set-inputs", "inputs": {"vrr_active": True}},
            {"at_ms": 1, "action": "apply-settings"},
            {"at_ms": 2, "action": "configure", "settings": {"logo_level": 3}},
            {"at_ms": 2, "action": "set-inputs", "inputs": {"vrr_active": False}},
            {"at_ms": 2, "action": "apply-settings"},
        )
        result = run_msi_scenario(self.load(payload))
        writes = [dict(e.detail)["write"] for e in result.events]
        self.assertEqual([w.payload for w in writes[3:6]], [(0, 3), (0, 2), (0, 1)])
        self.assertEqual([w.payload for w in writes[9:12]], [(0, 0)] * 3)
        self.assertEqual([w.payload for w in writes[15:18]], [(0, 3), (0, 2), (0, 3)])
        self.assertEqual(result.settings.logo_level, 3)
        self.assertFalse(result.vrr_active)

    def test_disabled_panel_does_not_emit_settings_transactions(self):
        payload = scenario_payload({"at_ms": 0, "action": "apply-settings"})
        payload["initial"]["inputs"]["panel_enabled"] = False
        self.assertEqual(run_msi_scenario(self.load(payload)).events, ())

    def test_latent_el_requires_explicit_analysis_entry(self):
        result = run_msi_scenario(self.load(scenario_payload(
            {"at_ms": 0, "action": "start-latent-el-for-analysis", "destination": "display"},
            {"at_ms": 3_100_000, "action": "advance"},
        )))
        self.assertTrue(result.final_state.unreachable_in_shipped_control_flow)
        self.assertEqual(result.final_state.el_run_count, 1)

    def test_duplicate_json_keys_are_rejected(self):
        with TemporaryDirectory() as directory:
            path = Path(directory, "scenario.json")
            path.write_text('{"schema_version":1,"schema_version":1}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                load_msi_scenario(path)


if __name__ == "__main__":
    unittest.main()
