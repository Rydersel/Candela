# What an OLED monitor does to protect itself

**Research evidence · MSI MAG 341CQP · September 2026**

This appendix supports *I built an OLED protection app, then reverse-engineered my monitor*. It presents the firmware findings, source comparison and physical measurements separately so that each claim can be checked against the evidence that supports it.

The investigation found a boundary between the MSI scaler and the Samsung panel controller, reconstructed published protection logic from three Samsung releases, and measured 43 successive image positions on the real monitor. The measured route does not execute the published Samsung normal orbit, although parts of the paths coincide.

## Read the evidence

| Report | Question answered | Evidence and result |
| --- | --- | --- |
| [MSI firmware boundary](firmware-boundary.md) | What does the monitor's update reveal? | Firmware 041 exposes fixed panel-care commands and scheduling. The panel executable and compensation calculations remain unavailable. |
| [Samsung source provenance](samsung-source.md) | Which code was examined? | Official 2022, 2023 and 2024 archives, identified by release records, member paths and hashes. They are related production code, not the MSI panel executable. |
| [Simulator comparison](simulator-comparison.md) | Do adjacent releases behave differently under the same inputs? | A controlled scenario reaches local strength 512 in v20 and 1,020 in v22. This is a model result, not a luminance measurement. |
| [Camera measurement](camera-measurement.md) | How was physical pixel movement measured? | Same-recording calibration and a stationary reference yield 43 positions and 42 relocations, with an apparent interval of about 60.134 seconds. |
| [Orbit comparison](orbit-comparison.md) | Does the measured path follow Samsung's table? | Every cyclic starting index is rejected by the third position under the calibrated axes. Later local matches do not establish full-route identity. |

## What the findings support

Desktop software and the monitor have complementary capabilities. The operating system can use lock, idle and window context to avoid showing unnecessary content. The display can move the final image and access physical panel state. These findings clarify the role of each layer; they do not measure Candela's effect on burn-in or panel life.

## Reproduce or inspect

The [simulator](../../../tools/pontusm-sim/README.md) runs locally with Python 3.11 or newer. Synthetic scenarios do not require vendor archives. Official-table comparisons require independently obtained Samsung archives matching the [source report](samsung-source.md).

The reports link to small data supplements with column definitions and reproduction instructions. Original measurement records are retained without changing their values. The [provenance manifest](data/provenance.json) identifies the source recording and records the publication's file hashes and formatting changes.

For two worked checks, follow the [pixel-shift setting through the firmware instructions](firmware-boundary.md#worked-example-the-pixel-shift-speed-setting), or [compare the original C curve controller with its Python reconstruction](simulator-comparison.md#checking-a-reconstruction-against-the-original-c). The latter requires a C11 compiler and the separately obtained 2023 source file.

The original 4.59 GB recording is not distributed. The camera report explains which results can be checked from the published data and which require original footage or a new acquisition. No vendor firmware binaries, complete Samsung source files or full vendor orbit tables are included.

[Back to Candela](../../../README.md)
