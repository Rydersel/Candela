# Hardware-pass driver scripts

Small tools that let a person drive a hardware pass from a shell, committed so
the next pass does not re-derive them.

What each one exists for, and the measured fact behind it:

| script | what it does | why it is needed |
|---|---|---|
| `ax.sh` | Drives the settings window over the accessibility API: `nav <n>`, `title`, `dump`, `toggle <name>`, `pick <popup> <item>`, `items <popup>`, `statusicon` | The settings window is fully drivable; this is what makes most of a pass runnable unattended. `title` reads the window name back after a nav, because the sidebar index table is a property of the current build; `items` lists a pop-up's item names, because a size label carries whatever marks apply to it and a hard-coded one silently matches nothing |
| `mediakey.swift` | Posts a real brightness/volume media key, optionally with `--cmd`/`--opt`/`--ctrl`/`--shift` | Candela watches a head-insert event tap, which sees every event regardless of what is frontmost, so a posted media key reaches the app even though the terminal has focus. The modifiers reach the routes that need one (Cmd + brightness down is the mirroring panic press), but whether a synthetic modifier arrives at all is not assumed: post `--opt brightnessDown` and require System Settings to open before believing any modified press |
| `pointer.swift` | Lists display bounds; warps the pointer to a display's centre | Key targeting defaults to the display under the pointer, so this is how a press is aimed at a chosen panel |
| `gammaread.swift` | Reads back the loaded gamma table per display | The achieved state of the software dimming leg. No DDC readback can answer it, and the MAG cannot answer any readback at all |
| `axlabel.swift` | Every button's accessibility label, with absent distinguished from present-but-empty | AppleScript's `description` is not `AXDescription`, and enumerating attribute names omits it; only a direct read separates the two |
| `axprobe.swift` | `dump [filter]`: every element of the settings window. `press <label>`: the one element matching a label | `ax.sh` walks two levels of the detail pane, which does not reach a toggle nested in a captioned row, a countdown banner's Keep button, or a LabeledContent readout whose value is a sibling static text |
| `axw.swift` | The same walk, but bound to ONE window named on the command line: `<title-prefix> dump [filter]`, `press <desc> [--nth N]`, `value`, `inc`, `dec`, `frame` | `axprobe.swift` binds the first window that is not a named decoy, and `ax.sh` binds nothing at all, once a second window is legitimately open: the checkup flow and the keep/revert confirmation windows both coexist with settings. Naming the window is how a pass reads or presses inside the right one |
| `synthread.swift` | The independent readback for a mirror-synthesis pass: CoreGraphics geometry and mirror flags, the NSScreen roster and its scales, the ColorSync ledger | The app cannot read its own virtual display, so its claim about an engage is not evidence. Three instruments in one capture, each able to answer the achieved-state question on its own |


## The invariant core is `candela-probe regress` now

For the app-behaviour invariants these scripts were assembled into multi-leg
passes to prove (the combined-dimming propagation, the crossover, the sync
fan-out, the mute strand, the quiet wake, the panel's capabilities pair),
`candela-probe regress` supersedes the ad-hoc scripting: it carries the positive
control for each one, splits its verdict three ways rather than two, and writes
a machine-readable record of the run. Run it against the
deployed build rather than re-deriving one of those legs here.

The scripts remain the instruments. `regress` posts every key by running
`mediakey.swift` out of this folder (`--tools <dir>` when it cannot find it),
and it aims the pointer and reads the gamma table in process, which is the same
measurement `pointer.swift` and `gammaread.swift` make by hand. Everything
outside the invariant core still starts here: a leg nobody has written a check
for, a state a person has to see for themselves, and every pass where the
question is not yet sharp enough to be an invariant.

## Before driving the rig

Each script's own header carries its usage, the traps it encodes, and what it
cannot reach. Read the one you are about to run rather than inferring its
arguments from this table.

The discipline that decides whether any of it means anything is the positive
control: alongside the measurement, run something whose answer is already known.
A check that reports a pass when its subject is absent, its path is wrong or its
grep matches nothing is not a check, and every driver here has a way to fail
that quietly. The worked shape, from the Release debug-marker check: before
grepping a binary for a marker that must be absent, grep the same binary in the
same command for a literal you know is present. If the control comes back zero,
the tool or the path is wrong and the marker's zero means nothing. Write the
control next to the measurement it qualifies, every time.
