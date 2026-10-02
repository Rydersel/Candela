# Everyday controls

The menu bar panel keeps brightness and volume directly available. Temporary
controls open from the existing status rows; they do not add permanent sections.

## Keep display awake

Click the label or chevron beside **Keep display awake** to reveal the duration
slider. Its stops are **15 minutes**, **30 minutes**, **1 hour**, **2 hours**,
**4 hours**, **8 hours**, and **Until turned off**. Choose the duration and turn
on the switch to start; changing the slider while a session is running restarts
its duration from now. Turning the switch off ends the session.

**Custom end time…** opens the end-time window. Click the date to choose a day
from the calendar, then edit the hour and minute fields. The time controls use
your 12- or 24-hour clock preference. Choose a future end time and click
**Keep Awake**; **Cancel** leaves the current session unchanged.
A timed session shows its end time, including the date when it is not today.

Candela releases its display-sleep assertion when the timer ends, including after
the Mac wakes from sleep. Quitting also ends the hold. It is never saved across
app launches. Keep Awake also prevents OLED Care from starting automatic dimming
while the hold is active.

## Pause OLED dimming

Click an enrolled display's care status below its name, then choose **Pause Dimming for
15 Minutes**, **Pause Dimming for 1 Hour**, or **Pause Dimming Until…**. The
custom picker applies only when you click **Pause Dimming**. **Cancel** leaves
the current pause unchanged, and **Resume Now** ends it early. These controls
also appear in the display's OLED Care settings under **Dimming**.

A pause removes existing dimming and pauses idle, lock, unfocused and regional
dimming on that display. Panel hours and exposure measurement continue. Normal
macOS sleep still applies. The pause follows that display through reconnects,
counts time asleep, and ends when Candela quits. Resuming starts a fresh idle
period rather than immediately applying an old idle timeout.

## Optional HDR shortcut

Open **Settings → Keyboard → More → Display Shortcuts** and assign **Toggle
HDR**. It is unassigned by default and does not change the brightness or volume
key modes. Put the pointer on the external display you want to change before
pressing it. A brief message identifies the result or explains why HDR could not
change.

The shortcut does not choose another monitor when the pointer is on the built-in
screen or an unsupported target. Finish an outstanding display preview, Checkup,
or settings reset first. The panel HDR button follows the same coordination rules.
Turn off a synthesized size before enabling HDR. Unsupported displays and an HDR
transition that the display does not confirm receive explanatory feedback.
