"""Strict offline MSI scenarios using absolute semantic millisecond times.

Schema 1 requires name, firmware (041), initial settings/inputs, and actions.
Settings/inputs are complete initially; configure/set-inputs are nonempty
partial updates. Each action has at_ms and action plus only its named arguments.
Deadlines at at_ms run BEFORE that action; equal-time actions retain list order.
An input update is observed immediately via advance(0). Only one sensing run is
allowed; after completion/abort only advance actions may extend the timeline.
No external model is mutated: loading validates the entire schema before a
private lifecycle preflight, and execution always owns a fresh model.
"""

from dataclasses import dataclass, fields, replace
import hashlib
import json
from pathlib import Path

from .msi import MSIEvent, MSIPanelCareModel, MSISnapshot
from .msi_settings import MSIOLEDSettings, display_up_writes


_SETTING_FIELDS = frozenset(field.name for field in fields(MSIOLEDSettings))
_INPUT_FIELDS = frozenset(("temperature_raw", "done_pin", "panel_enabled", "vrr_active"))
_ACTIONS = {
    "advance": (set(), set()),
    "apply-settings": (set(), set()),
    "abort": (set(), set()),
    "set-inputs": ({"inputs"}, set()),
    "configure": ({"settings"}, set()),
    "start-off": ({"destination"}, {"factory_suppressed"}),
    "start-latent-el-for-analysis": ({"destination"}, set()),
}


@dataclass(frozen=True)
class MSIScenario:
    name: str
    firmware: str
    scenario_sha256: str
    document: bytes


@dataclass(frozen=True)
class MSIScenarioResult:
    scenario: MSIScenario
    events: tuple[MSIEvent, ...]
    final_state: MSISnapshot
    settings: MSIOLEDSettings
    vrr_active: bool

    @property
    def name(self) -> str:
        return self.scenario.name

    @property
    def scenario_sha256(self) -> str:
        return self.scenario.scenario_sha256


def _object(value, required, optional=(), *, context):
    if not isinstance(value, dict):
        raise ValueError(f"{context} must be an object")
    unknown = value.keys() - set(required) - set(optional)
    missing = set(required) - value.keys()
    if unknown or missing:
        raise ValueError(f"{context}: unknown fields {sorted(unknown)}; missing fields {sorted(missing)}")


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON field: {key}")
        value[key] = item
    return value


def _invalid_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


def _inputs(value, *, partial=False):
    _object(value, () if partial else _INPUT_FIELDS,
            _INPUT_FIELDS if partial else (), context="inputs")
    if not value:
        raise ValueError("inputs must not be empty")
    for key, item in value.items():
        if key == "temperature_raw":
            if type(item) is not int or not 0 <= item <= 65535:
                raise ValueError("temperature_raw must be an integer in 0...65535")
        elif type(item) is not bool:
            raise ValueError(f"{key} must be boolean")


def _prepare(raw):
    if not isinstance(raw, bytes):
        raise ValueError("scenario document must be bytes")
    data = json.loads(raw, object_pairs_hook=_pairs, parse_constant=_invalid_constant)
    _object(data, {"schema_version", "name", "firmware", "initial", "actions"}, context="scenario")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        raise ValueError("schema_version must be 1")
    if not isinstance(data["name"], str) or not data["name"].strip():
        raise ValueError("name must be a non-empty string")
    if data["firmware"] != "041":
        raise ValueError("firmware must be 041 (the modeled semantic target)")
    _object(data["initial"], {"settings", "inputs"}, context="initial")
    _object(data["initial"]["settings"], _SETTING_FIELDS, context="settings")
    settings = MSIOLEDSettings(**data["initial"]["settings"])
    settings.validate()
    _inputs(data["initial"]["inputs"])
    if not isinstance(data["actions"], list) or not data["actions"]:
        raise ValueError("actions must be a non-empty array")
    previous = 0
    for action in data["actions"]:
        _object(action, {"at_ms", "action"},
                {"inputs", "settings", "destination", "factory_suppressed"}, context="action")
        name = action["action"]
        if not isinstance(name, str) or name not in _ACTIONS:
            raise ValueError("unsupported action; latent EL requires start-latent-el-for-analysis")
        required, optional = _ACTIONS[name]
        _object(action, {"at_ms", "action"} | required, optional, context=name)
        at = action["at_ms"]
        if type(at) is not int or at < previous:
            raise ValueError("at_ms must be a non-negative monotonic integer")
        previous = at
        if "destination" in action:
            if not isinstance(action["destination"], str) or action["destination"] not in (
                    "display", "power-save", "power-off"):
                raise ValueError("invalid destination")
        if "factory_suppressed" in action and type(action["factory_suppressed"]) is not bool:
            raise ValueError("factory_suppressed must be boolean")
        if name == "set-inputs":
            _inputs(action["inputs"], partial=True)
        elif name == "configure":
            _object(action["settings"], (), _SETTING_FIELDS, context="settings")
            if not action["settings"]:
                raise ValueError("settings update must not be empty")
            settings = replace(settings, **action["settings"])
            settings.validate()
    return MSIScenario(data["name"], data["firmware"],
                       hashlib.sha256(raw).hexdigest(), raw), data


def load_msi_scenario(path: str | Path) -> MSIScenario:
    """Read exact bytes, validate all fields, then preflight the run lifecycle."""
    scenario, data = _prepare(Path(path).read_bytes())
    _execute(scenario, data)
    return scenario


def run_msi_scenario(scenario: MSIScenario) -> MSIScenarioResult:
    """Return immutable events and configured state from a private model."""
    if not isinstance(scenario, MSIScenario):
        raise ValueError("scenario must be a loaded MSIScenario")
    checked, data = _prepare(scenario.document)
    if checked != scenario:
        raise ValueError("scenario metadata does not match its document")
    return _execute(checked, data)


def _execute(scenario, data):
    model = MSIPanelCareModel()
    settings = MSIOLEDSettings(**data["initial"]["settings"])
    inputs = dict(data["initial"]["inputs"])
    model.set_inputs(**{key: value for key, value in inputs.items() if key != "vrr_active"})
    events = []
    started = False
    for action in data["actions"]:
        events.extend(model.advance(milliseconds=action["at_ms"] - model.snapshot().time_ms))
        name = action["action"]
        if started and model.snapshot().state == "idle" and name != "advance":
            raise ValueError("completed or aborted run cannot be mutated or restarted")
        if name == "start-off":
            events.extend(model.start_off(destination=action["destination"],
                                         factory_suppressed=action.get("factory_suppressed", False)))
            started = True
        elif name == "start-latent-el-for-analysis":
            events.extend(model.start_latent_el_for_analysis(destination=action["destination"]))
            started = True
        elif name == "abort":
            events.extend(model.abort())
        elif name == "set-inputs":
            inputs.update(action["inputs"])
            model.set_inputs(**{key: value for key, value in inputs.items() if key != "vrr_active"})
            events.extend(model.advance(milliseconds=0))
        elif name == "configure":
            settings = replace(settings, **action["settings"])
        elif name == "apply-settings" and inputs["panel_enabled"]:
            snapshot = model.snapshot()
            events.extend(MSIEvent(snapshot.time_ms, "register-write", snapshot.state,
                                   (("write", write),))
                          for write in display_up_writes(settings, vrr_active=inputs["vrr_active"]))
    return MSIScenarioResult(scenario, tuple(events), model.snapshot(), settings, inputs["vrr_active"])
