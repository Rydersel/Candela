"""Stateful orchestration of the modeled PontusM QD protection pipeline."""

from __future__ import annotations

from dataclasses import dataclass, field

from .banner import BannerDetector
from .curve import FCNCurveController
from .local import AppLimiter, LocalExclusions, LocalProtection
from .patterns import PatternDetector
from .peak import PeakAccumulator
from .policy import ProtectionPolicy
from .retention import RetentionDetector
from .types import AlgorithmVersion, FrameStats, QDOutputs, QDStateSnapshot


@dataclass
class QDModel:
    version: AlgorithmVersion
    tick: int = 0
    calculation_phase: int = 0
    patterns: PatternDetector = field(init=False)
    retention: RetentionDetector = field(default_factory=RetentionDetector)
    curve: FCNCurveController = field(default_factory=FCNCurveController)
    peak: PeakAccumulator = field(default_factory=PeakAccumulator)
    app: AppLimiter = field(default_factory=AppLimiter)
    local: LocalProtection = field(init=False)
    banner: BannerDetector | None = field(init=False)
    policy: ProtectionPolicy = field(init=False)

    def __post_init__(self) -> None:
        self.version = AlgorithmVersion(self.version)
        self.patterns = PatternDetector(self.version)
        self.local = LocalProtection(self.version)
        self.banner = (
            None
            if self.version is AlgorithmVersion.V18
            else BannerDetector(self.version)
        )
        self.policy = ProtectionPolicy(self.version)

    def snapshot(self) -> QDStateSnapshot:
        return QDStateSnapshot(
            tick=self.tick,
            retention_count=(
                0 if self.version is AlgorithmVersion.V22 else self.curve.retention_count
            ),
            fcn_gain=0 if self.version is AlgorithmVersion.V22 else self.curve.gain,
            local_strength=self.local.strength,
            app_counter=self.app.count,
            anti_residue=self.peak.result,
            banner_probability=(
                None if self.banner is None else self.banner.raw_probability
            ),
            banner_history=None if self.banner is None else self.banner.history_count,
        )

    def step(self, frame: FrameStats) -> QDOutputs:
        # Validation must precede all calls below because every component is stateful.
        frame.validate()
        evaluate = self.calculation_phase == 0

        pattern_result = self.patterns.step(frame, evaluate=evaluate)
        if self.version is AlgorithmVersion.V22:
            retained = False
            retention_count = 0
            gain = 0
            curve: tuple[int, ...] = ()
        else:
            retained = self.retention.step(frame)
            gain, curve = self.curve.step(retained)
            retention_count = self.curve.retention_count
        anti_residue = self.peak.step(
            frame.max_columns,
            frame.max_rows,
            enabled=frame.spi_analog >= frame.spi_threshold,
        )
        app_counter, app_duty = self.app.step(frame.app_area, frame.osd_area)
        policy = self.policy.step(
            frame,
            pattern_result,
            retention_count,
            evaluate=evaluate,
        )

        if self.banner is None:
            banner_probability = None
            banner_history = None
        else:
            banner_result = self.banner.step(
                frame,
                retention_count=retention_count,
                hdr_color=pattern_result.hdr_color,
                standard_pattern=pattern_result.standard,
            )
            banner_probability = banner_result.probability
            banner_history = banner_result.history_count

        local_result = self.local.step(
            frame,
            LocalExclusions(
                flat=pattern_result.flat,
                standard_pattern=pattern_result.standard,
                hdr_color_pattern=pattern_result.hdr_color,
            ),
            retention_count,
            app_counter=app_counter,
            phase=self.calculation_phase,
        )

        self.tick += 1
        self.calculation_phase = (
            self.calculation_phase + 1 if self.calculation_phase < 4 else 0
        )
        return QDOutputs(
            tick=self.tick,
            flat=pattern_result.flat,
            standard_pattern=pattern_result.standard,
            hdr_color_pattern=pattern_result.hdr_color,
            retention=retained,
            retention_available=self.version is not AlgorithmVersion.V22,
            retention_count=retention_count,
            local_strength=local_result.strength,
            local_target_strength=local_result.target_strength,
            app_counter=app_counter,
            app_duty=app_duty,
            anti_residue=anti_residue,
            fcn_gain=gain,
            fcn_available=self.version is not AlgorithmVersion.V22,
            curve=curve,
            region_duties=local_result.duties,
            srp_center_mask_gain=(
                self.local.srp_mask_gains(frame.logo_brightness)[0]
                if self.version is AlgorithmVersion.V22
                else None
            ),
            srp_board_mask_gain=(
                self.local.srp_mask_gains(frame.logo_brightness)[1]
                if self.version is AlgorithmVersion.V22
                else None
            ),
            banner_available=self.banner is not None,
            banner_probability=banner_probability,
            banner_history=banner_history,
            screen_saver_off=policy.screen_saver_off,
            isp_off=policy.isp_off,
            policy_state=policy.encoded_state,
        )
