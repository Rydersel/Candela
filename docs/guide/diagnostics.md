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

The report contains the app version, the macOS version, whether Safe Mode is
on, whether Accessibility is granted, the launch-at-login state, and for each
display its names, connection, manufacturer, current mode, control method,
readback verdict and HDR state, followed by any settings you have changed from
their defaults and a short list of recent events.

Two things are deliberately not in it. **Serial numbers never appear**: the
report is written to be pasted into a public issue, and presence or absence of
a serial is all that display-identity diagnosis needs. And changed settings are
listed as a bare name and value, never as a full storage key, because a storage
key carries the display's serial.

Nothing is uploaded. The report exists only where you put it.
