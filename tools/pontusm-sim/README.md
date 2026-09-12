# PontusM OLED-protection simulator

A Python reconstruction of the published host-side QD-OLED protection logic in Samsung's 2022, 2023 and 2024 PontusM releases. It also models MSI MAG 341CQP scaler-side maintenance policy and compares supplied camera observations with official pixel-shift tables.

Start with the [research appendix](../../docs/evidence/oled-protection/README.md) for the findings and their limits. The [controlled comparison](../../docs/evidence/oled-protection/simulator-comparison.md) explains the scenario illustrated in the article.

## Scope

The simulator implements published integer operations, temporal state, regional-map processing, global-curve handling and pixel-shift index advancement. Image summaries and candidate regional gains are supplied by scenarios because their hardware producers are not published.

It does not emulate the MSI panel executable, calculate electrical compensation, measure wear or control a connected monitor. All commands below operate on local files. Synthetic fixture positions are not hardware observations.

## Requirements

- Python 3.11 or newer.
- No third-party Python packages.
- Official Samsung archives only for source verification and official-orbit comparisons. The [source report](../../docs/evidence/oled-protection/samsung-source.md) identifies the required releases and hashes.

## Commands

Run from the repository root:

```sh
export PYTHONPATH=tools/pontusm-sim
python3 -m pontusm_sim --help
```

Run one synthetic scenario:

```sh
python3 -m pontusm_sim run \
  tools/pontusm-sim/scenarios/static-desktop.json \
  --version 20 --output /tmp/pontusm-static
```

Compare v20 with v22:

```sh
python3 -m pontusm_sim compare \
  tools/pontusm-sim/scenarios/v22-local-delta.json \
  --from-version 20 --to-version 22 \
  --output /tmp/pontusm-version-comparison
```

Run the scenario collection:

```sh
python3 -m pontusm_sim run-all --output /tmp/pontusm-scenarios
```

Use a new destination for every run. Existing output directories are refused. Per-version results include a manifest, trace, summary, selected regional snapshots and a report. Comparison runs add combined differences. Digital duty values and internal strengths are not luminance percentages.

## Verify official sources

Download the archives independently from Samsung, then supply their paths:

```sh
python3 -m pontusm_sim verify-source /path/to/22_SmartMonitor_PontusM.zip --version 18
python3 -m pontusm_sim verify-source /path/to/23_DTV_PontusML.zip --version 20
python3 -m pontusm_sim verify-source /path/to/QNxxS95DAFXZA.zip --version 22
```

Verification checks the archive layers and relevant source members against pinned SHA-256 values. It parses data without executing vendor code. Full source files and vendor orbit tables are not redistributed in result bundles. Successful source verification establishes byte identity, not model accuracy.

## Compare the physical trace

The [camera report](../../docs/evidence/oled-protection/camera-measurement.md) describes the public measurements. The [orbit report](../../docs/evidence/oled-protection/orbit-comparison.md#reproduce-the-primary-comparison) provides the full replay command and expected results.

`compare-capture` accepts a capture manifest and hypotheses, with optional official archives. Results distinguish `consistent`, `contradicted` and `indeterminate`. Missing archives leave table-dependent hypotheses indeterminate. A matching cadence does not establish matching code.

The command emits `manifest.json`, `comparison.json`, `aligned.csv` and `report.md`. Use JSON for exact machine processing; CSV text fields are escaped for spreadsheet safety. Replay metadata includes the caller's input paths, so regenerated metadata can differ across checkouts while the comparison results agree.

## MSI maintenance model

```sh
python3 -m pontusm_sim msi-run \
  tools/pontusm-sim/msi-scenarios/off-early-done.json \
  --output /tmp/msi-off-model
```

The fixtures cover completion, timeout, temperature refusal, abort, VRR settings and a latent EL sequence. They simulate recovered scaler decisions. They neither invoke panel maintenance nor predict its electrical outcome. See the [model notes](docs/msi-source-map.md) for timing normalization and the latent sequence's reachability limit.

## Compare the curve controller with original C

An optional check compiles the original v20 `QD_FCN_CURVE_CTRL` function and compares its counter, gain and all 41 curve outputs with the Python reconstruction after every call. It requires a C11 compiler and the unmodified `QD_burn_in.c` extracted from the identified 2023 archive. Register writes are captured in memory; no monitor is accessed.

```sh
PYTHONPATH=tools/pontusm-sim python3 tools/pontusm-sim/validation/compare_fcn.py \
  --source /path/to/QD_burn_in.c --output /tmp/pontusm-fcn-check
```

Use `--cc clang` or another compiler executable if `cc` is unavailable. The [worked comparison](../../docs/evidence/oled-protection/simulator-comparison.md#checking-a-reconstruction-against-the-original-c) explains the inputs, checkpoints and limits. This check compiles and runs only the hash-pinned function; the separate `verify-source` command continues to parse archives without executing code.

## Tests

```sh
PYTHONPATH=tools/pontusm-sim python3 -m unittest discover -s tools/pontusm-sim/tests
```

Archive-dependent tests are skipped unless the corresponding environment variables are set:

```sh
export PONTUSM_2022_ARCHIVE=/path/to/22_SmartMonitor_PontusM.zip
export PONTUSM_2023_ARCHIVE=/path/to/23_DTV_PontusML.zip
export PONTUSM_2024_ARCHIVE=/path/to/QNxxS95DAFXZA.zip
PYTHONPATH=tools/pontusm-sim python3 -m unittest discover -s tools/pontusm-sim/tests
```

The tests cover model behavior, source identity, data validation and reproducible output. They do not establish that the unpublished MSI panel algorithm is identical to this implementation.
