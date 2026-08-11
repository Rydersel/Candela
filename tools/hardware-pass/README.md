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

## Two traps these scripts encode

**Select the settings window by size, never by name or index.** Candela also owns
a 1x1 "Candela Gamma Activity Enforcer" window and a full-screen "Candela OLED
Care Overlay for Display N" window. Both come and go mid-session and both shift
every window index. `first window whose size is {900, 568}` is stable.

**Guard every `name of` read with its own `try`.** One unnamed sibling otherwise
aborts the enclosing group, and the control you wanted reports as missing, which
looks exactly like a real failure. This produced a false "the Quit button does
not exist" before it was caught by a screenshot.

## What they cannot reach

The menu-bar panel's sliders expose as `AXUnknown` with no settable value, so
panel drags need a person. So do a Command-drag of the menu-bar icon, VoiceOver
announcements, a PC keyboard's F14/F15, a real room-light change for the ambient
sensor path, and typing a chord into a shortcut recorder.

## Usage

```
./ax.sh nav 1                  # 1 General, 2 Menu Bar, 3 Arrangement,
                               # 4 OLED Care, 5 Keyboard, 6 About,
                               # 8/9/10 the displays (7 is a group heading)
./ax.sh dump                   # every labelled control in the detail pane
./ax.sh toggle "Open at Login"
./ax.sh pick "Show the menu bar icon:" "Never"

swift pointer.swift            # list display bounds
swift pointer.swift 3          # aim the keys at display 3
swift mediakey.swift brightnessDown 2
swift gammaread.swift          # top=1.0000 means software dimming is released
```
