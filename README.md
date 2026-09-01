# Candela

Candela looks after your displays: panel health, burn-in protection, and the
everyday controls, done carefully. Free and open source, for macOS.

Other display apps adjust settings in the moment. Candela stewards your
display over its lifetime, and does the settings too.

Your monitor is probably the most expensive thing on your desk that nothing
takes care of. macOS forgets its settings, offers no brightness slider for it,
and has no idea how many hours its panel has been lit or where. Candela is a
menu-bar app that keeps those records, protects the panel from wear, and fills
in the controls macOS leaves out for external displays.

## What it does

Four things, and the first three are what make it different.

**Health.** Candela keeps a per-panel record of lit hours and an exposure heat
map: where on the panel the bright, static content has been, accumulated over
time in the panel's own geometry. No firmware shows you this. The map is
built from a coarse luminance grid (a 24 by 10 sampling of mean brightness),
so nothing on your screen is stored and nothing can be reconstructed from it.
By default it works without any permission, from what the system already
exposes about your windows and wallpaper. Granting Screen Recording turns on
measured sampling for a more accurate map; that stays opt-in.

**Protection.** One-click auto-hide for the menu bar and the Dock, the two
pieces of chrome that sit still for hours on an OLED. Dimming when you step
away and while the Mac is locked, with a recommended preset you can enroll a
display in with one click and adjust afterwards. A keep-awake assertion from
the panel when you need it. Display settings Candela remembers for you: the
resolution you picked for each display comes back after a replug or a reboot,
and you can forget it again from the same place.

**Checkup.** A guided verification of a newly connected monitor, so you can
check a panel before the return window closes. One flow covers a new panel, a
used purchase, or a recheck of one you already own; which it was is recorded
in the report rather than split into separate products. It reads the panel's
identity, exercises what the panel will answer over DDC, applies its native
mode and each refresh rate it advertises, and walks you through full-screen
colour, grey and gradient fields. Every claim carries a grade: observed,
refused, not observed, or self-reported. The fields you judge by eye are
graded too, by one small mark planted on the first of them. You are told
before the run that the mark is there, never where, and a run whose mark goes
unfound records as inconclusive rather than clean. The report exports as a
single integrity-checked file. There is no overall pass or fail, and it does
not certify panels.

**Controls.** Brightness, contrast and volume for external displays over
DDC/CI, from the menu bar, with keyboard media keys and a HUD. Software
dimming below the hardware floor. An HDR toggle. Every resolution the panel
can actually show, including HiDPI sizes macOS refuses to compute on standard-
density panels, plus an opt-in per-display setting that adds in-between
scaled sizes rendered through a virtual display. Arrangement, mirroring and
rotation from a canvas, with saved layouts. Virtual displays for headless and
capture setups. A guided first-run setup that walks each attached display.

## What it does not do

Some of these are deliberate, some are waiting on hardware. Each has a reason,
and the reason is what decides whether it ever changes.

- **Turn your monitor off or put it in standby over DDC.** Built, tested, and
  cut. On one panel it worked, and twice it left the monitor unreachable until
  its input was switched away and back. macOS cannot tell a blanked panel from
  a lit one, so the app cannot know when it has gone wrong. It stays out until
  someone finds a recovery path.
- **Colour calibration.** A colorimeter and a calibration workflow are a
  different product.
- **Blue-light or circadian modes.** macOS already owns Night Shift and True
  Tone.
- **Break reminders.** Wellness, not display care.
- **Picture-in-picture, display streaming, or a raw VCP console.** Other apps
  do these already. Candela is not chasing them.
- **XDR brightness unlock.** Parked, not cut: there is no XDR display in the
  test setup to verify it on.
- **Importing settings from other display apps.** Candela starts fresh.
- **Windows, Linux, or an iOS companion.**

## Requirements

- macOS 14 or later, on Apple silicon.
- For hardware brightness, contrast and volume: a monitor that supports
  DDC/CI over the cable you are using. Most do. Some panels accept DDC writes
  but answer every read with zeros (the MSI MAG 341C is one); Candela treats
  those as write-only and tracks the last value it sent.
- **Accessibility**, only if you want the keyboard media keys to drive the
  external display. Everything else works without it.
- **Screen Recording**, only if you opt into measured exposure sampling. The
  default health path never asks.

DDC does not work while a display is in HDR mode. Candela says so in the
panel rather than failing silently.

## Install

Download the notarized build from [candela.fyi](https://candela.fyi) and drag
it to Applications. The app checks for updates on its own and asks before
installing one; updates are signed, and a build whose signature does not
match is refused.

To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md).

## A note on private APIs

Parts of Candela rely on macOS interfaces Apple does not document: revealing
and switching display modes, creating virtual displays, the menu-bar auto-hide
key, and the HDR toggle among them. These are the features other tools cannot
offer, and they are also the ones that can break when a new macOS ships.
Candela carries a conformance check that detects that drift, and fixes land in
the open, so you can watch them happen. If something stops working the day
after a macOS update, that is the most likely reason, and an update is the
most likely fix.

## Tested hardware

Development runs on Apple silicon with macOS 26 and two external panels: an
MSI MAG 341C OLED (3440 by 1440, write-only DDC) and a Dell U2725QE (4K,
mounted rotated, full DDC read support). Every feature is verified on real
hardware before it merges, and the record of what has and has not been
verified is public in `docs/VERIFICATION-STATUS.md`. If your panel behaves
differently, an issue with the model name is the most useful thing you can
send.

## Credits

Candela is a new engine, not a fork. Its DDC transport for Apple silicon and
Intel, and part of its dimming math, are transplanted from
[MonitorControl](https://github.com/MonitorControl/MonitorControl) under the
MIT license and carry that project's copyright notice; the full list is in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). MonitorControl is the
best-known open-source app in this space and its DDC code is the most widely
read there is. Candela would not exist without it.

Candela itself is released under the [MIT license](LICENSE).
