"""Recovered scaler boundary behavior; no panel response is synthesized."""

import unittest

from pontusm_sim.msi import MSIPanelCareModel
from pontusm_sim.msi_settings import MSIScheduler


def kinds(events):
    return [event.kind for event in events]


def writes(events):
    return [dict(event.detail)["write"] for event in events
            if event.kind == "register-write"]


class MSIModelTests(unittest.TestCase):
    def test_temperature_gate_uses_truncated_sixteenth_degrees(self):
        for raw, refused in ((0, False), (720, False), (735, False),
                             (736, True), (65535, True)):
            with self.subTest(raw=raw):
                model = MSIPanelCareModel()
                model.set_inputs(temperature_raw=raw, done_pin=False, panel_enabled=True)
                model.start_off(destination="power-save")
                self.assertEqual(model.advance(milliseconds=180_999), ())
                events = model.advance(milliseconds=1)
                self.assertEqual("temperature-refused" in kinds(events), refused)
                self.assertEqual(kinds(events)[0], "register-read")
                self.assertEqual(dict(events[0].detail)["register"], 0x008)
                self.assertEqual([w.register for w in writes(events)], [] if refused else [0x0B2])
                if refused:
                    self.assertEqual(model.snapshot().destination, "power-off")

    def test_invalid_inputs_and_transitions_are_atomic(self):
        model = MSIPanelCareModel()
        for value in (-1, True, 1.5, "1000", None):
            before = model.snapshot()
            with self.assertRaises(ValueError):
                model.advance(milliseconds=value)
            self.assertEqual(before, model.snapshot())
        for value in (-1, 65536, True, 1.5, None):
            before = model.snapshot()
            with self.assertRaises(ValueError):
                model.set_inputs(temperature_raw=value, done_pin=True, panel_enabled=False)
            self.assertEqual(before, model.snapshot())
        for kwargs in ({"done_pin": 1}, {"panel_enabled": "yes"}):
            inputs = dict(temperature_raw=300, done_pin=False, panel_enabled=True)
            inputs.update(kwargs)
            before = model.snapshot()
            with self.assertRaises(ValueError):
                model.set_inputs(**inputs)
            self.assertEqual(before, model.snapshot())
        for destination in ("el", None, [], 42):
            before = model.snapshot()
            with self.assertRaises(ValueError):
                model.start_off(destination=destination)
            self.assertEqual(before, model.snapshot())
        with self.assertRaises(ValueError):
            model.abort()
        before = model.snapshot()
        with self.assertRaises(ValueError):
            model.start_off(destination="display", factory_suppressed=1)
        self.assertEqual(before, model.snapshot())
        model.start_off(destination="display")
        before = model.snapshot()
        with self.assertRaises(ValueError):
            model.start_off(destination="power-off")
        self.assertEqual(before, model.snapshot())

    def test_early_done_waits_for_trigger_and_strict_high_hold(self):
        model = MSIPanelCareModel()
        model.set_inputs(temperature_raw=400, done_pin=True, panel_enabled=True)
        model.start_off(destination="display")
        before = model.advance(milliseconds=181_499)
        self.assertNotIn("done", kinds(before))
        self.assertEqual([w.register for w in writes(before)], [0x0B2])
        trigger = model.advance(milliseconds=1)
        self.assertEqual(kinds(trigger), ["register-write", "done"])
        self.assertEqual(writes(trigger)[0].payload, (0, 1))
        self.assertEqual(model.advance(milliseconds=550), ())
        self.assertEqual(kinds(model.advance(milliseconds=1)), ["done-hold-finished"])
        self.assertEqual(model.snapshot().state, "off-led")

    def test_late_done_is_observed_without_fabricated_panel_state(self):
        model = MSIPanelCareModel()
        model.start_off(destination="power-save")
        model.advance(milliseconds=200_000)
        model.set_inputs(temperature_raw=900, done_pin=True, panel_enabled=True)
        events = model.advance(milliseconds=0)
        self.assertEqual(kinds(events), ["done"])
        self.assertEqual(events[0].time_ms, 200_000)
        self.assertEqual(model.snapshot().done_pin, True)
        # Cooling is not polled during sensing; a later hot input cannot veto it.
        self.assertNotIn("temperature-refused", kinds(events))
        model.set_inputs(temperature_raw=900, done_pin=False, panel_enabled=True)
        self.assertEqual(kinds(model.advance(milliseconds=0)), ["done-hold-finished"])

    def test_timeout_led_terminal_phase_and_final_wait(self):
        model = MSIPanelCareModel()
        model.start_off(destination="power-save")
        events = model.advance(milliseconds=557_499)
        self.assertNotIn("timeout", kinds(events))
        events = model.advance(milliseconds=1)
        self.assertEqual(kinds(events), ["timeout", "done-hold-finished"])
        self.assertEqual(model.snapshot().state, "off-led")
        phases = model.advance(milliseconds=4008)
        self.assertEqual([dict(e.detail)["phase"] for e in phases], list(range(1, 9)))
        self.assertEqual([dict(e.detail)["setter_called"] for e in phases],
                         [True] * 7 + [False])
        self.assertEqual([dict(e.detail)["rgb"] for e in phases],
                         [(0, 0, 0), (255, 16, 0), (0, 0, 0), (255, 16, 0),
                          (0, 0, 0), (255, 16, 0), (0, 0, 0), None])
        self.assertEqual(model.snapshot().state, "off-final-wait")
        self.assertEqual(model.advance(milliseconds=500), ())
        final = model.advance(milliseconds=1)
        self.assertEqual(kinds(final), ["counter-reset", "counter-reset",
                                        "run-count", "persistence", "destination"])
        self.assertEqual([dict(e.detail)["index"] for e in final[:2]], [0x0D, 0x0B])
        self.assertEqual(dict(final[-1].detail)["destination"], "power-save")
        self.assertEqual(model.snapshot().off_run_count, 1)
        self.assertEqual(model.snapshot().state, "idle")
        self.assertTrue(model.snapshot().panel_power_on)

    def test_factory_suppression_and_repeated_runs(self):
        for suppressed, count in ((False, 2), (True, 0)):
            model = MSIPanelCareModel()
            for _ in range(2):
                model.start_off(destination="power-off", factory_suppressed=suppressed)
                model.advance(milliseconds=600_000)
            self.assertEqual(model.snapshot().off_run_count, count)

    def test_abort_clears_only_off_trigger_and_does_not_commit(self):
        for enabled in (False, True):
            model = MSIPanelCareModel()
            model.set_inputs(temperature_raw=0, done_pin=False, panel_enabled=enabled)
            model.start_off(destination="display")
            model.advance(milliseconds=200_000)
            events = model.abort()
            self.assertEqual([(w.register, w.payload) for w in writes(events)],
                             [(0x0C0, (0, 0))] if enabled else [])
            self.assertNotIn("persistence", kinds(events))
            self.assertEqual(model.snapshot().state, "idle")
            self.assertEqual(model.snapshot().off_run_count, 0)
            self.assertEqual(model.advance(milliseconds=1_000_000), ())

    def test_disabled_enable_pin_uses_buffer_without_read_or_trigger(self):
        model = MSIPanelCareModel()
        model.set_inputs(temperature_raw=400, done_pin=False, panel_enabled=False)
        model.start_off(destination="power-save")
        events = model.advance(milliseconds=600_000)
        self.assertNotIn("register-read", kinds(events))
        self.assertEqual(writes(events), [])
        self.assertIn("timeout", kinds(events))

    def test_off_event_stream_is_chunk_invariant(self):
        for done in (False, True):
            one = MSIPanelCareModel()
            many = MSIPanelCareModel()
            for model in (one, many):
                model.set_inputs(temperature_raw=735, done_pin=done, panel_enabled=True)
                model.start_off(destination="display")
            expected = one.advance(milliseconds=600_000)
            actual = sum((many.advance(milliseconds=1000) for _ in range(600)), ())
            self.assertEqual(actual, expected)
            self.assertEqual(one.snapshot(), many.snapshot())
            self.assertTrue(all(e.evidence == "msi-source-translated" for e in actual))
            self.assertTrue(all(not w.verify_readback and w.attempts == 1
                                for w in writes(actual) if w.register == 0x0C0))

    def test_frame_rate_control_uses_verified_setter(self):
        model = MSIPanelCareModel()
        model.start_off(destination="display")
        write = writes(model.advance(milliseconds=181_000))[0]
        self.assertTrue(write.verify_readback)
        self.assertEqual(write.attempts, 10)

    def test_only_explicit_analysis_entry_reaches_el(self):
        scheduler = MSIScheduler(off_elapsed_hours=2000)
        for decision in (scheduler.power_off(destination="power-off"),
                         scheduler.request_manual_off(destination="display")):
            self.assertEqual(decision.run_kind, "off")
        ordinary = MSIPanelCareModel()
        ordinary.start_off(destination="display")
        self.assertFalse(ordinary.snapshot().unreachable_in_shipped_control_flow)
        self.assertNotIn(0x0C2, [w.register for w in writes(
            ordinary.advance(milliseconds=4_000_000))])
        latent = MSIPanelCareModel()
        events = latent.start_latent_el_for_analysis(destination="power-save")
        self.assertTrue(latent.snapshot().unreachable_in_shipped_control_flow)
        self.assertFalse(latent.snapshot().panel_power_on)
        self.assertTrue(dict(events[0].detail)["unreachable_in_shipped_control_flow"])
        for method in (latent.start_off, latent.start_latent_el_for_analysis):
            before = latent.snapshot()
            with self.assertRaises(ValueError):
                method(destination="display")
            self.assertEqual(before, latent.snapshot())

    def test_latent_el_timeout_sequence_and_persistence(self):
        model = MSIPanelCareModel()
        model.start_latent_el_for_analysis(destination="power-save")
        self.assertEqual(model.advance(milliseconds=900_999), ())
        self.assertEqual(kinds(model.advance(milliseconds=1)), ["panel-power"])
        events = model.advance(milliseconds=2_600_000)
        self.assertEqual([(e.time_ms, dict(e.detail)["write"].register)
                          for e in events if e.kind == "register-write"],
                         [(903_000, 0x0B2), (903_500, 0x0C0), (3_382_500, 0x0C2)])
        self.assertEqual([(e.time_ms, dict(e.detail)["register"])
                          for e in events if e.kind == "timeout"],
                         [(1_279_000, 0x0C0), (3_478_500, 0x0C2)])
        self.assertEqual([(e.time_ms, dict(e.detail)["on"])
                          for e in events if e.kind == "panel-power"][:2],
                         [(1_279_500, False), (3_380_500, True)])
        self.assertEqual([dict(e.detail)["phase"] for e in events
                          if e.kind == "led-phase"], list(range(1, 9)))
        self.assertEqual([dict(e.detail)["rgb"] for e in events
                          if e.kind == "led-phase"],
                         [(0, 0, 0), (255, 255, 255), (0, 0, 0), (255, 255, 255),
                          (0, 0, 0), (255, 255, 255), (0, 0, 0), None])
        self.assertEqual([dict(e.detail)["index"] for e in events
                          if e.kind == "counter-reset"], [0x0C, 0x0A, 0x0D, 0x0B])
        self.assertEqual(model.snapshot().el_run_count, 1)
        self.assertEqual(model.snapshot().off_run_count, 0)
        self.assertEqual(model.snapshot().state, "idle")
        self.assertFalse(model.snapshot().panel_power_on)
        self.assertEqual(kinds(events)[-2:], ["persistence", "destination"])

    def test_latent_done_and_chunks_preserve_full_event_sequence(self):
        one, many = MSIPanelCareModel(), MSIPanelCareModel()
        for model in (one, many):
            model.set_inputs(temperature_raw=735, done_pin=True, panel_enabled=True)
            model.start_latent_el_for_analysis(destination="display")
        expected = one.advance(milliseconds=3_100_000)
        actual = sum((many.advance(milliseconds=1000) for _ in range(3100)), ())
        self.assertEqual(actual, expected)
        self.assertEqual(one.snapshot(), many.snapshot())
        self.assertEqual([(e.time_ms, dict(e.detail)["register"])
                          for e in actual if e.kind == "done"],
                         [(903_500, 0x0C0), (3_007_000, 0x0C2)])
        self.assertNotIn("timeout", kinds(actual))
        self.assertEqual(one.snapshot().el_run_count, 1)

    def test_latent_temperature_gates_have_distinct_destination_semantics(self):
        first = MSIPanelCareModel()
        first.set_inputs(temperature_raw=736, done_pin=True, panel_enabled=True)
        first.start_latent_el_for_analysis(destination="display")
        events = first.advance(milliseconds=1_000_000)
        self.assertEqual(writes(events), [])
        self.assertIn("temperature-refused", kinds(events))
        self.assertEqual(first.snapshot().destination, "power-off")
        self.assertEqual(kinds(events).count("register-read"), 2)
        second = MSIPanelCareModel()
        second.set_inputs(temperature_raw=735, done_pin=True, panel_enabled=True)
        second.start_latent_el_for_analysis(destination="display")
        second.advance(milliseconds=3_005_000)
        second.set_inputs(temperature_raw=736, done_pin=True, panel_enabled=True)
        events = second.advance(milliseconds=10_000)
        self.assertEqual(writes(events), [])
        self.assertIn("temperature-refused", kinds(events))
        self.assertEqual(second.snapshot().destination, "display")


if __name__ == "__main__":
    unittest.main()
