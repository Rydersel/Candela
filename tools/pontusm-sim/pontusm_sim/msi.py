"""MSI scaler-side sensing oracle, not a model of the panel's internals.

Authority: C-oled-care-mechanism.md sections 3.2–3.6. Counter seconds are
normalized to 1,000 ms: `counter > N` fires at (N + 1) seconds. Real firmware
increments counters after >1,000 ticks and polling introduces unknown latency;
this oracle does not emulate that scheduler. Direct tick guards retain strict
comparisons (>500 = 501 ms, >550 = 551 ms), while a blocking 500-tick delay is
500 ms. Transitions take no modeled CPU time. Input changes are observed on
the next advance (including advance(0)); inputs remain fixed within a call.
"""

from dataclasses import dataclass

from .msi_settings import MSIRegisterWrite


OFF_REST_MS = 181_000
OFF_TIMEOUT_MS = 376_000
TRIGGER_SETTLE_MS = 500
DONE_HIGH_HOLD_MS = 551
LED_PHASE_MS = 501
FINAL_WAIT_MS = 501
EL_FIRST_REST_MS = 901_000
EL_SECOND_REST_MS = 2_101_000
EL_WARMUP_MS = 2_000
EL_TIMEOUT_MS = 96_000


@dataclass(frozen=True)
class MSIEvent:
    time_ms: int
    kind: str
    state: str
    detail: tuple[tuple[str, object], ...]
    evidence: str = "msi-source-translated"


@dataclass(frozen=True)
class MSISnapshot:
    time_ms: int
    state: str
    run_kind: str | None
    destination: str | None
    temperature_raw: int
    done_pin: bool
    panel_enabled: bool
    panel_power_on: bool
    video_muted: bool
    deadline_ms: int | None
    led_phase: int
    off_elapsed_hours: int
    off_elapsed_minutes: int
    el_elapsed_hours: int
    el_elapsed_minutes: int
    off_run_count: int
    el_run_count: int
    factory_suppressed: bool
    unreachable_in_shipped_control_flow: bool
    evidence: str = "msi-source-translated"


def _integer(name, value, maximum=None):
    if (isinstance(value, bool) or not isinstance(value, int) or value < 0
            or (maximum is not None and value > maximum)):
        raise ValueError(f"{name} must be a non-negative integer"
                         + (f" <= {maximum}" if maximum is not None else ""))


