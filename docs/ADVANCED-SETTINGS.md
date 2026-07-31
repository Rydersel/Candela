# Advanced settings

Candela's Settings window exposes the decisions a person can actually make.
The knobs below exist for broken or unusual hardware: they still work, they
still have engine tests, and they are set with `defaults write` instead of a
control. (Cut from the UI by ruling D26, which also promised this page.)

A second list at the bottom covers names that are **reserved and do nothing**.
They are documented so nobody sets one and concludes the app is broken.

Domain: `com.rydersel.Candela`.

## Finding a display's key

Per-display keys end in a *persistence key* — the display's EDID UUID, or a
name/manufacturer/serial triple when the EDID carries no UUID.

```sh
cd CandelaKit && swift run candela-probe list
# 3        4C2D-6E00-0000-0000-...        MAG341C
#  ^id     ^persistence key               ^name
```

`defaults read com.rydersel.Candela` shows every key Candela has written, which
is the other way to find it.

## Applying a change

**Quit and relaunch Candela after any `defaults write`.**

Every accessor below reads `UserDefaults` at the moment it is used — nothing is
snapshotted at launch — so the running app *can* pick an external write up on
its own. What it cannot do is react to one. The Settings window routes its own
edits through the app's pref-change seam, which re-arms the key tap, re-applies
dimming, rebuilds the panel and refreshes the menu bar item as each pref
requires; a write from the command line arrives with no such signal. So a key
that is consulted fresh on every use (`pollingMode`, `pollingCount`,
`separateCombinedScale`) takes effect at the next read or keypress, while one
whose effect has to be *re-applied* (`combinedSwitchingPoint`, `curveDDC`,
`remapDDC`) sits in the domain looking ignored until something else re-applies
it. Relaunching removes the distinction, which is why it is the rule rather
than a caveat.

---

# Working keys

## App-level (no suffix)

| Key | Type | Default | Effect |
|---|---|---|---|
| `separateCombinedScale` | Bool | `NO` | Changes how far one press of a **brightness key** moves the slider while combined hardware+software dimming is active: 32 steps across the whole range instead of the usual 16. Sliders are unaffected. Ignored unless the display is actually on the combined path — no effect with "Dim past the display's minimum" off, with hardware control off for that display, or on the built-in panel. |

## Per-display (`<key>.<persistenceKey>`)

| Key | Type | Default | Effect |
|---|---|---|---|
| `combinedSwitchingPoint` | Int | `0` | Where combined dimming hands over from the hardware (DDC) leg to the software leg. Range `-8`…`7`; values outside it are clamped on both read and write. Negative moves the crossover darker, positive brighter. Only meaningful while "Dim past the display's minimum" (Settings → General) is on. Set back to `0` by "Reset Display Settings…". |
| `pollingMode` | Int | `0` | How many times a DDC read is retried, and **only** when Settings → General → "On startup and wake:" is set to *Ask the display for its current values*. `-2` none, `-1` minimal (1 try), `0` normal (5), `1` heavy (20), `2` custom. Applies to the volume and contrast readback; the brightness readback makes a single attempt regardless. |
| `pollingCount` | Int | `0` | The try count used when `pollingMode` is `2`. Negative values clamp to 0. |

Example:

```sh
defaults write com.rydersel.Candela "combinedSwitchingPoint.4C2D-6E00-0000-0000-..." -int -3
defaults write com.rydersel.Candela "pollingMode.4C2D-6E00-0000-0000-..." -int 1
```

## Per-command (`<key>.<command>.<persistenceKey>`)

`<command>` is one of `brightness`, `volume`, `contrast`.

| Key | Type | Default | Effect |
|---|---|---|---|
| `curveDDC` | Int | `0` | Response curve, `1`–`9`. `0` (unset) and `5` are both linear; below 5 biases the low end, above 5 the high end. The engine default suits essentially all hardware — reach for the Min/Max fields in Settings → Displays first. |
| `remapDDC` | String | `""` | Comma-separated hex VCP codes to use instead of the standard one, for monitors that put a feature somewhere non-standard. Reads use only the FIRST code; writes go to all of them. Empty, `0` and non-hex tokens are dropped. |

