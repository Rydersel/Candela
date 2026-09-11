"""Local 15x15 protection-map and app/OSD limiter behavior."""

from __future__ import annotations

from dataclasses import dataclass, field

from .arithmetic import clamp
from .types import AlgorithmVersion, FrameStats, LogoBrightness


LPC_SHAPE1 = (
    115,126,139,150,160,169,174,175,174,169,160,150,139,126,115,
    130,141,155,167,179,188,194,195,194,188,179,167,155,141,130,
    146,158,175,188,200,210,216,217,216,210,200,188,175,158,146,
    158,172,189,203,216,226,234,234,234,226,216,203,189,172,158,
    166,181,199,213,226,237,246,247,246,237,226,213,199,181,166,
    170,185,203,217,230,242,251,253,251,242,230,217,203,185,170,
    171,186,204,219,232,244,254,256,254,244,232,219,204,186,171,
    171,186,204,219,232,245,254,256,254,245,232,219,204,186,171,
    171,186,204,219,232,244,254,256,254,244,232,219,204,186,171,
    170,185,203,217,230,242,251,253,251,242,230,217,203,185,170,
    166,181,199,213,226,237,246,247,246,237,226,213,199,181,166,
    158,172,189,203,216,226,234,234,234,226,216,203,189,172,158,
    146,158,175,188,200,210,216,217,216,210,200,188,175,158,146,
    130,141,155,167,179,188,194,195,194,188,179,167,155,141,130,
    115,126,139,150,160,169,174,175,174,169,160,150,139,126,115,
)

LPC_SHAPE2 = (
    237,256,237,196,177,196,237,256,237,196,177,196,237,256,237,
    256,256,256,212,192,212,256,256,256,212,192,212,256,256,256,
    237,256,237,196,177,196,237,256,237,196,177,196,237,256,237,
    196,212,196,160,144,160,196,212,196,160,144,160,196,212,196,
    177,192,177,144,128,144,177,192,177,144,128,144,177,192,177,
    196,212,196,160,144,160,196,212,196,160,144,160,196,212,196,
    237,256,237,196,177,196,237,256,237,196,177,196,237,256,237,
    256,256,256,212,192,212,256,256,256,212,192,212,256,256,256,
    237,256,237,196,177,196,237,256,237,196,177,196,237,256,237,
    196,212,196,160,144,160,196,212,196,160,144,160,196,212,196,
    177,192,177,144,128,144,177,192,177,144,128,144,177,192,177,
    196,212,196,160,144,160,196,212,196,160,144,160,196,212,196,
    237,256,237,196,177,196,237,256,237,196,177,196,237,256,237,
    256,256,256,212,192,212,256,256,256,212,192,212,256,256,256,
    237,256,237,196,177,196,237,256,237,196,177,196,237,256,237,
)


@dataclass(frozen=True)
class LocalExclusions:
    flat: bool = False
    standard_pattern: bool = False
    hdr_color_pattern: bool = False
    scene_state: int = 0


@dataclass(frozen=True)
class LocalResult:
    strength: int
    target_strength: int
    duties: tuple[int, ...]
    local_allowed: bool
    exclusion_reasons: tuple[str, ...]


@dataclass
class AppLimiter:
    count: int = 0

    def step(self, app_area: int, osd_area: int) -> tuple[int, int]:
        if app_area > 0 and osd_area > 0:
            self.count = min(512, self.count + 1)
        else:
            self.count = max(0, self.count - 1)
        return self.count, 255 - (self.count >> 3)


