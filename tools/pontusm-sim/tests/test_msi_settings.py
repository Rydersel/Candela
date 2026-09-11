import dataclasses
import unittest

from pontusm_sim.msi_settings import (
    MSIOLEDSettings,
    MSIScheduler,
    display_up_writes,
)


def configured_settings(**changes):
    values = {
        "pixel_shift_enabled": True,
        "pixel_shift_speed": 2,
        "static_enabled": True,
        "static_start_seconds": 50,
        "static_required_seconds": 240,
        "static_level": 7,
        "boundary_level": 3,
        "taskbar_level": 2,
        "logo_level": 1,
    }
    values.update(changes)
    return MSIOLEDSettings(**values)


class MSIOLEDSettingsTests(unittest.TestCase):
    def test_display_up_burst_has_recovered_order_and_payloads(self):
        writes = display_up_writes(configured_settings(), vrr_active=False)

        self.assertEqual(
            [write.register for write in writes],
            [0x070, 0x072, 0x060, 0x1B4, 0x1B6, 0x1B2],
        )
        self.assertEqual(writes[0].payload, (0, 1))
        self.assertEqual(writes[1].payload, (0, 2))
        self.assertEqual(writes[2].payload, (0x10, 7))
        self.assertEqual(writes[3].payload, (0, 3))
        self.assertEqual(writes[4].payload, (0, 2))
        self.assertEqual(writes[5].payload, (0, 1))

    def test_static_screen_selectors_use_the_recovered_two_byte_packing(self):
        expected_payloads = {
            (50, 120): (0x00, 4),
            (50, 240): (0x10, 4),
            (100, 120): (0x01, 4),
            (100, 240): (0x11, 4),
        }

        for (start, required), payload in expected_payloads.items():
            with self.subTest(start=start, required=required):
                writes = display_up_writes(
                    configured_settings(
                        static_start_seconds=start,
                        static_required_seconds=required,
                        static_level=4,
                    ),
                    vrr_active=False,
                )
                self.assertEqual(writes[2].payload, payload)

    def test_disabled_static_screen_detection_writes_zero_payload(self):
        writes = display_up_writes(
            configured_settings(static_enabled=False), vrr_active=False
        )

        self.assertEqual(writes[2].payload, (0, 0))

    def test_vrr_zeroes_effective_regional_payloads_without_changing_settings(self):
        settings = configured_settings()
        writes = display_up_writes(settings, vrr_active=True)

        self.assertEqual([write.payload for write in writes[3:]], [(0, 0)] * 3)
        self.assertEqual(settings.boundary_level, 3)
        self.assertEqual(settings.taskbar_level, 2)
        self.assertEqual(settings.logo_level, 1)

    def test_every_display_up_write_carries_the_readback_retry_contract(self):
        writes = display_up_writes(configured_settings(), vrr_active=False)

        self.assertTrue(all(write.verify_readback for write in writes))
        self.assertTrue(all(write.attempts == 10 for write in writes))
        self.assertTrue(all(write.evidence == "msi-source-translated" for write in writes))

    def test_settings_writes_and_returned_burst_are_immutable(self):
        settings = configured_settings()
        writes = display_up_writes(settings, vrr_active=False)

        self.assertIsInstance(writes, tuple)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            settings.static_level = 1
        with self.assertRaises(dataclasses.FrozenInstanceError):
            writes[0].attempts = 1
        with self.assertRaises(TypeError):
            writes[0].payload[0] = 1

    def test_settings_reject_out_of_range_and_non_boolean_values(self):
        invalid_cases = {
            "pixel_shift_enabled": 1,
            "pixel_shift_speed": 3,
            "static_enabled": 0,
            "static_start_seconds": 60,
            "static_required_seconds": 180,
            "static_level": 0,
            "boundary_level": 4,
            "taskbar_level": -1,
            "logo_level": 4,
        }

        for field, invalid_value in invalid_cases.items():
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    display_up_writes(
                        configured_settings(**{field: invalid_value}), vrr_active=False
                    )

        with self.assertRaises(ValueError):
            display_up_writes(configured_settings(), vrr_active=1)


