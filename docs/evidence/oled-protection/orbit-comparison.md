# Comparing the measured route with Samsung's orbit

[Evidence index](README.md) · Published-table comparison · September 11, 2026

## Finding

The 43-position MSI trace does not execute Samsung's published 1,956-position normal orbit from any cyclic starting index under the calibrated axes. The first three positions are enough to reject that specific hypothesis.

Later parts of the measured path coincide with segments of the published route. These matches are interesting evidence of common geometry, but they do not establish a shared implementation or explain the full MSI path.

## Primary comparison

The [camera measurement](camera-measurement.md) fixes the coordinate basis independently. The comparison allows the monitor to begin at any persisted index in the published table. It does not fit an axis transform, reverse direction or time warp to obtain a match.

| Observed position | Relative coordinate | Surviving starting indices |
| --- | --- | ---: |
| 1 | `(0, 0)` | 1,956 |
| 2 | `(0, 1)` | 1 |
| 3 | `(-1, 1)` | 0 |

After the second position, the sole remaining zero-based start index is 1955. Its next relative position would be `(1, 0)`, while the monitor moved to `(-1, 1)`.

The original retained comparison evaluated the official v18 and v20 normal tables. Later archive verification established that v22's normal table is identical, so the same contradiction applies. This does not mean the original comparison run independently tested three different algorithms.

The timing result is separate. The 42 relocated positions satisfy the declared 59.5–60.5-second cadence interval, including timestamp uncertainty. Agreement with that broad bound is consistent with the nominal one-minute interval; it is not evidence of code identity.

## Local matches

A subsequent segment search asked a different question: whether shorter parts of the paths coincide. These searches were performed after the full-route comparison and do not replace it.

| MSI positions | Published-route relationship | Observed continuation |
| --- | --- | --- |
| 22–43 | 22 consecutive positions under the calibrated axes and forward traversal | The recording ends at position 43, so continuation is unknown |
| 15–33 | 19 positions under reverse traversal from index 1882, translated to a common origin | At local position 20, MSI moves to `(3, -7)` while the published route would reach `(5, -7)` |

The reverse traversal is an analytical comparison, not a behavior demonstrated in Samsung's published runtime. The two segments use different indices, directions and translations and cannot be joined into one explanation of the full trace.

## Sensitivity checks

The additional [table diagnostics](data/table-diagnostics.json) enumerate the four available table shapes, all eight axis/sign mappings and forward/reverse traversal. No combination accounts for the full trace. Those broader checks address simple coordinate-convention alternatives; they are not the original fixed-axis hypothesis.

The result remains bounded to one monitor, configuration and partial route. It does not recover the full private orbit, establish why local segments match, or identify the implementations of logo detection and electrical compensation.

## Reproduce the primary comparison

Obtain the two matching official archives described in the [source report](samsung-source.md). From the repository root:

```sh
export PYTHONPATH=tools/pontusm-sim
python3 -m pontusm_sim compare-capture \
  docs/evidence/oled-protection/data/capture.json \
  --hypotheses docs/evidence/oled-protection/data/hypotheses.json \
  --archive-18 /path/to/22_SmartMonitor_PontusM.zip \
  --archive-20 /path/to/23_DTV_PontusML.zip \
  --artifact-epoch 2026-09-11T02:50:41Z \
  --output /tmp/oled-orbit-comparison
```

Use a new output directory. The expected outcomes are `contradicted` for both normal-orbit hypotheses and `consistent` for the apparent-cadence hypothesis. Without the archives, the table hypotheses remain `indeterminate`; the cadence comparison can still run.

The public manifest has rewritten acquisition notes and therefore a different hash from the working manifest. The observation bytes, coordinates, calibration and numerical hypothesis parameters are unchanged. Reproduction should agree on the results; manifest hashes and absolute replay paths will reflect the new publication location. The [provenance manifest](data/provenance.json) records that distinction.
