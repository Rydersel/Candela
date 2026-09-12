# The MSI firmware boundary

[Evidence index](README.md) · Firmware analysis and device readback · September 11, 2026

## Finding

The MAG 341CQP's firmware update explains how MSI configures and schedules OLED Care. It does not contain the Samsung panel controller's executable, image detectors or electrical compensation calculations.

This distinction limits what can be concluded from the update: a command that enables taskbar detection identifies an interface, not the algorithm behind it.

![The scaler sends fixed panel-care commands to a separate Samsung controller.](assets/firmware-boundary.svg)

## Device and material examined

| Item | Identification |
| --- | --- |
| Monitor | MSI MAG 341CQP, 34-inch QD-OLED |
| Scaler firmware | 041 |
| Panel identifier returned by the monitor | `SDC QMC340CC01_D01` |
| Controller version returned by the monitor | `V70` |
| Firmware source | [MSI product support](https://www.msi.com/Monitor/MAG-341CQP-QD-OLED/support#firmware) |

SHA-256 of the analyzed firmware 041 image:

```text
69b75a1b67652a0fcfb20bda8de958a203784d70111a76740380b29fc7ebda59
```

Static analysis accounted for the populated firmware partitions and traced the OLED Care setting handlers to their panel transactions. Device readback separately confirmed the reported identities and configured settings. Readback does not expose internal detector state.

## What the update exposes

The analyzed image contains 53 recovered transactions to the panel controller at bus address `0x60`. Each uses a fixed register address. No general panel-memory read was found among those transactions.

| Register | Recovered role | What remains unknown |
| --- | --- | --- |
| `0x008` | Panel temperature input to maintenance policy | Sensor location and internal thermal control |
| `0x060` | Static-screen configuration | The panel's image classifier and dimming response |
| `0x070`, `0x072` | Pixel-shift enable and speed selection | Complete private orbit and implementation |
| `0x1B2` | Logo detection configuration | Detected regions and gain calculations |
| `0x1B4` | Boundary/pillar detection configuration | Detector state and regional processing |
| `0x1B6` | Taskbar detection configuration | Detector state and regional processing |
| `0x0C0` | OFF-sensing maintenance control | Electrical measurements and compensation-map updates |
| `0x0C2` | EL-sensing control in a latent sequence | Panel-side sensing implementation |

The scaler owns eligibility, temperature gates, completion polling and settings policy, including VRR-dependent suppression of regional controls. The longer EL sequence exists in the analyzed code but has no identified entry in the shipped control flow of the four examined releases. Its presence is not evidence that users can invoke it as an ordinary feature.

These are analysis results, not instructions for sending commands to a monitor.

## Worked example: the pixel-shift speed setting

The speed-setting path shows how a menu choice reaches the panel without exposing the panel's movement algorithm. The following instructions come from the firmware image identified above, decoded as big-endian SPARC. For these application addresses, add `0x108000` to the virtual address to find the byte offset in the downloaded `.bin` file.

The settings-application code calls the wrapper at virtual address `0x753E0`. The wrapper loads one byte from the settings structure and jumps to the setter:

```text
VA        Bytes     Instruction
000753e0  032a00b1  sethi 0x2a00b1, %g1
000753e4  d0086345  ldub [%g1+0x345], %o0
000753e8  030002fd  sethi 0x2fd, %g1
000753ec  81c0634c  jmp %g1+0x34c
000753f0  01000000  nop
```

The first pair reads address `0xA802C745`, which is the settings base `0xA802C56C` plus `0x1D9`. The second pair constructs the destination `0xBF400 + 0x34C = 0xBF74C`. This is a tail jump. A search for ordinary `call` instructions targeting the setter would miss it.

At `0xBF74C`, the setter builds a two-byte buffer containing zero followed by the selected speed. After checking panel state and logging the setting, it prepares the write:

```text
VA        Bytes     Instruction
000bf788  9a100011  mov %l1, %o5
000bf78c  92102002  mov 2, %o1
000bf790  94102072  mov 0x72, %o2
000bf794  96102005  mov 5, %o3
000bf798  98102000  mov 0, %o4
000bf79c  e423a05c  st %l2, [%sp+0x5c]
000bf7a0  40007f7d  call 0xdf594
000bf7a4  90102060  mov 0x60, %o0
```

Here `%o5` points to the buffer, `%o2` selects register `0x072`, and `%o0` supplies bus address `0x60`. SPARC executes the instruction immediately after a call before transferring control, so the final `mov` supplies the bus address in time. The following block reads back the same register. The setter also references the embedded string `OLED set PixelShift Speed %d` at file offset `0x260B40`, supporting the interpretation of this path.

The [annotated disassembly](data/pixel-shift-disassembly.txt) includes the caller, buffer construction and readback instructions omitted above, with both address forms. To check the displayed bytes against a separately obtained image:

```sh
shasum -a 256 MSI_MAG_341CQP_QD-OLED_FW.041_A019.bin
xxd -g 4 -s 0x17d3e0 -l 0x14 MSI_MAG_341CQP_QD-OLED_FW.041_A019.bin
xxd -g 4 -s 0x1c7788 -l 0x20 MSI_MAG_341CQP_QD-OLED_FW.041_A019.bin
```

This example establishes a live setting-to-register path. It does not independently establish the 53-transaction census, specify a shift interval, or reveal a sequence of image coordinates. The [camera measurement](camera-measurement.md) supplies the observed timing and positions separately.

## Independent readback

The monitor reported firmware 041, controller V70, the panel identifier above, Pixel Shift set to Fast and the regional protection settings enabled. These replies corroborate the recovered configuration interface. A setting reported as enabled does not establish that a detector is active on a particular frame or reveal the regions it has selected.

An earlier failure to obtain DDC replies was traced to an incorrect request checksum. Corrected reads worked repeatedly. The earlier interpretation that this monitor was write-only was therefore withdrawn.

## Scope of the negative result

The investigation checked the MSI update partitions, recovered public command tables and related vendor/source packages. It found neither an embedded panel executable nor a documented external memory-read route to the Samsung controller.

This is a bounded negative result. It does not establish that no service interface exists. A matching service image, fuller source release or independently identified controller dump could change it. Encryption of a downloadable update package does not establish how this controller stores code internally.

Physical behavior can still be measured without recovering that code. The [camera report](camera-measurement.md) documents pixel movement; the [orbit report](orbit-comparison.md) compares that movement with published tables. Neither exposes the panel's electrical compensation internals.
