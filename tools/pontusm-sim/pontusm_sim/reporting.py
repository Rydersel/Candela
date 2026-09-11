"""Adapter from scenario results to deterministic artifact bundles."""

from __future__ import annotations

from collections import defaultdict
from os import PathLike
from typing import Mapping

from .artifacts import (
    ArtifactConfig,
    BundleDigests,
    RunMetadata,
    TickRecord,
    write_bundle,
)
from .scenario import ScenarioResult


DEFAULT_METRICS = (
    "retention",
    "retention_available",
    "retention_count",
    "fcn_gain",
    "fcn_available",
    "local_strength",
    "local_target_strength",
    "minimum_region_duty",
    "app_counter",
    "app_duty",
    "anti_residue",
    "srp_center_mask_gain",
    "srp_board_mask_gain",
    "flat",
    "standard_pattern",
    "hdr_color_pattern",
    "banner_probability",
    "banner_history",
    "screen_saver_off",
    "isp_off",
    "policy_state",
)


def write_result_bundle(
    result: ScenarioResult,
    output_directory: str | PathLike[str],
    *,
    source_hashes: Mapping[str, str],
    command: tuple[str, ...] = (),
    artifact_epoch: str = "2026-09-10T00:00:00Z",
    fidelity_caveats: tuple[str, ...] = (),
) -> BundleDigests:
    """Serialize one QD result using a caller-controlled stable epoch."""

    events: dict[int, list[str]] = defaultdict(list)
    for event in result.events:
        events[int(event["tick"])].append(str(event["event"]))
    regions = {int(snapshot["tick"]): snapshot for snapshot in result.regions}

    records: list[TickRecord] = []
    for sample in result.samples:
        tick = int(sample["tick"])
        snapshot = regions.get(tick)
        records.append(
            TickRecord(
                tick=tick,
                phase=str(sample["phase"]),
                metrics={name: sample[name] for name in DEFAULT_METRICS},
                event=",".join(events[tick]) or None,
                checkpoint=(None if snapshot is None else str(snapshot["snapshot"])),
                regions=(
                    None
                    if snapshot is None
                    else tuple(int(value) for value in snapshot["duties"])
                ),
            )
        )

    caveats = (
        "The 225 candidate regional gains and hardware statistics are scenario inputs, not reconstructed register-generation logic; in v22 these gains are the source-abstracted 24Y_SRP output.",
        "Source-comment durations and nominal 20 ms scheduler calculations may differ; ticks are authoritative in this simulator.",
        *fidelity_caveats,
    )
    return write_bundle(
        output_directory,
        RunMetadata(
            created_at=artifact_epoch,
            model_version=result.version,
            scenario_name=result.name,
            scenario_sha256=result.scenario_sha256,
            source_archive_hashes=source_hashes,
            command=command,
            fidelity_caveats=caveats,
        ),
        ArtifactConfig(summary_metrics=DEFAULT_METRICS, region_value_name="duty"),
        records,
    )
