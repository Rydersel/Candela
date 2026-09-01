<p align="center">
  <img src=".github/assets/icon.png" width="128" height="128" alt="Candela app icon">
</p>

<h1 align="center">Candela</h1>

<p align="center">
  <b>Candela looks after your displays.</b><br>
  Panel health, burn-in protection, a checkup for new monitors, and the everyday controls macOS leaves out.<br>
  Free and open source, for macOS.
</p>

<p align="center">
  <a href="https://github.com/Rydersel/Candela/releases/latest"><img src="https://img.shields.io/github/v/release/Rydersel/Candela?label=release&color=1f9e89" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon-arm64-111" alt="Apple silicon">
  <img src="https://img.shields.io/badge/signed%20%26%20notarized-Developer%20ID-111" alt="Signed and notarized">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Rydersel/Candela?color=1f9e89" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/Rydersel/Candela/releases/latest"><b>Download for macOS</b></a>
  &nbsp;&middot;&nbsp;
  <code>brew install --cask rydersel/tap/candela</code>
  &nbsp;&middot;&nbsp;
  <a href="https://candela.fyi">candela.fyi</a>
</p>

<p align="center">
  <img src=".github/assets/tour.gif" width="880" alt="A tour of Candela's settings window">
</p>

Other display apps adjust settings in the moment. Candela stewards your display over its lifetime, and does the settings too. Your monitor is probably the most expensive thing on your desk that nothing takes care of: macOS forgets its settings, offers no brightness slider for it, and has no idea how many hours its panel has been lit. Candela is a menu-bar app that keeps those records, protects the panel from wear, and fills in the controls.

## What it does

<table>
  <tr>
    <td width="50%" valign="top">
      <img src=".github/assets/health.gif" alt="The Health pane and its exposure heat map">
      <h3>Health</h3>
      A record of where an enrolled panel has been lit, kept in the panel's own geometry as a coarse exposure grid, so nothing on your screen is stored. Turn on measurement and the map fills in from real screen readings. Panel hours and per-app attribution come with it, and the whole record exports as one integrity-checked file.
    </td>
    <td width="50%" valign="top">
      <img src=".github/assets/setup.gif" alt="Guided setup recommending a sharper size for a display">
      <h3>Protection</h3>
      One-click auto-hide for the menu bar and the Dock, dimming when you step away and while the Mac is locked, and an optional static-region dim that eases down bright, unchanged regions while active content stays at full brightness. Display settings survive replugs and reboots.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src=".github/assets/checkup.webp" alt="A checkup report for a new monitor">
      <h3>Checkup</h3>
      A guided verification of a new, used or rechecked monitor while the return window is still open. Every claim carries a grade: observed, refused, not observed, or self-reported. The by-eye tests include a disclosed sensitivity control, and a run whose control goes unfound records as inconclusive. It records observations; it does not certify panels.
    </td>
    <td width="50%" valign="top">
      <img src=".github/assets/controls.gif" alt="Brightness and volume sliders for every display in the menu bar">
      <h3>Controls</h3>
      Brightness, contrast and volume for external displays over DDC/CI, from the menu bar, your keyboard's keys, and a HUD. Software dimming below the hardware floor, an HDR toggle, every resolution the panel can show including HiDPI sizes macOS hides, plus arrangement, mirroring, rotation, virtual displays and a guided first-run setup.
    </td>
  </tr>
</table>

## Install

Download the notarized build from [the latest release](https://github.com/Rydersel/Candela/releases/latest) or [candela.fyi](https://candela.fyi), unzip, and drag Candela to Applications. Or with Homebrew:

```sh
brew install --cask rydersel/tap/candela
```

Candela checks for updates on its own and asks before installing one. Updates are signed, and a build whose signature does not match is refused.

## Requirements

- macOS 14 or later, on Apple silicon.
- For hardware brightness, contrast and volume: a monitor that supports DDC/CI over the cable you are using. Most do. Write-only panels, which accept writes but answer every read with zeros, are supported and tracked by the last value sent.
- **Accessibility**, only if you want the keyboard media keys to drive an external display.
- **Screen Recording**, only if you opt into measured exposure sampling. Nothing else asks for it.

DDC/CI does not work while a display is in HDR mode. Candela marks the display in the menu bar and says so on its Diagnostics page rather than failing silently.

<details>
<summary><b>What it does not do</b></summary>
<br>

Some of these are deliberate, some are waiting on hardware. Each has a reason, and the reason is what decides whether it ever changes.

- **Turn your monitor off or put it in standby over DDC.** Built, tested, and cut. On one panel it worked, and twice it left the monitor unreachable until its input was switched away and back. macOS cannot tell a blanked panel from a lit one, so the app cannot know when it has gone wrong. It stays out until someone finds a recovery path.
- **Colour calibration.** A colorimeter and a calibration workflow are a different product.
- **Blue-light or circadian modes.** macOS already owns Night Shift and True Tone.
- **Break reminders.** Wellness, not display care.
- **Picture-in-picture, display streaming, or a raw VCP console.** Other apps do these already.
- **XDR brightness unlock.** Parked, not cut: there is no XDR display in the test setup to verify it on.
- **Importing settings from other display apps.** Candela starts fresh.
- **Windows, Linux, or an iOS companion.**

</details>

## A note on private APIs

Parts of Candela rely on macOS interfaces Apple does not document: revealing and switching display modes, creating virtual displays, the menu-bar auto-hide key, and the HDR toggle among them. These are the features other tools cannot offer, and they are also the ones that can break when a new macOS ships. Candela carries a conformance check that detects that drift, and fixes land in the open. If something stops working the day after a macOS update, that is the most likely reason, and an update is the most likely fix.

## Tested hardware

Every release is tested on as many different displays, connections and Macs as we can get our hands on, but no two setups are alike. If something misbehaves on yours, [open an issue](https://github.com/Rydersel/Candela/issues/new/choose) with your Mac, macOS version, monitor model and how it is connected, and we will look at it as soon as we can. A working setup is worth reporting too: it goes into the verified hardware list.

## Documentation

- [User guides](docs/guide/index.md): OLED care, checkup, resolutions, the Diagnostics page, and advanced settings.
- [Advanced settings](docs/ADVANCED-SETTINGS.md): the `defaults write` keys behind the escape hatches.
- [Contributing](CONTRIBUTING.md): building from source, running the suites, and what a change is expected to state about its own verification.

## Credits

Candela is a new engine, and it is descended from [MonitorControl](https://github.com/MonitorControl/MonitorControl). Its DDC/CI transport for Apple silicon and Intel, its media-key handling, its software-dimming approach and its HDR toggle were transplanted or adapted from that project under the MIT license, and every file containing its code carries its copyright header. The file-by-file list is in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). MonitorControl is the best-known open-source app in this space and its DDC code is the most widely read there is; Candela would not exist without it. Updates ship through [Sparkle](https://sparkle-project.org).

## License

[MIT](LICENSE).