@dataclass
class LocalProtection:
    version: AlgorithmVersion
    strength: int = 0
    duties: list[int] = field(default_factory=lambda: [255] * 225)
    _v22_global_reduce: int = 255
    _v22_cycle_minima: list[int] = field(
        default_factory=lambda: [255] * 4, repr=False
    )

    def apply_menu_scale(self, duty: int, menu: LogoBrightness) -> int:
        duty = clamp(duty, 0, 255)
        if self.version is AlgorithmVersion.V18:
            return duty
        if menu is LogoBrightness.OFF:
            return 255 - (((255 - duty) * 170) >> 8)
        if menu is LogoBrightness.HIGH:
            return max(0, 255 - (((255 - duty) * 365) >> 8))
        return duty

    def srp_mask_gains(self, menu: LogoBrightness) -> tuple[int, int]:
        """Return v22's center and source-named ``board`` SRP gains."""
        if self.version is not AlgorithmVersion.V22:
            raise ValueError("SRP mask gains are available only for version 22")
        return (128, 192) if menu is LogoBrightness.HIGH else (196, 224)

    def _pattern_gain(self, frame: FrameStats) -> int:
        probability = frame.pattern_probability
        if frame.pc_mode:
            return 0 if probability > 1024 else 256 - (probability >> 2)
        if frame.movie_mode and not (
            self.version is AlgorithmVersion.V22
            and frame.logo_brightness is LogoBrightness.HIGH
        ):
            if probability < 388:
                return 256
            if probability > 900:
                return 0
            return 256 - ((probability - 388) >> 1)
        if frame.motion:
            return 256
        knee = 768 if self.version is AlgorithmVersion.V22 else 512
        if probability < knee:
            return 256
        if probability > 1024:
            return 0
        if self.version is AlgorithmVersion.V22:
            return 256 - (probability - knee)
        return 256 - ((probability - knee) >> 1)

    @staticmethod
    def _lpc_mix(index: int, shape1_gain: int, shape2_gain: int) -> int:
        shape1 = 256 - min(256, ((256 - LPC_SHAPE1[index]) * shape1_gain) >> 8)
        shape2 = 256 - min(256, ((256 - LPC_SHAPE2[index]) * shape2_gain) >> 8)
        return min(256, (shape1 * shape2) >> 8) << 2

    @staticmethod
    def _row_limited(values: list[int]) -> list[int]:
        result = list(values)
        line_limit = 255
        for index, value in enumerate(values):
            if index < 105:
                line_limit = 255
            elif index in (105, 120, 135, 150, 165, 180, 195, 210):
                line_min = min(values[index : index + 15])
                line_limit = line_min + 160 - (index >> 1)
            result[index] = min(line_limit, value)
        return result

    def step(
        self,
        frame: FrameStats,
        exclusions: LocalExclusions,
        retention_count: int,
        *,
        app_counter: int = 0,
        phase: int | None = None,
        ew_mode: bool = False,
    ) -> LocalResult:
        if phase is not None and (
            not isinstance(phase, int) or isinstance(phase, bool) or not 0 <= phase <= 4
        ):
            raise ValueError("phase must be in 0...4")
        reasons: list[str] = []
        if frame.capture_error:
            reasons.append("capture-error")
        if frame.dormant:
            reasons.append("dormant")
        if frame.portrait:
            reasons.append("portrait")
        if not frame.qd_enabled:
            reasons.append("qd-disabled")
        if not frame.local_feature_enabled:
            reasons.append("local-feature-disabled")
        if frame.logo_brightness is LogoBrightness.OFF and (frame.movie_mode or frame.pc_mode):
            reasons.append("off-mode-policy")
        if app_counter > 0:
            reasons.append("app-osd")
        if exclusions.scene_state in (1, 2):
            reasons.append("scene-state")
        if exclusions.flat:
            reasons.append("flat")
        if exclusions.standard_pattern:
            reasons.append("standard-pattern")
        if exclusions.hdr_color_pattern:
            reasons.append("hdr-color-pattern")
        if retention_count > 400 and self.version is not AlgorithmVersion.V22:
            reasons.append("retention")
        if frame.factory_mode and self.version is AlgorithmVersion.V22:
            reasons.append("factory-mode")

        osd = (frame.osd_area >> 2) * 5
        target = 0 if reasons or osd > 1024 else 1024 - osd
        if self.version is AlgorithmVersion.V22:
            target = ((target * self._pattern_gain(frame)) + 128) >> 8
            target = ((target * frame.brightness) + 512) >> 10
            if frame.image_mean < 256:
                dark_reduction = (256 - frame.image_mean) >> (
                    2 if frame.movie_mode or frame.pc_mode else 3
                )
                target = max(0, target - dark_reduction)
        else:
            target = (target * self._pattern_gain(frame)) >> 8
            target = (target * frame.brightness) >> 10
        if self.version is AlgorithmVersion.V18 and frame.logo_brightness is LogoBrightness.OFF:
            target = (target * 170) >> 8

        if frame.movie_mode and frame.black_probability == 1023:
            self.strength = 0
        elif target > self.strength:
            self.strength = min(1024, self.strength + (8 if ew_mode else 1))
        elif target < self.strength:
            self.strength = max(0, self.strength - 16)

        source_values = list(frame.region_gains)
        global_reduce = (
            self._v22_global_reduce
            if self.version is AlgorithmVersion.V22 and phase is not None
            else sum(sorted(source_values)[:4]) >> 2
        )
        blended = []
        for raw in source_values:
            candidate = global_reduce if frame.logo_brightness is LogoBrightness.OFF else raw
            numerator = candidate * self.strength + (1024 - self.strength) * 255
            if self.version is AlgorithmVersion.V22:
                numerator += 512
            blended.append(numerator >> 10)

        if app_counter > 0 and not ew_mode:
            rendered = [255 - (app_counter >> 3)] * 225
        elif self.version is AlgorithmVersion.V22:
            rendered = self._row_limited(blended)
        elif frame.movie_mode or frame.pc_mode:
            add = ((256 - frame.image_mean) >> 2) if frame.image_mean < 256 else 0
            rendered = [min(255, value + add) for value in blended]
        else:
            limited = self._row_limited(blended)
            add = ((256 - frame.image_mean) >> 3) if frame.image_mean < 256 else 0
            rendered = [min(255, value + add) for value in limited]

        rendered = [self.apply_menu_scale(value, frame.logo_brightness) for value in rendered]
        if self.version is AlgorithmVersion.V22:
            rendered = [
                (value * self._lpc_mix(
                    index, frame.lpc_shape1_gain, frame.lpc_shape2_gain
                )) >> 10
                for index, value in enumerate(rendered)
            ]
            if phase is not None:
                if phase == 0:
                    self._v22_cycle_minima[:] = [255] * 4
                start = phase * 45
                for value in source_values[start : start + 45]:
                    self._v22_cycle_minima.append(value)
                    self._v22_cycle_minima.sort()
                    self._v22_cycle_minima.pop()
                if phase == 4:
                    self._v22_global_reduce = sum(self._v22_cycle_minima) >> 2
        if phase is None:
            self.duties[:] = rendered
        else:
            start = phase * 45
            self.duties[start : start + 45] = rendered[start : start + 45]

        return LocalResult(
            strength=self.strength,
            target_strength=target,
            duties=tuple(self.duties),
            local_allowed=not reasons,
            exclusion_reasons=tuple(reasons),
        )