class MSISchedulerTests(unittest.TestCase):
    def test_automatic_off_is_ineligible_before_four_accumulated_hours(self):
        scheduler = MSIScheduler()
        scheduler.accumulate_minutes(239)

        decision = scheduler.power_off(destination="power-save")

        self.assertFalse(decision.start_off)
        self.assertFalse(decision.eligible)
        self.assertIsNone(decision.request_kind)
        self.assertEqual((decision.off_elapsed_hours, decision.off_elapsed_minutes), (3, 59))

    def test_automatic_off_is_eligible_at_four_accumulated_hours(self):
        scheduler = MSIScheduler()
        scheduler.accumulate_minutes(240)

        decision = scheduler.power_off(destination="power-off")

        self.assertTrue(decision.start_off)
        self.assertTrue(decision.eligible)
        self.assertEqual(decision.request_kind, "automatic")
        self.assertEqual(decision.trigger, "power-off")
        self.assertEqual(decision.destination, "power-off")

    def test_fake_sleep_starts_an_eligible_off_run_only_at_ten_minutes(self):
        scheduler = MSIScheduler()
        scheduler.accumulate_minutes(240)
        scheduler.begin_fake_sleep(destination="power-save")

        before_boundary = scheduler.advance_fake_sleep(9)
        at_boundary = scheduler.advance_fake_sleep(1)

        self.assertFalse(before_boundary.start_off)
        self.assertTrue(at_boundary.start_off)
        self.assertEqual(at_boundary.request_kind, "automatic")
        self.assertEqual(at_boundary.trigger, "fake-sleep")
        self.assertEqual(at_boundary.fake_sleep_minutes, 10)

    def test_fake_sleep_advance_starting_before_ten_minutes_can_cross_the_boundary(self):
        scheduler = MSIScheduler()
        scheduler.accumulate_minutes(240)
        scheduler.begin_fake_sleep(destination="power-save")
        scheduler.advance_fake_sleep(9)

        decision = scheduler.advance_fake_sleep(2)

        self.assertTrue(decision.start_off)
        self.assertEqual(decision.request_kind, "automatic")
        self.assertEqual(decision.trigger, "fake-sleep")
        self.assertEqual(decision.fake_sleep_minutes, 11)

    def test_invalid_factory_suppression_never_partially_mutates_request_state(self):
        requests = {
            "power_off": lambda scheduler: scheduler.power_off(
                destination="power-save", factory_suppressed=1
            ),
            "begin_fake_sleep": lambda scheduler: scheduler.begin_fake_sleep(
                destination="power-save", factory_suppressed=1
            ),
            "request_manual_off": lambda scheduler: scheduler.request_manual_off(
                destination="power-save", factory_suppressed=1
            ),
        }

        for name, request in requests.items():
            with self.subTest(method=name):
                scheduler = MSIScheduler(destination="display")
                scheduler.accumulate_minutes(42)
                before = vars(scheduler).copy()

                with self.assertRaises(ValueError):
                    request(scheduler)

                self.assertEqual(vars(scheduler), before)

    def test_manual_and_automatic_requests_are_distinct_immutable_decisions(self):
        scheduler = MSIScheduler()

        manual = scheduler.request_manual_off(destination="power-save")
        scheduler.accumulate_minutes(240)
        automatic = scheduler.power_off(destination="power-save")

        self.assertTrue(manual.start_off)
        self.assertEqual(manual.request_kind, "manual")
        self.assertTrue(automatic.start_off)
        self.assertEqual(automatic.request_kind, "automatic")
        with self.assertRaises(dataclasses.FrozenInstanceError):
            manual.request_kind = "automatic"

    def test_scheduler_decisions_only_request_off_runs(self):
        scheduler = MSIScheduler()
        scheduler.accumulate_minutes(240)

        decisions = (
            scheduler.eligibility(),
            scheduler.request_manual_off(destination="power-save"),
            scheduler.power_off(destination="power-save"),
        )

        self.assertTrue(all(decision.run_kind == "off" for decision in decisions))


if __name__ == "__main__":
    unittest.main()
