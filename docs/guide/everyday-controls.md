# Everyday controls

Temporary changes are how displays get left in the wrong state: a monitor kept
awake all weekend, or OLED dimming switched off for a presentation and never
switched back on. The controls on this page end on their own. Keep Awake holds
the display on until a time you choose, a dimming pause lifts OLED care on one
display without unenrolling it, and one optional shortcut switches HDR on the
display under the pointer.

## Keep display awake

Click the label or chevron beside **Keep display awake** to reveal the duration
slider. Its stops are **15 minutes**, **30 minutes**, **1 hour**, **2 hours**,
**4 hours**, **8 hours**, and **Until turned off**. Choosing a stop starts the
hold for that long, and choosing another while it runs restarts it from now.
Turning on the switch starts the hold with the duration shown. Turning the
switch off ends it.

**Custom end time…** opens the end-time window. Click the date to choose a day
from the calendar, then edit the hour and minute fields. The time controls use
your 12- or 24-hour clock preference. Choose a future end time within the next
year and click **Keep Awake**; **Cancel** leaves the current hold unchanged.

While a timed hold runs, the row shows when it ends: the time alone for today,
then "tomorrow", a weekday within the coming week, or a month and day further
out.

Candela releases its display-sleep assertion when the timer ends, including after
the Mac wakes from sleep. Quitting also ends the hold. It is never saved across
app launches. Keep Awake also prevents OLED Care from starting automatic dimming
while the hold is active.

## Pause OLED dimming

Click an enrolled display's care status below its name, then choose **Pause Dimming for
15 Minutes**, **Pause Dimming for 1 Hour**, or **Pause Dimming Until…**. The
custom picker applies only when you click **Pause Dimming**. **Cancel** leaves
the current pause unchanged, and **Resume Now** ends it early. The same choices
are on the display's OLED Care page under **Dimming**.

A pause removes existing dimming and pauses idle, blackout, lock, unfocused and
regional dimming on that display. Panel hours and exposure measurement continue,
and macOS can still sleep the display. The pause follows that display through
reconnects, counts time asleep, and ends when Candela quits. Resuming starts a
fresh idle period rather than immediately applying an old idle timeout.

## Optional HDR shortcut

Open **Settings → Keyboard**, find **Toggle HDR** under **More**, and assign a
shortcut. It is unassigned by default and does not change the brightness or
volume key modes. Put the pointer on the external display you want to change
before pressing it. A brief message identifies the result or explains why HDR
could not change.

The shortcut does not choose another monitor when the pointer is on the built-in
screen or an unsupported target. Finish an outstanding display preview, Checkup,
or settings reset first. The panel HDR button follows the same coordination rules.
Turn off a synthesized size before enabling HDR. Unsupported displays and an HDR
transition that the display does not confirm receive explanatory feedback.
