"""Validated MSI OLED-care settings and the production OFF scheduler boundary."""

from __future__ import annotations

from dataclasses import dataclass


_DESTINATIONS = frozenset({"display", "power-save", "power-off"})
_FOUR_HOURS_MINUTES = 4 * 60
_FAKE_SLEEP_MINUTES = 10


def _require_bool(name: str, value: object) -> None:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be boolean")


def _require_int_in(name: str, value: object, allowed: range | tuple[int, ...]) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value not in allowed:
        if isinstance(allowed, range):
            allowed_values = f"{allowed.start}...{allowed.stop - 1}"
        else:
            allowed_values = ", ".join(str(item) for item in allowed)
        raise ValueError(f"{name} must be an integer in {allowed_values}")


def _require_non_negative_int(name: str, value: object) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer")


def _require_destination(destination: object) -> str:
    if destination not in _DESTINATIONS:
        choices = ", ".join(sorted(_DESTINATIONS))
        raise ValueError(f"destination must be one of {choices}")
    return str(destination)


@dataclass(frozen=True)
class MSIRegisterWrite:
    register: int
    payload: tuple[int, ...]
    verify_readback: bool
    attempts: int
    evidence: str = "msi-source-translated"


@dataclass(frozen=True)
class MSIOLEDSettings:
    """Configured OSD values, kept distinct from effective VRR-gated writes."""

    pixel_shift_enabled: bool
    pixel_shift_speed: int
    static_enabled: bool
    static_start_seconds: int
    static_required_seconds: int
    static_level: int
    boundary_level: int
    taskbar_level: int
    logo_level: int

    def validate(self) -> None:
        _require_bool("pixel_shift_enabled", self.pixel_shift_enabled)
        _require_int_in("pixel_shift_speed", self.pixel_shift_speed, range(3))
        _require_bool("static_enabled", self.static_enabled)
        _require_int_in("static_start_seconds", self.static_start_seconds, (50, 100))
        _require_int_in(
            "static_required_seconds", self.static_required_seconds, (120, 240)
        )
        _require_int_in("static_level", self.static_level, range(1, 8))
        _require_int_in("boundary_level", self.boundary_level, range(4))
        _require_int_in("taskbar_level", self.taskbar_level, range(4))
        _require_int_in("logo_level", self.logo_level, range(4))


def _static_screen_payload(settings: MSIOLEDSettings) -> tuple[int, int]:
    if not settings.static_enabled:
        return (0, 0)

    required_selector = 1 if settings.static_required_seconds == 240 else 0
    start_selector = 1 if settings.static_start_seconds == 100 else 0
    return ((required_selector << 4) | start_selector, settings.static_level)


def _configured_write(register: int, payload: tuple[int, ...]) -> MSIRegisterWrite:
    return MSIRegisterWrite(
        register=register,
        payload=payload,
        verify_readback=True,
        attempts=10,
    )


def display_up_writes(
    settings: MSIOLEDSettings, *, vrr_active: bool
) -> tuple[MSIRegisterWrite, ...]:
    """Return the recovered after-display settings transaction in source order."""

    settings.validate()
    _require_bool("vrr_active", vrr_active)

    effective_boundary = 0 if vrr_active else settings.boundary_level
    effective_taskbar = 0 if vrr_active else settings.taskbar_level
    effective_logo = 0 if vrr_active else settings.logo_level
    return (
        _configured_write(0x070, (0, int(settings.pixel_shift_enabled))),
        _configured_write(0x072, (0, settings.pixel_shift_speed)),
        _configured_write(0x060, _static_screen_payload(settings)),
        _configured_write(0x1B4, (0, effective_boundary)),
        _configured_write(0x1B6, (0, effective_taskbar)),
        _configured_write(0x1B2, (0, effective_logo)),
    )


@dataclass(frozen=True)
class MSISchedulerDecision:
    """An immutable request/snapshot returned by a scheduler operation."""

    start_off: bool
    eligible: bool
    request_kind: str | None
    trigger: str | None
    run_kind: str
    off_elapsed_hours: int
    off_elapsed_minutes: int
    off_run_count: int
    fake_sleep_minutes: int
    destination: str | None
    factory_suppressed: bool
    evidence: str = "msi-source-translated"


