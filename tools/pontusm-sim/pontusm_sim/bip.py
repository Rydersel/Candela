"""Deterministic model of PontusM BIP/pixel-shift host-side policy.

Orbit coordinates are supplied by the caller.  This module intentionally
contains no Samsung orbit table and does not model unavailable panel wear or
electrical-compensation behavior.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Sequence

from .types import AlgorithmVersion, Fidelity


Orbit = tuple[int, int]

QD_TICK_MILLISECONDS = 20
BIP_INTERVAL_MILLISECONDS = 60_000
DEFAULT_INTERVAL_TICKS = BIP_INTERVAL_MILLISECONDS // QD_TICK_MILLISECONDS
PERSISTENCE_ADVANCE_INTERVAL = 10

_SOURCE_18 = "2022 sdp_pqe_dp/dp/pontusm/sdp_pqe_bip.c"
_SOURCE_20 = "2023 sdp_pqe_dp/pontusm/sdp_pqe_bip.c"
_SOURCE_22 = "2024 sdp_pqe_dp/pontusm/sdp_pqe_bip.c"
_SOURCE_THREAD_20 = "2023 sdp_pqe_dp/pontusm/sdp_pqe_thrd.c:136-143"
_SOURCE_THREAD_22 = "2024 sdp_pqe_dp/pontusm/sdp_pqe_thrd.c:136-143"


class BIPTable(str, Enum):
    NORMAL = "normal"
    ROTATED = "rotated"
    ENGINEERING = "engineering"


class BIPAction(str, Enum):
    MOVE = "move"
    PRIME = "prime"
    MODE = "mode"
    PERSIST = "persist"
    ROTATION = "rotation"
    ENGINEERING = "engineering"
    FACTORY_RESET = "factory-reset"
    RESTORE = "restore"
    GEOMETRY_RESET = "geometry-reset"


class BIPState(str, Enum):
    IDLE = "idle"
    TRACE_LAST_POSITION = "trace-last-position"
    RUN = "run"


@dataclass(frozen=True)
class BIPEvent:
    """One reportable BIP transition with its fidelity classification.

    For ``PRIME``, ``position`` is the selected trace target; it is not an
    applied position and therefore does not replace
    ``BIPModel.current_position``.
    """

    tick: int
    action: BIPAction
    reason: str
    table: BIPTable
    selected_index: int
    next_index: int
    position: Orbit | None = None
    persisted_state: str | None = None
    fidelity: Fidelity = Fidelity.SOURCE_TRANSLATED
    source_reference: str = ""


@dataclass(frozen=True)
class BIPSnapshot:
    tick: int
    elapsed_ticks: int
    enabled: bool
    rotation: bool
    index: int
    current_position: Orbit | None
    active_table: BIPTable
    state: BIPState
    advances_since_persist: int
    output_geometry: tuple[int, int]


class BIPModel:
    """Stateful BIP model driven by nominal 20 ms simulator ticks.

    ``normal``, ``engineering``, and ``rotated`` are runtime inputs so official
    tables stay outside the repository.  Table selection, cadence, index
    advancement, and persistence policy are source-translated.
    """

    def __init__(
        self,
        normal: Sequence[Orbit],
        engineering: Sequence[Orbit],
        *,
        rotated: Sequence[Orbit] | None = None,
        interval_ticks: int = DEFAULT_INTERVAL_TICKS,
        version: AlgorithmVersion | int | str = AlgorithmVersion.V20,
        initial_geometry: tuple[int, int] = (0, 0),
    ) -> None:
        self._normal = self._validate_table("normal", normal)
        self._engineering = self._validate_table("engineering", engineering)
        self._rotated = (
            None if rotated is None else self._validate_table("rotated", rotated)
        )
        if (
            not isinstance(interval_ticks, int)
            or isinstance(interval_ticks, bool)
            or interval_ticks <= 0
        ):
            raise ValueError("interval_ticks must be a positive integer")

        self.version = AlgorithmVersion.parse(version)
        self._output_geometry = self._validate_geometry(initial_geometry)
        self.interval_ticks = interval_ticks
        self.tick = 0
        self._elapsed_ticks = 0
        self.enabled = False
        self.rotation = False
        self.index = 0
        self.current_position: Orbit | None = None
        self.state = BIPState.IDLE
        self._advances_since_persist = 0

    @staticmethod
    def _validate_geometry(geometry: tuple[int, int]) -> tuple[int, int]:
        if (
            not isinstance(geometry, tuple)
            or len(geometry) != 2
            or any(
                not isinstance(value, int)
                or isinstance(value, bool)
                or not 0 <= value <= 0xFFFF_FFFF
                for value in geometry
            )
        ):
            raise ValueError("geometry must be a pair of unsigned 32-bit integers")
        return geometry

    @staticmethod
    def _validate_table(name: str, table: Sequence[Orbit]) -> tuple[Orbit, ...]:
        if isinstance(table, (str, bytes)) or not table:
            raise ValueError(f"{name} orbit table must not be empty")
        result: list[Orbit] = []
        for entry in table:
            try:
                horizontal, vertical = entry
            except (TypeError, ValueError):
                raise ValueError(
                    f"{name} orbit table entries must be pairs of integers"
                ) from None
            if any(
                not isinstance(value, int) or isinstance(value, bool)
                for value in (horizontal, vertical)
            ):
                raise ValueError(
                    f"{name} orbit table entries must be pairs of integers"
                )
            result.append((horizontal, vertical))
        return tuple(result)

    @property
    def active_table(self) -> BIPTable:
        return BIPTable.ROTATED if self.rotation else BIPTable.NORMAL

    def snapshot(self) -> BIPSnapshot:
        return BIPSnapshot(
            tick=self.tick,
            elapsed_ticks=self._elapsed_ticks,
            enabled=self.enabled,
            rotation=self.rotation,
            index=self.index,
            current_position=self.current_position,
            active_table=self.active_table,
            state=self.state,
            advances_since_persist=self._advances_since_persist,
            output_geometry=self._output_geometry,
        )

    def _table(self, selection: BIPTable) -> tuple[Orbit, ...]:
        if selection is BIPTable.NORMAL:
            return self._normal
        if selection is BIPTable.ENGINEERING:
            return self._engineering
        if self._rotated is None:
            raise ValueError("rotation requires a rotated orbit table")
        return self._rotated

    def _source(
        self,
        version_18_lines: str,
        version_20_lines: str,
        version_22_lines: str | None = None,
    ) -> str:
        if self.version is AlgorithmVersion.V18:
            return f"{_SOURCE_18}:{version_18_lines}"
        if self.version is AlgorithmVersion.V22:
            return (
                _SOURCE_22
                if version_22_lines is None
                else f"{_SOURCE_22}:{version_22_lines}"
            )
        return f"{_SOURCE_20}:{version_20_lines}"

    def _event(
        self,
        action: BIPAction,
        reason: str,
        *,
        tick: int | None = None,
        table: BIPTable | None = None,
        selected_index: int | None = None,
        position: Orbit | None = None,
        persisted_state: str | None = None,
        source_reference: str,
    ) -> BIPEvent:
        selection = self.active_table if table is None else table
        index = self.index if selected_index is None else selected_index
        return BIPEvent(
            tick=self.tick if tick is None else tick,
            action=action,
            reason=reason,
            table=selection,
            selected_index=index,
            next_index=self.index,
            position=position,
            persisted_state=persisted_state,
            source_reference=source_reference,
        )

    def _persist_event(self, reason: str, index: int, tick: int | None = None) -> BIPEvent:
        return self._event(
            BIPAction.PERSIST,
            reason,
            tick=tick,
            selected_index=index,
            persisted_state=self.serialize_state(index=index),
            source_reference=self._source("151-162,553-584", "158-170,586-617"),
        )

    def _select_current_position(
        self, action: BIPAction, reason: str, tick: int
    ) -> tuple[BIPEvent, ...]:
        selection = self.active_table
        table = self._table(selection)
        selected_index = self.index
        position = table[selected_index]
        self.index = (selected_index + 1) % len(table)
        if action is BIPAction.MOVE:
            self.current_position = position
        self._advances_since_persist += 1

        if action is BIPAction.PRIME:
            source_reference = self._source(
                "452-489,586-630", "485-522,619-663"
            )
        else:
            source_reference = self._source(
                "568-630,672-680", "601-663,705-713"
            )
        if reason.startswith("cadence"):
            thread_source = (
                _SOURCE_THREAD_22
                if self.version is AlgorithmVersion.V22
                else _SOURCE_THREAD_20
            )
            source_reference = f"{source_reference}; {thread_source}"

        events = [
            self._event(
                action,
                reason,
                tick=tick,
                table=selection,
                selected_index=selected_index,
                position=position,
                source_reference=source_reference,
            )
        ]
        if self._advances_since_persist == PERSISTENCE_ADVANCE_INTERVAL:
            self._advances_since_persist = 0
            events.append(self._persist_event("periodic", selected_index, tick))
        return tuple(events)

    def _apply_current_position(self, reason: str, tick: int) -> tuple[BIPEvent, ...]:
        return self._select_current_position(BIPAction.MOVE, reason, tick)

    def _prime_current_position(self, tick: int) -> tuple[BIPEvent, ...]:
        self.state = BIPState.RUN
        return self._select_current_position(
            BIPAction.PRIME, "cadence-prime", tick
        )

    def step(self, ticks: int = 1) -> tuple[BIPEvent, ...]:
        """Advance QD ticks and return moves at each BIP cadence boundary."""
        if not isinstance(ticks, int) or isinstance(ticks, bool) or ticks <= 0:
            raise ValueError("ticks must be a positive integer")

        start_tick = self.tick
        first_boundary = self.interval_ticks - self._elapsed_ticks
        total = self._elapsed_ticks + ticks
        boundary_count, self._elapsed_ticks = divmod(total, self.interval_ticks)
        self.tick += ticks

        events: list[BIPEvent] = []
        for offset in range(boundary_count):
            event_tick = start_tick + first_boundary + (offset * self.interval_ticks)
            if self.enabled:
                if self.state is BIPState.IDLE:
                    events.extend(self._prime_current_position(event_tick))
                else:
                    events.extend(self._apply_current_position("cadence", event_tick))
        return tuple(events)

    def set_enabled(self, enabled: bool) -> tuple[BIPEvent, ...]:
        if not isinstance(enabled, bool):
            raise ValueError("enabled must be boolean")
        if enabled == self.enabled:
            return ()

        self.enabled = enabled
        if not enabled:
            self.current_position = None
            self.state = BIPState.IDLE

        events: list[BIPEvent] = [
            self._event(
                BIPAction.MODE,
                "enabled" if enabled else "disabled",
                source_reference=self._source("408-421,861-919", "441-454,899-956"),
            ),
            self._persist_event("mode", self.index),
        ]
        if enabled:
            if self.version is AlgorithmVersion.V18:
                table = self._table(self.active_table)
                skipped_index = self.index
                self.index = (self.index + 1) % len(table)
                self._advances_since_persist += 1
                if self._advances_since_persist == PERSISTENCE_ADVANCE_INTERVAL:
                    self._advances_since_persist = 0
                    events.append(self._persist_event("periodic", skipped_index))
            events.extend(self._apply_current_position("enabled", self.tick))
        return tuple(events)

    def set_rotation(self, rotation: bool) -> tuple[BIPEvent, ...]:
        if not isinstance(rotation, bool):
            raise ValueError("rotation must be boolean")
        if rotation == self.rotation:
            return ()
        if self.version is AlgorithmVersion.V18:
            raise ValueError("rotation is available only for version 20 or 22")
        if rotation and self._rotated is None:
            raise ValueError("rotation requires a rotated orbit table")

        self.rotation = rotation
        self.index = 0
        self.current_position = None
        self.state = BIPState.IDLE
        events = (
            self._event(
                BIPAction.ROTATION,
                "rotation-on" if rotation else "rotation-off",
                source_reference=self._source("unavailable", "1095-1118"),
            ),
            self._persist_event("rotation", 0),
        )
        return events

    def engineering_verify(self, index: int) -> BIPEvent:
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or not 0 <= index < len(self._engineering)
        ):
            raise ValueError("engineering index is outside the EW orbit table")
        return self._event(
            BIPAction.ENGINEERING,
            "engineering-verification",
            table=BIPTable.ENGINEERING,
            selected_index=index,
            position=self._engineering[index],
            source_reference=self._source("986-991", "372-392,1026-1031"),
        )

    def resume(self) -> tuple[BIPEvent, ...]:
        self.current_position = None
        self.state = BIPState.IDLE
        if not self.enabled:
            return ()
        return self._apply_current_position("resume", self.tick)

    def notify_frc_unmute(
        self, output_den_line: int, output_den_pixel: int
    ) -> tuple[BIPEvent, ...]:
        """Apply v22's FRC-unmute output-geometry guard.

        The published notifier clears the applied offset and returns the state
        machine to IDLE when output-DEN geometry changed while BIP is enabled.
        It does not change the selected mode or table index.
        """
        if self.version is not AlgorithmVersion.V22:
            raise ValueError(
                "FRC unmute geometry handling is available only for version 22"
            )
        geometry = self._validate_geometry((output_den_line, output_den_pixel))
        if not self.enabled:
            return ()
        changed = geometry != self._output_geometry
        self._output_geometry = geometry
        if not changed:
            return ()
        self.current_position = None
        self.state = BIPState.IDLE
        return (
            self._event(
                BIPAction.GEOMETRY_RESET,
                "frc-unmute-geometry-change",
                source_reference=self._source(
                    "unavailable", "unavailable", "206-264"
                ),
            ),
        )

    def factory_reset(self) -> tuple[BIPEvent, ...]:
        self.enabled = False
        self.index = 0
        self.current_position = None
        self.state = BIPState.IDLE
        return (
            self._event(
                BIPAction.FACTORY_RESET,
                "factory-reset",
                source_reference=self._source("861-880", "899-919"),
            ),
            self._persist_event("factory-reset", 0),
        )

    def serialize_state(self, *, index: int | None = None) -> str:
        stored_index = self.index if index is None else index
        table = self._table(self.active_table)
        if (
            not isinstance(stored_index, int)
            or isinstance(stored_index, bool)
            or not 0 <= stored_index < len(table)
        ):
            raise ValueError("persisted index is outside the active orbit table")

        mode = 2 if self.enabled else 0
        if self.version is AlgorithmVersion.V18:
            return f"@mode\n{mode}\n@index\n{stored_index}\n@done\n"
        rotation = 1 if self.rotation else 0
        return (
            f"@mode\n{mode}\n@index\n{stored_index}\n"
            f"@rot\n{rotation}\n@done\n"
        )

    def restore_state(self, document: str) -> tuple[BIPEvent, ...]:
        """Validate a persisted document completely before changing state.

        The 2023 C parser accepts every successfully parsed ``u32`` index due
        to an unsigned ``>= 0`` check.  The simulator deliberately validates
        against the selected runtime table so malformed scenarios fail before
        mutation instead of emulating an out-of-bounds persisted state.
        """
        if not isinstance(document, str):
            raise ValueError("persisted state must be text")
        lines = document.splitlines()
        expected_tags = (
            ("@mode", "@index", "@done")
            if self.version is AlgorithmVersion.V18
            else ("@mode", "@index", "@rot", "@done")
        )
        expected_length = 5 if self.version is AlgorithmVersion.V18 else 7
        if len(lines) != expected_length or tuple(lines[0::2]) != expected_tags:
            raise ValueError("persisted state has invalid tags or version format")

        mode = self._parse_u32(lines[1], "mode")
        index = self._parse_u32(lines[3], "index")
        if mode not in (0, 1, 2):
            raise ValueError("persisted mode must be 0, 1, or 2")

        rotation = False
        if self.version is not AlgorithmVersion.V18:
            rotation_value = self._parse_u32(lines[5], "rotation")
            if rotation_value not in (0, 1):
                raise ValueError("persisted rotation must be 0 or 1")
            rotation = bool(rotation_value)
            if rotation and self._rotated is None:
                raise ValueError("persisted rotation requires a rotated orbit table")

        selection = BIPTable.ROTATED if rotation else BIPTable.NORMAL
        table = self._table(selection)
        if index >= len(table):
            raise ValueError("persisted index is outside the selected orbit table")

        self.enabled = mode != 0
        self.rotation = rotation
        self.index = index
        self.current_position = None
        self.state = BIPState.IDLE
        self._elapsed_ticks = 0
        self._advances_since_persist = 0
        return (
            self._event(
                BIPAction.RESTORE,
                "restore",
                table=selection,
                selected_index=index,
                source_reference=self._source(
                    "126-149,1008-1025", "130-156,1048-1070"
                ),
            ),
        )

    @staticmethod
    def _parse_u32(value: str, name: str) -> int:
        if not value.isdecimal():
            raise ValueError(f"persisted {name} must be an unsigned decimal integer")
        result = int(value, 10)
        if result > 0xFFFF_FFFF:
            raise ValueError(f"persisted {name} exceeds u32")
        return result


BIP_SOURCE_FIDELITY = (
    (
        "cadence",
        Fidelity.SOURCE_TRANSLATED,
        (
            f"{_SOURCE_THREAD_20}; {_SOURCE_THREAD_22}; "
            "2023/2024 sdp_pqe_dp/pontusm/sdp_pqe_bip.h:26"
        ),
    ),
    (
        "orbit-values",
        Fidelity.SOURCE_ABSTRACTED,
        "runtime-supplied official-source sequences; no full tables are embedded",
    ),
    (
        "idle-prime",
        Fidelity.SOURCE_TRANSLATED,
        f"{_SOURCE_18}:452-489; {_SOURCE_20}:485-522; {_SOURCE_22}:485-522",
    ),
    (
        "crop-and-electrical-compensation",
        Fidelity.UNAVAILABLE,
        "crop is disabled by the inspected host source; OFF/EL behavior is outside it",
    ),
)
