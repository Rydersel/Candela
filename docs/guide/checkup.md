# Checkup

A new monitor is easiest to send back in its first days, and hardest to judge
by eye. Checkup walks one display through a fixed protocol, grades every claim
by how it was established, and writes down what it saw.

Settings, **Checkup**, then **Run a checkup**. The flow opens in its own
window and you can stop it at any point; whatever was recorded before that
stands, and the report says the run was incomplete.

## Before the run

You choose the **scenario**: a new monitor before the return window closes, a
used purchase, or a recheck of one already in use. It is one flow either way;
the scenario is recorded in the report rather than split into separate
products. Then you choose the display, and Checkup shows what it plans to run
and a worst-case duration.

## What it runs

- **Identity.** What the display reports about itself, read from its EDID:
  product name, serial (or, honestly, that it reports none), manufacture week
  and year, native pixel size, maximum refresh, and the HDR flags in the EDID.
- **Capabilities.** Whether the display answers over DDC for brightness,
  contrast and volume.
- **The native resolution.** Applying the panel's own mode.
- **The refresh sweep.** Each refresh rate the display advertises, applied in
  turn.
- **The witness card.** A full-screen circle and square, which you judge by eye:
  both should look round and square with nothing cut off at the edges. It is a
  geometry check, and it obeys the same caps as the colour fields below.
- **Colour fields.** Full-screen black, red, green, blue, 7% grey, 50% grey, a
  gradient, and white, in that order, which you judge by eye. Each field is
  capped at 20 seconds (white at 10) and can be shown up to three times, so a
  run does not itself leave a static field on an OLED for long.
- **HDR.** The EDID flags, and whether an HDR switch settles. These run last.

Nothing here ends a run except you. A display that refuses a check has the
refusal recorded with its reason and the run carries on.

## How claims are graded

Every claim in the report carries one of these, and each carries the evidence
it rests on:

- **observed**: Candela saw it happen.
- **refused**: the display was asked and said no, with the reason quoted.
- **not observed**: it could not be established here, with the reason named.
  A display with no DDC path, a write-only display, and a display in HDR mode
  each produce a different named reason. Readback cannot be observed while a
  display is in HDR mode, and Checkup says exactly that rather than reporting
  a failure.
- **self-reported**: the display said so about itself, which is not the same as
  being seen.
- **inconclusive**: see the planted control below.

There is no overall pass or fail, and Checkup does not certify panels.

## The planted control

The colour fields are your eyes, not an instrument, so Checkup grades the eyes
too. Before the fields, it tells you that it will plant one small mark on the
screen at a position it will not reveal, and asks you to tap the mark when you
see it. That establishes whether a defect of that size is visible from where
you are sitting, which is what lets the report say how sensitive your answers
were.

The existence of the control is always disclosed in advance; only its position
is withheld. If the first mark is not found, the same field is shown once more
with a larger one. If an 8 pixel mark is missed as well, the colour fields are
recorded as **inconclusive** rather than clean, and the other checks stand
unaffected.

## The report

Every run is stored on this machine, filed under the display's own identity,
under `~/Library/Application Support/Candela/Checkups/`. Nothing is sent
anywhere. The Checkup pane lists past runs for the selected display, newest
first, with **Show details**, **Export** and **Copy summary** on each.

**Export** writes a single `.candela-checkup.json` file that carries a hash of
its own contents. **Verify a report** on the same pane takes a file somebody
sends you and checks that the contents and the hash still agree, so a report
that has been edited since it was written says so.

A checkup report can also travel inside a **provenance record**, which bundles
one display's hours, exposure history and checkup runs into a single
hash-carrying file; see [OLED care](oled-care.md). **Check a provenance file**,
on this same pane, verifies one of those.

Two limits are stated in the document itself, not only here. The visual fields
are the user's attestations at the recorded control sensitivity, because a file
handed to a stranger cannot point at what was on the screen. And a run that
never managed to read the display prints no serial, no size and no EDID flag
rather than a plausible blank.
