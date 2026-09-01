# Resolutions

macOS lists a handful of sizes per display. Candela enumerates what the panel
can actually run, tells you where each option came from, and never commits a
change you have not looked at.

Everything here is in Settings, on a display's own page, under **Display**.

## The controls

- **Size** picks a logical size. Choosing one keeps the refresh rate the
  display is already running whenever that size offers it.
- **Refresh rate** picks a rate at the current size.
- **Remember this resolution** saves the current size and rate for this
  display, and restores it when the display reconnects, not while you are
  using it. **Forget** clears it again from the same row.
- **All Sizes & Refresh Rates** opens the full list, with a **Show** switch
  between Recommended and All and, on the full list, a refresh-rate filter.

Rows carry marks that say where an option came from and what choosing it
costs. `Native` is the panel's own timing. `Scaled` renders larger and
downsamples. `low resolution` marks a size that has a sharper twin at the same
logical dimensions. `Recommended` marks the size the density model picked.
`Default` appears on the built-in display for the size macOS calls Default.

## The sizes macOS does not list

Some panels can drive HiDPI sizes that macOS never lists, most often
standard-density external displays. Candela asks the window server directly,
keeps only entries that are genuinely HiDPI, discards ones that are implausible
or off-aspect or that the panel has no matching timing for, and adds what
survives to the list marked
**Added by Candela**. This is a claim about our own enumeration and nothing
else: no API reports why the Displays pane's list is the length it is, so we
never say macOS hid anything specific, only that it did not list it.

One guard sits in front of this. A mode whose refresh rate the display
advertises no full-width timing for is withheld by default, because some
panels bind such a mode to an unrelated timing and scan the desktop out
letterboxed or cropped while macOS reports success throughout. The display's
Diagnostics page reports how many modes are being withheld, and the guard can
be turned off; see [advanced settings](advanced-settings.md).

## The recommended size

Where a display declares its physical size, Candela works out which logical
size lands in the band that looks right for a panel that size, and offers it
once as a callout with a **Use This Size** button and a **Dismiss** button.
It abstains rather than guessing: no declared physical size, an implausible
one, a virtual display, a current size that already looks right, or no
available size that reaches the band all produce no recommendation. Applying
it goes through the same confirm-or-revert flow as any other change, because a
recommended size is no safer than any other.

## In-between sizes

**More sizes** is a per-display switch that adds scaled sizes between the ones
the display reports. They are rendered through a virtual display, so they are
marked **Rendered by Candela** rather than `Added by Candela`, and the picture
may use more memory while one is active. A virtual display appears in System
Settings while such a size is engaged; that is the mechanism, not a bug.

While one of these sizes is engaged, the full list, which enumerates what the
display itself reports, has no row for it, so the list says so out loud
instead of appearing to have lost track. Turning **More sizes** off takes an
engaged size down first and only then clears the setting, so a teardown that
fails leaves the rows you need to recover still in the picker.

## Confirm or revert

No resolution change is committed by choosing it. The new mode is applied as a
preview with a 30 second countdown and a **Keep** button, and if you do not
answer, it reverts on its own. That window is the only detector there is for a
panel that accepts a mode and then scans it out wrong, so it applies to
recommended sizes, in-between sizes, rotation, mirroring and arrangement
alike. Rotation, mirroring and arrangement ask the same question in their own
words.

If you are looking at a different window when a preview starts, the settings
window still shows the countdown and points you at the confirmation window
holding the buttons.

## When a size fails

Candela distinguishes the cases, and each says what state the display is in:

- **The change never started.** Either the request failed outright, in which
  case nothing changed, or another operation was holding the display, in which
  case the message names what held it. Nothing needs answering.
- **The preview could not be resolved.** The preview is still on the display,
  nothing retries by itself, and the message invites another attempt. If the
  countdown has already run out, it says the automatic revert has been used up.
- **A remembered size could not be restored.** At launch or on reconnect this
  runs with nobody watching, so it is always reported afterwards: the saved
  size was unavailable and something close was used instead, or it was
  unavailable and nothing close enough existed so the display was left alone,
  or the mode still exists but the change failed, which is worth trying again
  from the list.

If a size leaves the screen unreadable and you cannot see the buttons, wait:
the countdown reverts without you.

## Safe Mode

Hold Shift while launching Candela. For that session it will not restore your
saved brightness, volume, contrast, resolution or arrangement at startup or
wake, will not read values back from your displays, will not write anything to
them when it quits, and will not dim any display, count hours of use or take
any measurements for OLED care. Your sliders and keyboard shortcuts still work
and still send commands, and none of your settings are changed. Relaunch
without Shift to leave it.
