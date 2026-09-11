"""The source-identical PontusM 41-point FCN/global response."""

from __future__ import annotations

from dataclasses import dataclass

from .arithmetic import clamp


ORIGINAL_CURVE = (
    0, 256, 512, 768, 1024, 1280, 1536, 1792, 2048, 2304,
    2560, 2816, 3072, 3328, 3584, 3840, 4096, 4608, 5120, 5632,
    6144, 6656, 7168, 7680, 8192, 8704, 9216, 9728, 10240, 10752,
    11264, 11776, 12288, 12800, 13312, 13824, 14336, 14848, 15360,
    15872, 16383,
)

REDUCED_CURVE = (
    0, 256, 512, 768, 1024, 1280, 1536, 1792, 2048, 2304,
    2560, 2671, 2782, 2893, 3004, 3116, 3227, 3449, 3671, 3893,
    4115, 4338, 4560, 4782, 5004, 5226, 5449, 5671, 5893, 6115,
    6338, 6560, 6782, 7004, 7226, 7449, 7671, 7893, 8115, 8337, 8559,
)


@dataclass
class FCNCurveController:
    retention_count: int = 0
    gain: int = 0

    LIMIT = 14_400
    ATTACK = 1
    RELEASE = 2_400

    def step(
        self, retention: bool, *, debug_gain: int | None = None
    ) -> tuple[int, tuple[int, ...]]:
        if retention:
            self.retention_count = min(3_500, self.retention_count + 1)
        else:
            self.retention_count = 0

        target = self.LIMIT if self.retention_count > 3_499 else 0
        if target > self.gain:
            self.gain += self.ATTACK
        elif target < self.gain:
            self.gain = max(0, self.gain - self.RELEASE)
        self.gain = min(self.LIMIT, self.gain)

        if debug_gain is not None:
            self.gain = clamp(debug_gain, 0, 16_384)

        inverse = 16_384 - self.gain
        curve = tuple(
            ((original * inverse) + (reduced * self.gain)) >> 14
            for original, reduced in zip(ORIGINAL_CURVE, REDUCED_CURVE, strict=True)
        )
        return self.gain, curve
