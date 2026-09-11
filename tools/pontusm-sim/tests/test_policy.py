import unittest

from pontusm_sim.patterns import PatternResult
from pontusm_sim.policy import ProtectionPolicy
from pontusm_sim.types import AlgorithmVersion, FrameStats


def patterns(*, standard=False, color=False):
    return PatternResult(
        flat=False,
        standard=standard,
        hdr_color=color,
        local_allowed=not (standard or color),
        standard_counter=0,
        symmetry=0,
    )


class ProtectionPolicyTests(unittest.TestCase):
    def test_v20_encodes_four_states_as_two_source_bits(self):
        frame = FrameStats.neutral()
        frame.motion = False
        self.assertEqual(
            ProtectionPolicy(AlgorithmVersion.V20).step(frame, patterns(), 0).encoded_state,
            0,
        )
        self.assertEqual(
            ProtectionPolicy(AlgorithmVersion.V20).step(
                frame, patterns(color=True), 0
            ).encoded_state,
            1,
        )
        frame.motion = True
        self.assertEqual(
            ProtectionPolicy(AlgorithmVersion.V20).step(frame, patterns(), 0).encoded_state,
            2,
        )
        self.assertEqual(
            ProtectionPolicy(AlgorithmVersion.V20).step(frame, patterns(), 401).encoded_state,
            3,
        )

    def test_no_still_motion_history_refreshes_on_eight_call_cycle(self):
        policy = ProtectionPolicy(AlgorithmVersion.V20)
        frame = FrameStats.neutral()
        frame.motion = True
        self.assertEqual(policy.step(frame, patterns(), 0).no_still_counter, 30)
        frame.motion = False
        for _ in range(7):
            self.assertEqual(policy.step(frame, patterns(), 0).no_still_counter, 30)
        self.assertEqual(policy.step(frame, patterns(), 0).no_still_counter, 29)

    def test_v18_reports_split_policy_unavailable(self):
        result = ProtectionPolicy(AlgorithmVersion.V18).step(
            FrameStats.neutral(), patterns(), 500
        )
        self.assertFalse(result.feature_available)
        self.assertIsNone(result.screen_saver_off)
        self.assertIsNone(result.isp_off)
        self.assertIsNone(result.encoded_state)

    def test_v22_policy_ignores_retired_retention_counter(self):
        frame = FrameStats.neutral()
        frame.motion = False
        result = ProtectionPolicy(AlgorithmVersion.V22).step(
            frame, patterns(), 500
        )
        self.assertTrue(result.feature_available)
        self.assertFalse(result.screen_saver_off)
        self.assertFalse(result.isp_off)
        self.assertEqual(result.encoded_state, 0)


if __name__ == "__main__":
    unittest.main()
