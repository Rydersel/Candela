import unittest

from pontusm_sim.bip import (
    BIPAction,
    BIPModel,
    BIPState,
    BIPTable,
    DEFAULT_INTERVAL_TICKS,
)
from pontusm_sim.types import AlgorithmVersion, Fidelity


NORMAL = (
    (0, 0),
    (1, -1),
    (2, -2),
    (3, -3),
    (4, -4),
    (5, -5),
    (6, -6),
    (7, -7),
    (8, -8),
    (9, -9),
    (10, -10),
    (11, -11),
)
ENGINEERING = ((0, 0), (-16, -16), (16, 16))
ROTATED = ((20, 10), (21, 11), (22, 12))


def model(
    *,
    version: AlgorithmVersion = AlgorithmVersion.V20,
    interval_ticks: int = DEFAULT_INTERVAL_TICKS,
    rotated=ROTATED,
    initial_geometry=(0, 0),
) -> BIPModel:
    return BIPModel(
        NORMAL,
        ENGINEERING,
        rotated=rotated,
        interval_ticks=interval_ticks,
        version=version,
        initial_geometry=initial_geometry,
    )


def movement(events):
    return next(event for event in events if event.action is BIPAction.MOVE)


class BIPModelTests(unittest.TestCase):
    def test_default_cadence_is_one_minute_of_nominal_qd_ticks(self):
        bip = model()
        enabled = bip.set_enabled(True)
        self.assertEqual(DEFAULT_INTERVAL_TICKS, 60_000 // 20)
        self.assertEqual(movement(enabled).position, (0, 0))
        self.assertEqual(bip.index, 1)

        self.assertEqual(bip.step(DEFAULT_INTERVAL_TICKS - 1), ())
        primed = bip.step()
        self.assertEqual(len(primed), 1)
        self.assertEqual(primed[0].action, BIPAction.PRIME)
        self.assertEqual(primed[0].reason, "cadence-prime")
        self.assertEqual(primed[0].position, (1, -1))
        self.assertEqual(primed[0].tick, DEFAULT_INTERVAL_TICKS)
        self.assertEqual(bip.index, 2)
        self.assertEqual(bip.state, BIPState.RUN)
        self.assertEqual(bip.current_position, (0, 0))

        moved = bip.step(DEFAULT_INTERVAL_TICKS)
        self.assertEqual(moved[0].action, BIPAction.MOVE)
        self.assertEqual(moved[0].position, (2, -2))
        self.assertEqual(moved[0].tick, DEFAULT_INTERVAL_TICKS * 2)

    def test_normal_index_wraps_without_copying_the_official_table(self):
        bip = BIPModel(
            ((0, 0), (1, 1), (2, 2)),
            ENGINEERING,
            interval_ticks=1,
            version=AlgorithmVersion.V20,
        )
        self.assertEqual(movement(bip.set_enabled(True)).position, (0, 0))
        self.assertEqual(
            [event.position for event in bip.step(3)],
            [(1, 1), (2, 2), (0, 0)],
        )
        self.assertEqual(bip.index, 1)

    def test_off_to_on_differs_between_source_versions(self):
        version_18 = model(version=AlgorithmVersion.V18, rotated=None)
        version_20 = model()

        event_18 = movement(version_18.set_enabled(True))
        event_20 = movement(version_20.set_enabled(True))

        self.assertEqual(event_18.position, NORMAL[1])
        self.assertEqual(event_18.selected_index, 1)
        self.assertEqual(version_18.index, 2)
        self.assertEqual(event_20.position, NORMAL[0])
        self.assertEqual(event_20.selected_index, 0)
        self.assertEqual(version_20.index, 1)

    def test_off_preserves_index_and_version_20_on_restores_it(self):
        bip = model(interval_ticks=2)
        bip.set_enabled(True)
        bip.set_enabled(False)
        index_while_off = bip.index

        self.assertEqual(bip.step(4), ())
        self.assertEqual(bip.index, index_while_off)

        restored = bip.set_enabled(True)
        restored_move = movement(restored)
        self.assertEqual(restored_move.reason, "enabled")
        self.assertEqual(restored_move.selected_index, index_while_off)
        self.assertEqual(restored_move.position, NORMAL[index_while_off])

    def test_rotation_resets_index_and_selects_the_rotated_table(self):
        bip = model(interval_ticks=1)
        bip.set_enabled(True)
        rotation_events = bip.set_rotation(True)

        self.assertEqual(bip.index, 0)
        self.assertIsNone(bip.current_position)
        self.assertEqual(rotation_events[0].action, BIPAction.ROTATION)
        self.assertEqual(rotation_events[1].action, BIPAction.PERSIST)
        self.assertIn("@rot\n1\n", rotation_events[1].persisted_state)

        primed = bip.step()[0]
        self.assertEqual(primed.action, BIPAction.PRIME)
        self.assertEqual(primed.table, BIPTable.ROTATED)
        self.assertEqual(primed.position, ROTATED[0])
        self.assertIsNone(bip.current_position)

        move = bip.step()[0]
        self.assertEqual(move.table, BIPTable.ROTATED)
        self.assertEqual(move.position, ROTATED[1])

    def test_rotation_requires_version_20_and_a_runtime_table(self):
        with self.assertRaisesRegex(ValueError, "version 20"):
            model(version=AlgorithmVersion.V18, rotated=None).set_rotation(True)
        with self.assertRaisesRegex(ValueError, "rotated orbit table"):
            model(rotated=None).set_rotation(True)

    def test_version_22_rotation_uses_the_version_20_persistence_format(self):
        bip = model(version=AlgorithmVersion.V22)
        bip.set_enabled(True)
        events = bip.set_rotation(True)
        self.assertEqual(events[0].action, BIPAction.ROTATION)
        self.assertIn("@rot\n1\n", events[1].persisted_state)

    def test_engineering_verification_selects_ew_without_moving_normal_index(self):
        bip = model()
        bip.set_enabled(True)
        normal_index = bip.index

        event = bip.engineering_verify(2)

        self.assertEqual(event.action, BIPAction.ENGINEERING)
        self.assertEqual(event.table, BIPTable.ENGINEERING)
        self.assertEqual(event.position, ENGINEERING[2])
        self.assertEqual(bip.index, normal_index)
        with self.assertRaisesRegex(ValueError, "engineering index"):
            bip.engineering_verify(len(ENGINEERING))

    def test_every_tenth_source_index_advance_persists_the_pre_advance_index(self):
        bip = model(interval_ticks=1)
        self.assertEqual(
            [event.action for event in bip.set_enabled(True)],
            [BIPAction.MODE, BIPAction.PERSIST, BIPAction.MOVE],
        )

        for _ in range(8):
            self.assertEqual(len(bip.step()), 1)
        tenth = bip.step()

        self.assertEqual(
            [event.action for event in tenth],
            [BIPAction.MOVE, BIPAction.PERSIST],
        )
        self.assertEqual(tenth[0].selected_index, 9)
        self.assertEqual(bip.index, 10)
        self.assertIn("@index\n9\n", tenth[1].persisted_state)

    def test_resume_reapplies_the_current_index_only_while_enabled(self):
        bip = model()
        bip.set_enabled(True)
        resumed = bip.resume()
        self.assertEqual(resumed[0].action, BIPAction.MOVE)
        self.assertEqual(resumed[0].reason, "resume")
        self.assertEqual(resumed[0].position, NORMAL[1])

        bip.set_enabled(False)
        index_while_off = bip.index
        self.assertEqual(bip.resume(), ())
        self.assertEqual(bip.index, index_while_off)

    def test_factory_reset_turns_off_and_persists_zero_without_clearing_rotation(self):
        bip = model()
        bip.set_enabled(True)
        bip.set_rotation(True)

        events = bip.factory_reset()

        self.assertFalse(bip.enabled)
        self.assertTrue(bip.rotation)
        self.assertEqual(bip.index, 0)
        self.assertIsNone(bip.current_position)
        self.assertEqual(events[0].action, BIPAction.FACTORY_RESET)
        self.assertEqual(events[1].action, BIPAction.PERSIST)
        self.assertEqual(
            events[1].persisted_state,
            "@mode\n0\n@index\n0\n@rot\n1\n@done\n",
        )

    def test_persisted_state_formats_match_each_source_version(self):
        version_18 = model(version=AlgorithmVersion.V18, rotated=None)
        version_20 = model()
        version_18.set_enabled(True)
        version_20.set_enabled(True)

        self.assertEqual(
            version_18.serialize_state(index=7),
            "@mode\n2\n@index\n7\n@done\n",
        )
        self.assertEqual(
            version_20.serialize_state(index=7),
            "@mode\n2\n@index\n7\n@rot\n0\n@done\n",
        )

    def test_restore_validates_before_mutating_state(self):
        bip = model()
        bip.set_enabled(True)
        before = bip.snapshot()

        invalid_documents = (
            "@mode\n2\n@index\nnot-a-number\n@rot\n0\n@done\n",
            "@mode\n2\n@index\n99\n@rot\n0\n@done\n",
            "@mode\n4\n@index\n0\n@rot\n0\n@done\n",
            "@mode\n2\n@index\n0\n@done\n",
        )
        for document in invalid_documents:
            with self.subTest(document=document):
                with self.assertRaises(ValueError):
                    bip.restore_state(document)
                self.assertEqual(bip.snapshot(), before)

        restored = bip.restore_state("@mode\n2\n@index\n2\n@rot\n1\n@done\n")
        self.assertEqual(restored[0].action, BIPAction.RESTORE)
        self.assertTrue(bip.enabled)
        self.assertTrue(bip.rotation)
        self.assertEqual(bip.index, 2)

    def test_events_carry_reportable_source_fidelity(self):
        event = movement(model().set_enabled(True))
        self.assertEqual(event.fidelity, Fidelity.SOURCE_TRANSLATED)
        self.assertIn("sdp_pqe_bip.c", event.source_reference)

    def test_constructor_and_step_reject_invalid_inputs_without_state_changes(self):
        with self.assertRaisesRegex(ValueError, "normal orbit table"):
            BIPModel((), ENGINEERING)
        with self.assertRaisesRegex(ValueError, "pairs of integers"):
            BIPModel(((0, 0, 0),), ENGINEERING)
        with self.assertRaisesRegex(ValueError, "pairs of integers"):
            BIPModel((7,), ENGINEERING)
        with self.assertRaisesRegex(ValueError, "interval_ticks"):
            BIPModel(NORMAL, ENGINEERING, interval_ticks=0)

        bip = model()
        before = bip.snapshot()
        with self.assertRaisesRegex(ValueError, "ticks"):
            bip.step(0)
        self.assertEqual(bip.snapshot(), before)

    def test_version_22_unmute_geometry_change_clears_offset_and_returns_idle(self):
        bip = model(
            version=AlgorithmVersion.V22,
            initial_geometry=(100, 200),
        )
        bip.set_enabled(True)
        index = bip.index
        self.assertEqual(bip.notify_frc_unmute(100, 200), ())

        events = bip.notify_frc_unmute(101, 200)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].action, BIPAction.GEOMETRY_RESET)
        self.assertEqual(events[0].reason, "frc-unmute-geometry-change")
        self.assertTrue(bip.enabled)
        self.assertEqual(bip.index, index)
        self.assertIsNone(bip.current_position)
        self.assertEqual(bip.state, BIPState.IDLE)
        self.assertEqual(bip.snapshot().output_geometry, (101, 200))

    def test_unmute_geometry_notifier_is_version_22_only_and_validates_atomically(self):
        old = model(version=AlgorithmVersion.V20)
        with self.assertRaisesRegex(ValueError, "version 22"):
            old.notify_frc_unmute(1, 2)

        new = model(version=AlgorithmVersion.V22)
        before = new.snapshot()
        with self.assertRaisesRegex(ValueError, "geometry"):
            new.notify_frc_unmute(-1, 2)
        self.assertEqual(new.snapshot(), before)

    def test_version_22_ignores_unmute_geometry_while_pixel_shift_is_off(self):
        bip = model(version=AlgorithmVersion.V22, initial_geometry=(10, 20))
        self.assertEqual(bip.notify_frc_unmute(30, 40), ())
        self.assertEqual(bip.snapshot().output_geometry, (10, 20))


if __name__ == "__main__":
    unittest.main()
