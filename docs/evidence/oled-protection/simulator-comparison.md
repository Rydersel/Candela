# Comparing two generations of protection logic

[Evidence index](README.md) · Controlled software simulation · September 11, 2026

## Finding

Under the same synthetic input, the reconstructed PontusM v20 and v22 algorithms produce different regional limits. At tick 1,100, v20 has reached local strength 512 with minimum regional duty 127. Version 22 reaches strength 1,020 with minimum duty 1.

These are internal digital quantities from a software model. They are not measured brightness, panel wear or the MSI monitor's output.

![Version 20 and version 22 diverge under identical candidate-map inputs.](assets/simulator-comparison.svg)

## What is being simulated

The [Python implementation](../../../tools/pontusm-sim/README.md) reconstructs the published integer operations, counters and state transitions from three [identified Samsung releases](samsung-source.md). It models the 225-region map, global-curve state, banner policy and pixel-shift index advancement. An additional module reconstructs MSI scaler maintenance policy.

Hardware-generated values are explicit scenario inputs. In particular, the simulator does not calculate the unpublished 2024 SRP candidate map. It also does not emulate the MSI panel executable or electrical compensation.

| Evidence class | Meaning in this comparison |
| --- | --- |
| Published logic | Integer operations, constants and temporal transitions translated from identified source |
| Supplied input | Image summaries and candidate regional gains that real hardware would produce |
| Unavailable | Candidate-map generator, exact MSI panel code and OFF/EL sensing calculations |

## Experimental input

The [version-delta scenario](../../../tools/pontusm-sim/scenarios/v22-local-delta.json) has four phases totaling 1,220 ticks. Both releases receive the same inputs for each phase.

| Phase | Duration | Purpose |
| --- | ---: | --- |
| Pattern knee | 1,100 ticks | Compare the normal-pattern threshold and accumulated local strength |
| Dark image | 10 ticks | Compare dark-image target handling |
| High menu / LPC | 40 ticks | Exercise menu strength and local-mask shaping |
| Factory exclusion | 70 ticks | Exercise v22's factory-mode exclusion and recovery |

For the first phase, row and column means are 100, maxima are 150, every candidate regional gain is zero, pattern probability is 769, image mean is 256, motion is false and logo brightness is Low. These values are a controlled stimulus, not statistics extracted from the camera recording.

The simulator records periodic checkpoints and phase boundaries. The chart shows the first phase. The downloadable tables retain the subsequent phases as well.

## Results

| Quantity at tick 1,100 | Version 20 | Version 22 |
| --- | ---: | ---: |
| Local target strength | 512 | 1,020 |
| Accumulated local strength | 512 | 1,020 |
| Minimum regional duty | 127 | 1 |

The comparison records 120 differences across its saved checkpoints, including availability flags and scalar fields. That count describes the report's coverage; it is not a confidence score or 120 independent experiments.

The result demonstrates why the phrase “Samsung's algorithm” is too broad without a release identifier. It does not establish which implementation runs inside the MSI.

## Reproduce

From the repository root, with Python 3.11 or newer:

```sh
export PYTHONPATH=tools/pontusm-sim
python3 -m pontusm_sim compare \
  tools/pontusm-sim/scenarios/v22-local-delta.json \
  --from-version 20 --to-version 22 \
  --output /tmp/oled-version-comparison
```

Use a destination that does not already exist. The comparison produces per-version traces, summaries and a combined report. This scenario runs without downloading vendor archives; source verification is a separate step described in the [source report](samsung-source.md).

The implementation's tests exercise reconstruction behavior. Passing tests alone cannot prove correspondence with hardware or rule out a shared mistake in a model and its expectations.

## Checking a reconstruction against the original C

For one independently executable check, I compared the v20 global dimming-curve controller with Samsung's original `QD_FCN_CURVE_CTRL` function. This is the retention-triggered curve discussed in the article, separate from the regional v20/v22 comparison above. The check uses lines 2241–2377 of the [identified 2023 source file](samsung-source.md#2023-retention-counter).

