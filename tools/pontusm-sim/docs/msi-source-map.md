# MSI maintenance model notes

The [public firmware report](../../../docs/evidence/oled-protection/firmware-boundary.md) identifies the analyzed device, firmware image and recovered interface. This page documents the simulator's interpretation of scaler timing.

## Model boundary

The model reconstructs scaler policy: maintenance eligibility, temperature refusal, completion polling, settings application and VRR suppression. Scenario inputs supply the panel's temperature and completion signal. The model does not calculate those signals from an electrical panel simulation.

Pixel-shift settings select enable and speed, not an image offset. The [physical measurement](../../../docs/evidence/oled-protection/camera-measurement.md) provides observed offsets separately. There is no numerical mapping from an MSI configuration byte to a PontusM regional gain.

## Timing interpretation

Counter increments are normalized to 1,000 ms. A test of `counter > N` becomes `(N + 1)` seconds relative to the appropriate counter reset. Strict tick guards of `>500` and `>550` become 501 and 551 ms, while a blocking 500-tick wait remains 500 ms.

This is a semantic reconstruction. It does not reproduce CPU scheduling or polling latency and should not be compared directly with camera timing as though it were cycle-accurate firmware execution.

## Latent EL sequence

The longer EL sequence has no identified production entry in the examined FW.028, FW.031, FW.035 and FW.041 control flows. It is available in the simulator only as a named analysis scenario. Its outputs are labeled `unreachable_in_shipped_control_flow`; they do not describe a monitor function the tool can activate.

## Interpreting results

Modeled completion establishes how the scaler would respond to the supplied input. It does not establish what compensation the panel performed, whether a partial cycle changed stored data, or how much wear was corrected. Those calculations remain outside the available implementation.
