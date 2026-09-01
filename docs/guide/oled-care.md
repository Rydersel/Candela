# OLED care

An OLED panel wears where bright, unchanging content sits. Candela keeps that
record per display and acts on it, which is two separate jobs: **Health**
watches and **OLED Care** dims.

## Enrolling a display

Settings has an **OLED Care** pane with one card per external display. Opening
a card gives that display its own page, and the switch at the top is
**Enroll this display in OLED care**. Enrolling applies the recommended
settings: dim to 50% after 5 idle minutes, dim while the screen is locked, and
count hours of use. Nothing changes until the display has actually been idle
for a while, everything can be changed afterwards, and nothing outside that
display is touched.

Enrollment is per display, and it gates all of OLED care: a display you never
enroll is never dimmed, never measured, never attributed by app and never
counted for hours. Turning a measurement switch on for an unenrolled display
records nothing, so enroll it first.

## Dimming

All of it is on the display's OLED Care page, under **Dimming**. Every one of
these dims by drawing a dark overlay over the display. Your monitor's own
brightness setting is not touched, and any key or click restores the picture
immediately.

- **Idle dim.** After a set number of minutes with no keyboard or mouse
  activity anywhere on the Mac, the display dims to a level you choose. Video
  playback, calls and anything else that holds the screen awake postpone it.
- **Dim while the screen is locked.** Same brightness as the idle dim. A key or
  click lifts it while the screen stays locked, and it comes back after the
  idle time.
- **Turn the screen black after longer.** A full blackout after a longer idle
  period. The click that wakes it is discarded, so nothing is clicked by
  accident. A key press wakes it too, but that key reaches whichever app you
  were using.
- **Dim while this display has nothing in focus.** For the display you are not
  working on. Only clicking into it brings it back, not typing elsewhere.
- **Automatic static-region dimming.** Areas that stay bright and unchanged, a
  toolbar or a sidebar, are dimmed a little while you work. Full-screen video
  is never dimmed. This is the one dimming setting that is **off by default**
  and not part of the recommended settings, because it is the only one that
  changes the screen while you are looking at it. It also needs both
  measurement settings on the Health pane; without them nothing is dimmed.

## Screen chrome

The OLED Care pane also has a **Screen Chrome** section that applies to the
whole Mac rather than one display: one switch each for automatically hiding the
menu bar and the Dock, the two pieces of interface that sit in the same pixels
for hours. These write the same system settings you would set in System
Settings, and Candela says so if macOS does not take the change.

## Measurement and the heat map

Measurement lives on the **Health** pane, per display, with a switcher when
more than one display is attached. Two independent switches:

- **Measure how bright each part of this display is.** Needs macOS to grant
  Screen Recording. It takes one reading a minute while the display is awake
  and in use, reduces each to a coarse grid of mean brightness (24 cells across
  by 10 down), and accumulates that into the exposure map. No image is stored
  and nothing on your screen can be reconstructed from a grid that size. This is
  the only place in the app that asks for Screen Recording. **Off by default.**
- **Note which apps are on this display.** Needs no permission. It reads each
  on-screen window's position and the name of the app that owns it, never
  window titles and never their contents. This is what puts an app's name next
  to an area of the display. **On by default.**

Both pause while the Mac is running on battery at 20% charge or less.

The **Heat Map** window (from the display's OLED Care page, or **Open Heat
Map** on a Health card) is the map itself, in the panel's own geometry, so a
rotated display accumulates wear where the wear actually is. It states which of
three things it is showing:

- **Measured.** Enough readings recorded to say something. Figures are relative
  to this display's own average, never an absolute luminance.
- **Not enough readings yet.** Under 30 readings, no figures are shown at all,
  because there is nothing to be right about yet.
- **Estimated: brightness is not being measured.** Measuring is off, so nothing
  comes from the screen itself. What remains is window geometry: which app held
  which part of the display, and for how long. There is no heat map in this
  state, because a map drawn without readings would imply a currency it does
  not have.

If measuring is on but macOS has withdrawn Screen Recording, the window says so
rather than quietly recording nothing. History recorded before that point is
kept.

## Panel hours

**Count hours of use**, also on the Health pane, counts while the display is
awake and not mirrored, and keeps the count per display even when it is
unplugged. One honest limit: a display switched off at the monitor itself can
still be counted, because macOS reports a blanked display as awake and there is
no layer at which the difference is observable.

## The provenance record

Each display's card on the Health pane has **Export provenance...** and **Copy
summary**. A provenance record bundles that display's hours, exposure history
and checkup runs into one file carrying a hash of its own contents, so it can
go with the display when you sell or return it. The record states in its own
text that its data is self-reported: it corroborates, it does not certify.
**Check a provenance file** on the Checkup pane verifies that a record somebody
sends you still matches its hash. Nothing is sent anywhere by the app itself.

## Write-only displays

Some monitors accept commands over the cable but answer every read with zeros.
None of OLED care depends on reading from the display. The dimming is an
overlay Candela draws, the exposure readings come from the screen contents, and
the hours come from macOS, so a write-only panel gets the same care as any
other. What such a panel cannot do is tell Candela its current brightness, so
the brightness value you see is the last one Candela sent, tracked and saved.
Which sort of panel you have is stated on the display's Diagnostics page.

## Safe Mode

Hold Shift while launching Candela and, for that session, no display is dimmed,
no hours are counted and no measurements are taken. Everything recorded before
that session is kept, and the panes that would otherwise describe behaviour
that is not happening say so on screen.
