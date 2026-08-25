# Hardware-pass driver scripts

Small tools that let an agent (or a person) drive a hardware pass from a shell.
The first four were written during Checkpoint 1 §6 session 3 (2026-08-11) and
committed so the next pass does not re-derive them; the synthesis set was added
for #186 on 2026-08-18. **Placement is provisional**: if the reusable-playbook
work lands, these are its seed and should move wherever it puts them.

What each one exists for, and the measured fact behind it:

| script | what it does | why it is needed |
|---|---|---|
| `ax.sh` | Drives the settings window over the accessibility API: `nav <n>`, `title`, `dump`, `toggle <name>`, `pick <popup> <item>`, `items <popup>`, `statusicon` | The settings window is fully drivable; this is what made most of §6 runnable unattended. `title` reads the window name back after a nav, because the sidebar index table is a property of the current build; `items` lists a pop-up's item names, because a size label carries whatever marks apply to it and a hard-coded one silently matches nothing |
| `mediakey.swift` | Posts a real brightness/volume media key, optionally with `--cmd`/`--opt`/`--ctrl`/`--shift` | Candela watches a head-insert event tap, which sees every event regardless of what is frontmost, so a posted media key reaches the app even though the terminal has focus. The modifiers reach the routes that need one (Cmd + brightness down is the mirroring panic press), but whether a synthetic modifier arrives at all is not assumed: post `--opt brightnessDown` and require System Settings to open before believing any modified press |
| `pointer.swift` | Lists display bounds; warps the pointer to a display's centre | Key targeting defaults to the display under the pointer, so this is how a press is aimed at a chosen panel |
| `gammaread.swift` | Reads back the loaded gamma table per display | The achieved state of the software dimming leg. No DDC readback can answer it, and the MAG cannot answer any readback at all |
| `axlabel.swift` | Every button's accessibility label, with absent distinguished from present-but-empty | AppleScript's `description` is not `AXDescription`, and enumerating attribute names omits it; only a direct read separates the two |
| `axprobe.swift` | `dump [filter]`: every element of the settings window. `press <label>`: the one element matching a label | `ax.sh` walks two levels of the detail pane, which does not reach a toggle nested in a captioned row, a countdown banner's Keep button, or a LabeledContent readout whose value is a sibling static text |
| `synthread.swift` | The independent readback for a mirror-synthesis pass: CoreGraphics geometry and mirror flags, the NSScreen roster and its scales, the ColorSync ledger | The app cannot read its own virtual display, so its claim about an engage is not evidence. Three instruments in one capture, each able to answer the achieved-state question on its own |
| `synth-pass.sh` | The scripted legs of the #186 synthesized-sizes pass, one invocable leg at a time | It halts on divergence and restores nothing, so a halt leaves the evidence standing and the operator resumes at the leg they choose. Its run card is `RUN-CARD-186-synthesized-sizes.md` |


## The invariant core is `candela-probe regress` now

For the app-behaviour invariants these scripts were assembled into multi-leg
passes to prove (the combined-dimming propagation, the crossover, the sync
fan-out, the mute strand, the quiet wake, the panel's D24 pair),
`candela-probe regress` supersedes the ad-hoc scripting: it carries the positive
control for each one, splits its verdict three ways rather than two, and writes
a machine-readable record the verification ledger reads. Run it against the
deployed build rather than re-deriving one of those legs here.

The scripts remain the instruments. `regress` posts every key by running
`mediakey.swift` out of this folder (`--tools <dir>` when it cannot find it),
and it aims the pointer and reads the gamma table in process, which is the same
measurement `pointer.swift` and `gammaread.swift` make by hand. Everything
outside the invariant core still starts here: a leg nobody has written a check
for, a state a person has to see for themselves, and every pass where the
question is not yet sharp enough to be an invariant.

## The guidance for these scripts lives in a skill

Everything that used to be in this file below this point (the traps the scripts
encode, what they cannot reach, usage, and the measured rig facts) moved to
**skill `candela-hardware-verification`** on 2026-08-11, so that it loads on
demand and so that a subagent brief can name it. A README is not routed: nothing
pushed anyone to read this one, and every brief written during the Checkpoint 1
pass had to re-teach the same traps by hand.

Load that skill before driving the rig. It also carries the positive-control
discipline, which is the part that decides whether a measurement means anything.

Deliberately not duplicated here. If you find yourself adding guidance to this
file, put it in the skill instead: two copies of one fact drifting apart is the
defect we filed as #147 against our own product, and it is no better in our
tooling.