Example — a monitor that answers brightness on `0xE1`:

```sh
defaults write com.rydersel.Candela "remapDDC.brightness.4C2D-..." -string "e1"
defaults write com.rydersel.Candela "curveDDC.brightness.4C2D-..." -int 7
```

The other per-command settings — Min, Max, Invert and the per-command On
switch — **do** have controls, in Settings → Displays under "Command tuning".

---

# Reserved, but not implemented

These names exist so they are never reused for something else. **Nothing reads
them, and setting one changes nothing.** They are listed here because a name
with no documentation and no behavior is indistinguishable from a bug report
waiting to happen.

Three of them have a `DisplayPrefs` accessor and a test pinning their storage,
so the schema slot is claimed in code; the other three are reserved on this
page only — Candela has never written them and has no accessor for them.

| Key | Scope | Claimed in code? | Why it is reserved |
|---|---|---|---|
| `longerDelay` | per-display | accessor + test | The fork paced its DDC reads more slowly with this, and force-disabled launch-at-login as a "safety measure" with nothing to re-enable it. Neither behavior is ported. Set back to `NO` by "Reset Display Settings…", only so a stray `defaults write` can be cleared. |
| `showTickMarks` | app-level | accessor + test | The fork drew tick marks under its sliders (and, by mistake, chose the quit button's glyph with the same key). Candela's panel has no tick renderer — cut before one was written. |
| `menuItemStyle` | app-level | accessor + test | The fork's menu had icon/text/hidden footer styles. Candela's panel footer is a designed, fixed row; no code reads this. |
| `hideBrightness` | app-level | name only | The fork hid every brightness slider app-wide. Hiding every brightness slider in a brightness app is a footgun, and the per-display controls in Settings → Displays are strictly more expressive. |
| `hideVolume` | app-level | name only | Same as above; superseded by the per-display "Show the volume slider in the panel". |
| `multiSliders` | app-level | name only | The fork's combined/relevant multi-slider menu modes. Recorded as an M5 scope gap rather than a decision against it: the modes are unbuildable and untestable on single-monitor hardware. |

---

## Related keys that are not settings

- `prefsSchemaVersion` (Int) records which schema wrote this domain. Deleting
  it makes the next launch treat itself as a first run and show Setup again;
  nothing else is lost. A version *newer* than the running build is left
  alone — Candela never wipes on downgrade.
- `brightness.<pk>` / `combinedBrightness.<pk>` / `volume.<pk>` /
  `contrast.<pk>` are the saved levels. On a write-only DDC panel these are the
  **only** record of the display's state, because nothing can be read back.
  Deleting them is a real loss, not a cache invalidation.
- `muted.<pk>` is engine state, not a preference.

## Resetting

Settings → General → **"Reset All Settings…"** removes the whole domain —
per-display tuning, names, custom shortcuts, saved levels, and the Open at
Login registration — and runs Setup again. Settings → Displays →
**"Reset Display Settings…"** clears one display's settings, including the
keys on this page, and keeps its saved levels.

Holding Shift during launch is *Safe Mode*, which is unrelated and changes no
settings at all. For that session Candela does not restore your saved values at
startup or on wake, does not read brightness back from the display, and does
not write values out when it quits. The sliders and the keyboard keys keep
working normally and still send DDC — Safe Mode is for a display that a
*restore* wedges, not a way to silence the app. Relaunch without Shift to
leave it.

One exception, and the safe-mode notice names it when it applies: with
"Match other displays to the built-in display" turned on, brightness changes on
the built-in display — including ones macOS makes by itself, such as the
ambient light sensor's — are still mirrored out over DDC. Turn that setting off
if a display has to be left completely alone.
