# Controller scan-out verification

## Scope

CoreGraphics can report the requested framebuffer while the controller drives
a different wire timing. The reported MAG341C case requested 3440 x 1440 HiDPI
at 120 Hz and drove 2560 x 1440 at 120 Hz. The framebuffer check alone cannot
catch this.

Candela reads the selected `TimingElements` entry on the display's `AppleCLCD2`
node. `DPTimingModeId` selects by `ID`, not array position. Active width and
height come from `HorizontalAttributes.Active` and `VerticalAttributes.Active`.
`VerticalAttributes.PreciseSyncRate` is unsigned 16.16 fixed point. A second
active-ID read rejects a snapshot taken across a timing change.

The controller must match the exact `IODisplayLocation` path returned by
CoreDisplay. The reader checks that location again after reading. It does not
match by vendor, product, name or EDID UUID, because those can be shared by two
attached displays. A missing location, duplicate location, absent active ID,
duplicate timing ID or malformed timing produces no reading. That is **not
verifiable**, never a clean verification. No Intel, virtual-display or unknown
controller fallback is claimed.

## Guard policy

The post-apply check waits up to half a second for a matching timing, using the
existing settling helper. Refresh comparison uses the existing half-hertz
tolerance. A zero requested refresh is unspecified and does not assert a rate.
Panel dimensions are compared independently of portrait or landscape rotation.

A native mode, a revealed HiDPI mode, or a synthesized size requires native
scan-out dimensions. Ordinary published lower-resolution modes can legitimately
drive a smaller timing. A reading matching their own pixel size or native size
is accepted; another size is unverified rather than automatically called
cropped. This avoids the false assumption that every fixed panel must always
receive a native-resolution signal.

A controller mismatch on an interactive mode change triggers an immediate
attempt to apply the original fallback. A failed recovery retains a recovery-only
preview and its countdown. A mismatch discovered while keeping a preview also
attempts the fallback. Remembered-mode restoration uses the current snapshot as
its fallback. A synthesized-size mismatch unwinds the mirror and virtual display.
The synthesized guard checks geometry before the later physical-link retime,
without confusing the virtual master's 60 Hz with the physical panel's refresh.
The engage tail also checks final geometry after retiming or the HDR round trip.
A definite retime mismatch unwinds immediately; a failed unwind retains the
pairing for another recovery attempt. Removing the rendered size does not claim
that the separate best-effort restoration of the prior mode succeeded.

If an unattended rollback fails, its original safe mode survives in a
recovery-only preview with a countdown. Further arrivals wait until that preview
ends. Recovery checks the captured hardware identity before applying to a display
ID and refuses a fallback if that ID now reports a different identity. Quarantine hides
selectable rows without hiding the active mode's readback. The app shares one
configurator between ordinary mode changes and synthesis, so both use the same
session quarantine.
Interactive previews capture that identity when available, preserve it across
replacement selections, and check it before an immediate timing rollback or
countdown expiry. They also check after a successful apply, so a replacement
cannot receive a committed outcome that would save the old selection under its
preferences. Stale outcomes do not trigger restoration of a torn-down stop.
Synthesis retains the original panel dimensions across stop changes, since a
live mirror can publish the virtual master's geometry. A failed engine unwind
keeps both that baseline and the original mode until teardown succeeds. The
delayed mode restore checks that captured identity after its settling wait.
Unattended apply and fallback paths check identity again before reporting a
completed restore or proceeding to synthesis.

Observed unsafe ordinary/revealed modes are withheld by descriptor for the app
session. The cache is scoped to vendor, product, serial and exact controller
path. Runtime mode IDs are not persisted or used as durable identities. Two
serial-less identical panels physically swapped on the same port can share
that conservative quarantine until restart. This can withhold an option, but
cannot attach the other panel's live timing reading.

The pre-apply unsupported-timing prediction and normal confirmation countdown
remain enabled. Turning off the prediction does not disable the observed
mismatch check or clear its quarantine. Diagnostics reports the controller's
active size and rate, or "not verifiable". Reading that timing alone does not
prove image quality, color, link stability or the absence of cropping caused
elsewhere in the pipeline.

## Deferred hardware verification

No connected-display changes were made during implementation. Fixture tests
cover identity isolation, malformed and ambiguous data, fixed-point decoding,
rotation, refresh tolerance, legitimate lower wire modes, immediate recovery,
recovery failure/countdown, and synthesized-mirror unwind. They do not establish
that this reader works on a particular macOS/controller combination.

The manual scan-out safety pass was removed from the 1.0.5 merge and release
requirements on October 1. The unperformed cases below remain optional
follow-up investigations, not passed hardware results. The original reproduction
plan uses an Apple Silicon Mac with the MAG341C and another external display:

1. Read correct modes first. Switch the Dell to 60 Hz and the MAG to native
   175 Hz with the countdown armed. Compare diagnostics with the monitor OSD.
   Verify the active entry changes and changes back on revert, and that the
   other display's reading remains independent.
2. Disable only the prediction guard and select the MAG's revealed 3440 x 1440
   HiDPI at 120 Hz. Verify the reported 2560 x 1440 timing triggers a revert,
   names the timing in feedback, and removes the unsafe choice until restart.
3. Exercise an ordinary lower-resolution wire mode and a rotated display.
   Neither may be rejected solely for differing from the native framebuffer.
4. Exercise a controller with no supported reading or a virtual display.
   Diagnostics must say "not verifiable" and the normal countdown must remain.
5. Exercise a synthesized size and its later physical-link retime. Confirm
   that a correct native scan-out remains usable and teardown restores the
   previous display state. Test same-model neighbors on distinct ports when
   that hardware is available.

## Automated verification, 2026-09-27

The initial integrated `make check` passed 2,697 engine tests and 817 host-free
app tests. No app was installed or launched and no attached display was changed.
The app run enabled the hardware-free native render probes.

Behavioral red runs observed the missing immediate preview recovery, missing
synthesized-mirror unwind, missing recovery during Keep, missing unattended
fallback and timing feedback, and loss of native geometry after quarantine.
The corresponding regressions pass in the final combined run. Parser fixtures
also cover active-ID selection, fixed-point decoding, malformed and ambiguous
properties, exact-location matching, rotation, ordinary lower wire modes and
session quarantine boundaries.

Run logs for this work session are `/tmp/scanout-synthesis-red.log`,
`/tmp/scanout-confirm-red.log`, `/tmp/scanout-app-red.log`,
`/tmp/scanout-native-red.log`, and `/tmp/candela-release-integrated-check.log`.
These logs are local test artifacts, not physical verification evidence.

The [adversarial release review](adversarial-release-review.md) supersedes these
counts and records the later recovery, replacement-display, and synthesis-tail
regressions. Those tests reproduced the failures before the corresponding fixes.
