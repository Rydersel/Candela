# Diagnostics

A display that will not answer should be able to say so in its own words.
Candela's Diagnostics page is the app explaining, per display, what it knows,
how it is driving that display, and what is unavailable and why.

Open it from Settings, choose the display in the sidebar, then **Diagnostics**.
A switcher at the top moves between displays without leaving the page. The page
is read-only: nothing on it changes a setting.

## What it shows

It opens with one sentence answering "is this working?", composed from the same
state the rows below it render, so the verdict cannot disagree with its own
evidence. Then:

- **This Display.** The name the display reports and the name you gave it, the
  cable it is connected through, manufacturer, whether it reports a serial
  number, its declared physical size, the mode it is running, how many
  resolutions macOS listed, how many more Candela found, and the two keys your
  settings are filed under.
- **Brightness Control.** Which path this display's brightness is taking
  (native, hardware commands over the cable, software dimming, or the combined
  path), whether native brightness is available, whether hardware control is
  turned on, and how many times another app has fought Candela for the colour
  profile while it was dimming.
- **Reported Capabilities.** External displays only. What the display answered
  when asked what it supports: the capabilities request, its MCCS version,
  model and display type, the commands it advertises, whether it reads values
  back, and the brightness scale in use.
- **Availability.** Brightness, volume, contrast, mute and HDR, each either
  available or unavailable with the reason.
- **Right Now.** Live state: HDR, Safe Mode, which keyboard keys are being
  watched, the current sound output and whether it matches this display, the
  last brightness command, the last resolution problem if there was one, and
  mirroring.

Six rules govern the wording, and they are the point of the page. An
unavailable row always states a reason. A display that was asked and did not
answer is reported as **unanswered**, never as unsupported. A write-only panel,
one that takes commands but answers every read with zeros, is named as such,
with the consequence spelled out. "Not measured yet" is never rendered as "no
answer". Nothing here claims what macOS hides, only what Candela's own
enumeration found. And no internal key name reaches the page.

## Exporting the report

At the bottom of the page, **Copy Report** puts a plain-text report on the
clipboard and **Save Report...** writes it to a file you choose. Either one
covers every connected display, not only the one you are looking at, which is
what makes it useful on an issue where two displays interact.

For a support request, reproduce the issue and then save or copy the report.
There is no need to copy the raw capability description separately. Both
buttons use the same report format and take a new snapshot when used. The report
names its own format version on the second line, currently 3. That number goes
up when a heading changes name, so two pastes taken from different versions can
be told apart.

The report includes:

- **System:** capture time, report format version, app and macOS versions, Mac
  model, Safe Mode, Accessibility and Screen Recording grants, launch-at-login
  state, the media keys Candela is watching, the selected sound output and
  whether macOS can control its volume, and how many displays macOS reports as
  online, counting the built-in and any virtual display. Candela offers the
  first 32 online displays for control, and the report says so when more than
  that are online.
- **Display setup:** the controlled displays, their names, connections,
  manufacturers and modes, plus every display that is not controlled over DDC,
  each with its reason. A display can be the built-in, whose brightness macOS
  controls directly; a virtual display, either one Candela made or one from
  AirPlay, Sidecar or another app; a dummy plug; or a display with no DDC
  channel at all, which is normal for DisplayLink and also happens behind some
  hubs. A display that is only in the cached topology, which no discovery pass
  has seen, is listed as having no recorded reason. That sample can lag a
  connection change.
- **Reported capabilities:** the request state, parser result, MCCS version,
  advertised command codes and capability description for each external
  display. Not asked, still checking, no readable reply and a description that
  could not be parsed are distinct states.
- **Controls:** availability and reasons for brightness, volume, contrast, mute
  and HDR; recorded read evidence and reported maxima for individual controls;
  current app values and mute state; and the last brightness command result.
- **Context:** OLED care enrollment, mirroring, recorded resolution problems,
  cached resolution counts, non-default settings and recent display events.

Export does not send test commands or change display settings. A reported app
value or an accepted command is not confirmation that the physical brightness
or audible volume changed. The report also cannot tell where an analog speaker
cable is connected or whether sound is audible.

Identifying fields are redacted for sharing: serial fields, known serials and
storage keys in text, and unrecognized capability payloads. Capability text
over 16,384 bytes is withheld. Redactions are marked; the parser result always
describes the original response. Review custom display and audio-device names
before sharing, since those may contain information you entered yourself.

Nothing is uploaded. The report exists only where you put it.
