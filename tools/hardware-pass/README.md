# Hardware-pass driver scripts

Four small tools that let an agent (or a person) drive a checkpoint hardware
pass from a shell, written during Checkpoint 1 §6 session 3 (2026-08-11) and
committed so the next pass does not re-derive them. **Placement is provisional**:
if the reusable-playbook work lands, these are its seed and should move wherever
it puts them.

What each one exists for, and the measured fact behind it:

| script | what it does | why it is needed |
|---|---|---|
| `ax.sh` | Drives the settings window over the accessibility API: `nav <n>`, `dump`, `toggle <name>`, `pick <popup> <item>`, `statusicon` | The settings window is fully drivable; this is what made most of §6 runnable unattended |
| `mediakey.swift` | Posts a real brightness/volume media key | Candela watches a head-insert event tap, which sees every event regardless of what is frontmost, so a posted media key reaches the app even though the terminal has focus |
| `pointer.swift` | Lists display bounds; warps the pointer to a display's centre | Key targeting defaults to the display under the pointer, so this is how a press is aimed at a chosen panel |
| `gammaread.swift` | Reads back the loaded gamma table per display | The achieved state of the software dimming leg. No DDC readback can answer it, and the MAG cannot answer any readback at all |


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