@dataclass
class MSIScheduler:
    """Minute-based production scheduler; it can request only the OFF run."""

    off_elapsed_hours: int = 0
    off_elapsed_minutes: int = 0
    off_run_count: int = 0
    fake_sleep_minutes: int = 0
    destination: str | None = None
    factory_suppressed: bool = False
    _fake_sleep_active: bool = False
    _automatic_started: bool = False

    def __post_init__(self) -> None:
        _require_non_negative_int("off_elapsed_hours", self.off_elapsed_hours)
        _require_int_in("off_elapsed_minutes", self.off_elapsed_minutes, range(60))
        _require_non_negative_int("off_run_count", self.off_run_count)
        _require_non_negative_int("fake_sleep_minutes", self.fake_sleep_minutes)
        if self.destination is not None:
            _require_destination(self.destination)
        _require_bool("factory_suppressed", self.factory_suppressed)
        _require_bool("_fake_sleep_active", self._fake_sleep_active)
        _require_bool("_automatic_started", self._automatic_started)

    @property
    def accumulated_minutes(self) -> int:
        return self.off_elapsed_hours * 60 + self.off_elapsed_minutes

    def _decision(
        self,
        *,
        start_off: bool = False,
        request_kind: str | None = None,
        trigger: str | None = None,
    ) -> MSISchedulerDecision:
        return MSISchedulerDecision(
            start_off=start_off,
            eligible=self.accumulated_minutes >= _FOUR_HOURS_MINUTES,
            request_kind=request_kind,
            trigger=trigger,
            run_kind="off",
            off_elapsed_hours=self.off_elapsed_hours,
            off_elapsed_minutes=self.off_elapsed_minutes,
            off_run_count=self.off_run_count,
            fake_sleep_minutes=self.fake_sleep_minutes,
            destination=self.destination,
            factory_suppressed=self.factory_suppressed,
        )

    def eligibility(self) -> MSISchedulerDecision:
        return self._decision()

    def accumulate_minutes(self, minutes: int) -> MSISchedulerDecision:
        _require_non_negative_int("minutes", minutes)
        total = self.accumulated_minutes + minutes
        self.off_elapsed_hours, self.off_elapsed_minutes = divmod(total, 60)
        return self._decision()

    def power_off(
        self, *, destination: str, factory_suppressed: bool = False
    ) -> MSISchedulerDecision:
        validated_destination = _require_destination(destination)
        _require_bool("factory_suppressed", factory_suppressed)
        self.destination = validated_destination
        self.factory_suppressed = factory_suppressed
        self._fake_sleep_active = False
        should_start = (
            self.accumulated_minutes >= _FOUR_HOURS_MINUTES
            and not self._automatic_started
        )
        if should_start:
            self._automatic_started = True
        return self._decision(
            start_off=should_start,
            request_kind="automatic" if should_start else None,
            trigger="power-off" if should_start else None,
        )

    def begin_fake_sleep(
        self, *, destination: str, factory_suppressed: bool = False
    ) -> MSISchedulerDecision:
        validated_destination = _require_destination(destination)
        _require_bool("factory_suppressed", factory_suppressed)
        self.destination = validated_destination
        self.factory_suppressed = factory_suppressed
        self.fake_sleep_minutes = 0
        self._fake_sleep_active = True
        self._automatic_started = False
        return self._decision()

    def advance_fake_sleep(self, minutes: int) -> MSISchedulerDecision:
        _require_non_negative_int("minutes", minutes)
        if not self._fake_sleep_active:
            raise ValueError("fake sleep has not begun")
        self.fake_sleep_minutes += minutes
        should_start = (
            self.accumulated_minutes >= _FOUR_HOURS_MINUTES
            and self.fake_sleep_minutes >= _FAKE_SLEEP_MINUTES
            and not self._automatic_started
        )
        if should_start:
            self._automatic_started = True
        return self._decision(
            start_off=should_start,
            request_kind="automatic" if should_start else None,
            trigger="fake-sleep" if should_start else None,
        )

    def request_manual_off(
        self, *, destination: str, factory_suppressed: bool = False
    ) -> MSISchedulerDecision:
        validated_destination = _require_destination(destination)
        _require_bool("factory_suppressed", factory_suppressed)
        self.destination = validated_destination
        self.factory_suppressed = factory_suppressed
        return self._decision(start_off=True, request_kind="manual", trigger="manual")