class MSIPanelCareModel:
    def __init__(self):
        self._time_ms = 0
        self._state = "idle"
        self._run_kind = None
        self._destination = None
        self._temperature_raw = 0
        self._done_pin = False
        self._panel_enabled = True
        self._panel_power_on = True
        self._video_muted = False
        self._deadline_ms = None
        self._led_phase = 0
        self._off_elapsed_hours = self._off_elapsed_minutes = 0
        self._el_elapsed_hours = self._el_elapsed_minutes = 0
        self._off_run_count = self._el_run_count = 0
        self._factory_suppressed = False
        self._unreachable_in_shipped_control_flow = False

    def snapshot(self) -> MSISnapshot:
        return MSISnapshot(**{name: getattr(self, "_" + name)
                              for name in MSISnapshot.__dataclass_fields__
                              if name != "evidence"})

    def set_inputs(self, *, temperature_raw: int, done_pin: bool,
                   panel_enabled: bool) -> None:
        _integer("temperature_raw", temperature_raw, 65535)
        if not isinstance(done_pin, bool) or not isinstance(panel_enabled, bool):
            raise ValueError("done_pin and panel_enabled must be boolean")
        self._temperature_raw = temperature_raw
        self._done_pin = done_pin
        self._panel_enabled = panel_enabled

    def _validate_start(self, destination, factory_suppressed):
        if not isinstance(destination, str) or destination not in (
                "display", "power-save", "power-off"):
            raise ValueError("invalid destination")
        if not isinstance(factory_suppressed, bool):
            raise ValueError("factory_suppressed must be boolean")
        if self._state != "idle":
            raise ValueError("a sensing run is already active")

    def _event(self, events, kind, **detail):
        events.append(MSIEvent(self._time_ms, kind, self._state,
                               tuple(detail.items())))

    def _wait(self, state, delay):
        self._state = state
        self._deadline_ms = self._time_ms + delay

    def _write(self, events, register, value):
        if not self._panel_enabled:
            return
        self._event(events, "register-write", write=MSIRegisterWrite(
            register, (0, value), verify_readback=register == 0x0B2,
            attempts=10 if register == 0x0B2 else 1))

    def _read_temperature(self, events):
        if self._panel_enabled:
            self._event(events, "register-read", register=0x008,
                        payload=(self._temperature_raw >> 8,
                                 self._temperature_raw & 255))

    def _temperature_gate(self, events):
        # When disabled, firmware converts its existing read buffer. The input
        # then denotes that buffer; do not invent a fresh transaction.
        self._read_temperature(events)
        if self._temperature_raw // 16 > 45:
            self._event(events, "temperature-refused",
                        degrees=self._temperature_raw // 16)
            return False
        return True

    def start_off(self, *, destination: str,
                  factory_suppressed: bool = False) -> tuple[MSIEvent, ...]:
        self._validate_start(destination, factory_suppressed)
        self._run_kind = "off"
        self._destination = destination
        self._factory_suppressed = factory_suppressed
        self._unreachable_in_shipped_control_flow = False
        self._video_muted = True
        self._wait("off-rest", OFF_REST_MS)
        events = []
        self._event(events, "run-start", run_kind="off")
        self._event(events, "video-mute", muted=True)
        return tuple(events)

    def abort(self) -> tuple[MSIEvent, ...]:
        """Emit the stop-write boundary, without simulating QSM's entry delay.

        This method represents arrival at the guarded stop write, not entry
        into the separately recovered QSM state (which waits >1,000 ticks).
        It makes no claim that a panel discarded or committed sensing data.
        """
        if self._state == "idle":
            raise ValueError("no active sensing run")
        events = []
        if self._panel_enabled:
            self._write(events, 0x0C0, 0)
        self._event(events, "abort")
        self._state = "idle"
        self._deadline_ms = None
        return tuple(events)

    def start_latent_el_for_analysis(self, *, destination: str) -> tuple[MSIEvent, ...]:
        """Enter unreachable state 1 solely for analysis of the recovered body.

        The caller of state 1 is absent. Initial power-low and video-muted
        conditions are explicit analysis assumptions, not recovered writes.
        """
        self._validate_start(destination, False)
        self._run_kind = "latent-el"
        self._destination = destination
        self._factory_suppressed = False
        self._unreachable_in_shipped_control_flow = True
        self._panel_power_on = False
        self._video_muted = True
        self._led_phase = 0
        self._wait("el-first-rest", EL_FIRST_REST_MS)
        events = []
        self._event(events, "analysis-entry",
                    unreachable_in_shipped_control_flow=True,
                    assumed_panel_power_on=False, assumed_video_muted=True)
        return tuple(events)

    def _power(self, events, on):
        self._panel_power_on = on
        self._event(events, "panel-power", on=on)

    def _finish(self, events):
        counters = (("off_elapsed_hours", 0x0D), ("off_elapsed_minutes", 0x0B))
        if self._run_kind == "latent-el":
            counters = (("el_elapsed_hours", 0x0C), ("el_elapsed_minutes", 0x0A)) + counters
        for name, index in counters:
            setattr(self, "_" + name, 0)
            self._event(events, "counter-reset", counter=name, index=index, value=0)
        if self._run_kind == "latent-el":
            self._el_run_count += 1
            self._event(events, "run-count", counter="el_run_count",
                        index=0x0E, value=self._el_run_count)
        elif not self._factory_suppressed:
            self._off_run_count += 1
            self._event(events, "run-count", counter="off_run_count",
                        index=0x0F, value=self._off_run_count)
        self._event(events, "persistence", commit=1)
        self._event(events, "destination", destination=self._destination)
        self._state = "idle"
        self._deadline_ms = None

    def _observe_inputs(self, events):
        if self._state == "off-sensing" and self._done_pin:
            self._event(events, "done", register=0x0C0)
            self._wait("off-done-hold", DONE_HIGH_HOLD_MS)
        if self._state == "off-done-hold" and not self._done_pin:
            self._end_hold(events)
        if self._state in ("el-off-sensing", "el-sensing") and self._done_pin:
            is_off = self._state == "el-off-sensing"
            self._event(events, "done", register=0x0C0 if is_off else 0x0C2)
            if is_off:
                self._wait("el-power-down-settle", TRIGGER_SETTLE_MS)
            else:
                self._wait("el-led", LED_PHASE_MS)

    def _end_hold(self, events):
        self._event(events, "done-hold-finished")
        self._led_phase = 0
        self._wait("off-led", LED_PHASE_MS)

    def _transition(self, events):
        if self._state == "off-rest":
            if self._temperature_gate(events):
                self._write(events, 0x0B2, 0)
                self._wait("off-trigger-settle", TRIGGER_SETTLE_MS)
            else:
                self._destination = "power-off"
                # The hot path prints a second temperature read.
                self._read_temperature(events)
                self._wait("off-final-wait", FINAL_WAIT_MS)
        elif self._state == "off-trigger-settle":
            if self._panel_enabled:
                self._write(events, 0x0C0, 1)
            self._wait("off-sensing", OFF_TIMEOUT_MS)
        elif self._state == "off-sensing":
            self._event(events, "timeout", register=0x0C0, threshold_seconds=375)
            self._wait("off-done-hold", DONE_HIGH_HOLD_MS)
        elif self._state == "off-done-hold":
            self._end_hold(events)
        elif self._state == "off-led":
            self._led_phase += 1
            # Source increments 1..8; phase 8 advances substate before the
            # LED setter. Preserve that terminal interval, not an extra write.
            self._event(events, "led-phase", phase=self._led_phase,
                        setter_called=self._led_phase < 8,
                        rgb=(None if self._led_phase == 8 else
                             (0, 0, 0) if self._led_phase % 2 else (255, 16, 0)))
            if self._led_phase == 8:
                self._wait("off-final-wait", FINAL_WAIT_MS)
            else:
                self._wait("off-led", LED_PHASE_MS)
        elif self._state == "off-final-wait":
            self._finish(events)
        elif self._state == "el-first-rest":
            self._power(events, True)
            self._wait("el-first-warmup", EL_WARMUP_MS)
        elif self._state == "el-first-warmup":
            # Command and observed enable pin are distinct. Never fabricate
            # the pin's readback in response to this firmware-owned output.
            self._event(events, "panel-enable", enabled=True)
            if self._temperature_gate(events):
                self._write(events, 0x0B2, 0)
                self._wait("el-off-trigger-settle", TRIGGER_SETTLE_MS)
            else:
                self._destination = "power-off"
                self._read_temperature(events)
                self._wait("el-led", LED_PHASE_MS)
        elif self._state == "el-off-trigger-settle":
            self._write(events, 0x0C0, 1)
            # Unlike OFF, EL resets its counter BEFORE the trigger settle
            # (VA C0B4C), and does not reset again after its 0x0C0 write.
            self._wait("el-off-sensing", OFF_TIMEOUT_MS - TRIGGER_SETTLE_MS)
        elif self._state == "el-off-sensing":
            self._event(events, "timeout", register=0x0C0, threshold_seconds=375)
            self._wait("el-power-down-settle", TRIGGER_SETTLE_MS)
        elif self._state == "el-power-down-settle":
            self._power(events, False)
            self._wait("el-second-rest", EL_SECOND_REST_MS)
        elif self._state == "el-second-rest":
            self._power(events, True)
            self._wait("el-second-warmup", EL_WARMUP_MS)
        elif self._state == "el-second-warmup":
            self._event(events, "panel-enable", enabled=True)
            if self._temperature_gate(events):
                self._write(events, 0x0C2, 1)
                self._wait("el-sensing", EL_TIMEOUT_MS)
            else:
                # VA C0AF4 enters completion without changing destination.
                self._wait("el-led", LED_PHASE_MS)
        elif self._state == "el-sensing":
            self._event(events, "timeout", register=0x0C2, threshold_seconds=95)
            self._wait("el-led", LED_PHASE_MS)
        elif self._state == "el-led":
            # VA C07F8 clears power on EACH phase, including terminal phase 8.
            # The first 501-ms wait is the first LED interval, not an extra
            # half-second ahead of eight more intervals.
            self._power(events, False)
            self._led_phase += 1
            self._event(events, "led-phase", phase=self._led_phase,
                        setter_called=self._led_phase < 8,
                        rgb=(None if self._led_phase == 8 else
                             (0, 0, 0) if self._led_phase % 2 else (255, 255, 255)))
            if self._led_phase == 8:
                self._finish(events)
            else:
                self._wait("el-led", LED_PHASE_MS)

    def advance(self, *, milliseconds: int) -> tuple[MSIEvent, ...]:
        _integer("milliseconds", milliseconds)
        target = self._time_ms + milliseconds
        events = []
        self._observe_inputs(events)
        while self._deadline_ms is not None and self._deadline_ms <= target:
            self._time_ms = self._deadline_ms
            self._deadline_ms = None
            self._transition(events)
            self._observe_inputs(events)
        self._time_ms = target
        return tuple(events)
