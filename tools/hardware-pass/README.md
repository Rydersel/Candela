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

**Select the settings window by EXCLUSION, never by index and no longer by size.**
Candela also owns a 1x1 "Candela Gamma Activity Enforcer" window and a
full-screen "Candela OLED Care Overlay for Display N" window. Both come and go
mid-session and both shift every window index.

This file used to say `first window whose size is {900, 568}` is stable. **It is
not.** On 2026-08-11 the window silently became **1005x580** (#149) and every
script here failed at once. Use the name instead: the two decoy windows are both
named `Candela ...`, while the settings window is named for its current pane
("General", "Keyboard", "MAG 341C OLED"), so

```
first window whose name does not start with "Candela "
```

matches the settings window and nothing else, at any size. Verified against both
a settings pane and a display pane.

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

## Rig facts measured on 2026-08-11, each of which cost a run

**The settings sidebar has no labels (#135), so it is driven by index.** The
order, verified by clicking each and reading the window title back:

| index | pane |
|---|---|
| 1 | General |
| 2 | Menu Bar |
| 3 | Arrangement |
| 4 | OLED Care |
| 5 | Keyboard |
| 6 | About |
| 7 | (the "Displays" header, not clickable) |
| 8 | built-in (Color LCD) |
| 9 | DELL U2725QE |
| 10 | MAG 341C OLED |

Read the title back after clicking rather than trusting this table: it is a
property of the current build. Note that `set w to <window>` binds by NAME, so a
reference taken before a click goes stale the moment the pane changes and the
error message quotes the OLD title. That is confusing but it is also a free way
to read the previous pane's name.

**A synthetic `shift+option` does NOT reach the app as a fine step.** Posting a
media key with those modifiers moves a FULL notch, so brightness snaps to a 1/16
grid: 0.7468 to 0.8125 to 0.875 to 0.9375 to 1.0, measured. Any plan that asks
for "set 90%" or "set 40%" is therefore unreachable by script; use the nearest
grid point and **say in the record which value you actually used**, with whether
it is a weaker or stronger test than the one planned. Substituting a value
silently is how a weaker run gets recorded as the planned one.

**OLED care will contaminate a brightness measurement that goes quiet.** The MAG
is enrolled with `oledIdleDimSeconds = 300` and `oledIdleDimLevel = 0.5`, so a
run that pauses five minutes gets dimmed underneath it. Keep a run tight, or
check the `oledcare` log category before trusting a reading.

**Brightness sync amplifies the built-in's ambient auto-brightness** into
continuous DDC traffic on every external (#145): measured 1278 fan-outs and 1268
writes in twelve minutes, all `from=1`. Turn sync off before any brightness
measurement, and check `enableBrightnessSync` rather than assuming.

**A bare relative path writes into whichever worktree the shell last `cd`'d to.**
The working directory persists between commands. With several agent worktrees
open, `cat >> docs/FILE.md` after an earlier `cd` into one of them appends
there, the later `git add` in the main checkout picks up nothing, and the commit
succeeds having recorded nothing. That happened on 2026-08-11 and the write was
recovered only because an agent reported a file it had not touched. **Use
absolute paths, or `cd` explicitly at the top of every command that writes.**
