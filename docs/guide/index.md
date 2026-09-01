# Candela guides

Most display utilities stop at the slider. These pages cover the parts of
Candela that keep a record of your display and act on it, plus the escape
hatches for hardware that misbehaves.

- [OLED care](oled-care.md). Enrolling a display, the dimming settings, the
  exposure heat map, panel hours, and what the permission-free path can and
  cannot see.
- [Checkup](checkup.md). What a guided verification measures, how each claim is
  graded, the planted control that grades your own eyes, and what the report
  does not certify.
- [Resolutions](resolutions.md). The size list, the HiDPI sizes macOS does not
  list, the in-between sizes Candela renders, and what happens when a size
  fails.
- [Diagnostics](diagnostics.md). What the per-display Diagnostics page reports
  and how to export it for an issue.
- [Advanced settings](advanced-settings.md). The knobs that are set with
  `defaults write` instead of a control, and why they are there.

## Where things live

Everything below is in Candela's Settings window (Command-comma, or Settings
from the menu bar item). The sidebar runs top to bottom: **General** on its
own, then **Care** (Health, Protection, OLED Care, Checkup), then **Controls**
(Menu Bar, Keyboard, Arrangement, Virtual Displays), then **About**, and each
connected display has its own entry below those.

## What leaves your Mac

Nothing you record. Exposure history, panel hours and checkup reports are
files on your own disk, and the only way any of them travels is you exporting
one deliberately. The app makes one network request of its own accord: the
signed update check.
