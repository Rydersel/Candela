"""Named helpers for the unsigned integer operations used by the source."""


def clamp(value: int, low: int, high: int) -> int:
    if low > high:
        raise ValueError("low must not exceed high")
    return min(high, max(low, value))


def u32(value: int) -> int:
    return value & 0xFFFF_FFFF


def linear_interpolate(
    value: int, in_low: int, in_high: int, out_low: int, out_high: int
) -> int:
    """Integer linear interpolation with source-style truncation and clamping."""
    if in_low >= in_high:
        raise ValueError("input range must be increasing")
    if value <= in_low:
        return out_low
    if value >= in_high:
        return out_high
    numerator = (value - in_low) * (out_high - out_low)
    return out_low + numerator // (in_high - in_low)