The [comparison program](../../../tools/pontusm-sim/validation/compare_fcn.py) verifies the complete source file's SHA-256, extracts those lines without changing the function, and compiles them with a small C wrapper. The wrapper supplies the retention flag and captures all 41 curve writes in memory. It replaces hardware addresses with array indices, supplies 32-bit unsigned state variables, and leaves debug mode disabled. No display is involved.

Both implementations start with a zero counter and zero gain. Each receives the same sequence: 18,000 asserted calls, seven clear calls, a 3,499-call near miss, a reset, a full 3,500-call rearm, and a final clear. The program compares the counter, gain and every curve point after every call. Expected values come from executing the original C function, rather than from a second transcription of its arithmetic.

All **25,008 calls** matched, including **1,025,328 curve values** and 50,016 counter/gain values. Selected checkpoints show the threshold and recovery:

| Call | Retention input | Counter | Gain | Final curve point |
| --- | --- | ---: | ---: | ---: |
| 3,499 | Asserted | 3,499 | 0 | 16,383 |
| 3,500 | Asserted | 3,500 | 1 | 16,382 |
| 17,899 | Asserted | 3,500 | 14,400 | 9,506 |
| 18,001 | Clear | 0 | 12,000 | 10,652 |
| 18,006 | Clear | 0 | 0 | 16,383 |
| 21,506 | Asserted, 3,499 calls since reset | 3,499 | 0 | 16,383 |
| 21,507 | Clear | 0 | 0 | 16,383 |

The first threshold crossing illustrates the translation. Source lines 2341–2352 increment the counter only while retention is asserted and reset it otherwise. At count 3,500, lines 2354–2366 select target gain 14,400 and advance the current gain by one. The final curve point then follows line 2372's integer interpolation:

```text
((16383 × (16384 − 1)) + (8559 × 1)) >> 14 = 16382
```

The [Python controller](../../../tools/pontusm-sim/pontusm_sim/curve.py) performs the same counter update, gain step and interpolation. At the gain limit, the final point is 9,506. Clearing retention resets the counter immediately and reduces gain by 2,400 per call, restoring the original curve in six calls. These are digital code values, not measured luminance.

To repeat the comparison, extract `QD_burn_in.c` from the 2023 archive using the [member path](samsung-source.md#locate-the-code), then run with Python 3.11 or newer and a C11 compiler:

```sh
export PYTHONPATH=tools/pontusm-sim
python3 tools/pontusm-sim/validation/compare_fcn.py \
  --source /path/to/QD_burn_in.c \
  --output /tmp/pontusm-fcn-check
```

The [saved result](data/fcn-comparison.json) records source and function hashes, the input phases, counts and a digest of the complete comparison trace. The [checkpoint table](data/fcn-checkpoints.csv) also includes saturation, each release step and rearming. `call` counts function invocations from one; `phase_call` restarts for each input phase. `curve_40` is the final point of the 41-point output. A mismatch or a different source hash makes the program fail.

This check supports the ordinary-mode FCN reconstruction over the stated inputs. It does not validate the upstream retention classifier, debug override, regional v20/v22 processing, hardware register effects or the unpublished MSI panel code. The 2024 worker no longer calls this function.

## Data supplement

- [Version 20 checkpoints](data/simulator-v20.csv)
- [Version 22 checkpoints](data/simulator-v22.csv)

`tick` identifies the simulated worker call, and `phase` identifies the stimulus. `local_target_strength` is the instantaneous target; `local_strength` is its temporally filtered state. `minimum_region_duty` is the lowest digital regional duty in that checkpoint. Availability flags distinguish retired paths from numerical zero. Empty fields mean the release does not provide that value.

The tables preserve the original saved values. Their hashes are recorded in the [publication manifest](data/provenance.json).
