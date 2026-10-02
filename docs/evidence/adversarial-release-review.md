# Adversarial release review

September 28, 2026. Reviewed the local `feature/everyday-display-controls`
changes against `bcc44c16`, including new files and their existing callers.
Three parallel reviewers and an independent integration reviewer covered
scan-out and recovery, OLED/brightness/timer lifecycles, and HDR/UI integration.
Findings were checked against callers. Behavioral regressions reproduced the
hardware-free failures before their fixes; shortcut unregistration ordering was
verified against the checked-out dependency implementation. A passing pre-review suite was not treated as proof
that asynchronous failure paths were covered.

## Confirmed findings

- The panel HDR button bypassed the shortcut's gate. A settings reset could also
  begin during HDR, and a stale panel snapshot could target a replacement display
  with the same ID. The panel and shortcut now share one observable action;
  reset eligibility and controller identity checks cover the whole transition.
- A DDC read started in SDR could complete during HDR entry, replace the saved
  brightness, and write the software dimming layer. Generation and path checks
  now prevent adoption after HDR or temporary-dimming transitions, including
  delayed quit-recovery readbacks.
- A forward wall-clock change could leave timed Keep Awake active beyond its
  displayed deadline. Clock-change notifications now expire or reschedule it.
- Synthesis could swallow a definite scan-out mismatch during its later physical
  retime or HDR bounce. The tail now checks and unwinds that failure.
- Quarantining the active mode hid its readback. If automatic restore and its
  fallback both failed, there was no actionable recovery preview. Readback now
  remains independent of selectable rows, and failed automatic restoration keeps
  the original fallback, countdown and gate ownership, with identity checks.
- Separate production configurators had separate quarantine stores. The app now
  supplies the same configurator to mode selection, synthesis and Checkup.
- Checkup's mode/HDR operations bypassed display coordination, and abort mode
  restoration could overlap the still-running HDR leg. Checkup now needs an
  exclusive lease from selection through cleanup; cancellation must finish the
  active leg before restoring the mode and releasing ownership.
- Settings reset could overlap mode, mirror, rotation and arrangement changes
  in either direction. Reset now reserves the shared gate through cleanup; only
  its own synthesis teardown can run under that reservation. Reset All also
  unregisters saved keyboard shortcuts before wiping their stored mappings.
- Going Back from a Checkup plan retained the previous display's pregraded
  claims. Admission could also use HDR or mirroring metadata captured before
  another display change. Retargeting now clears the prior plan, and admission
  revalidates the setup before building runners.
- Keep Awake's accessibility value omitted its expiry. HDR feedback also measured
  unconstrained text before wrapping, which clipped sufficiently long messages.
  The controls now expose the deadline and size feedback at its actual width.

Follow-up regressions reproduced loss of the original panel geometry across
synthesized-size changes, loss of the original mode while an initial synthesis
failure still needs teardown, and an interactive rollback writing to a
replacement display that reused the original display ID. Identity checks now
also cover successful commits, unattended reapply and the synthesis teardown
tail, preventing wrong-target writes, saved selections and completion reports.

## Evidence

- First engine red: 2,701 tests, 14 expected failed assertions. Eight exposed the
  SDR/HDR readback race, five exposed clock handling, and one exposed hidden
  active-mode readback.
- First app red: 824 tests, 15 expected failed assertions in HDR ownership/identity,
  automatic recovery and synthesis-tail failures.
- After the first fixes: all 2,706 engine tests passed. The next app run reproduced
  11 expected Checkup lifecycle assertions while the earlier app regressions passed.
- The next engine run reproduced five identity/rollback assertions in 2,708
  tests. The 834-test app run reproduced four synthesis-ledger assertions; the
  Checkup lifecycle and feedback layout regressions passed.
- A further run reproduced two post-apply identity assertions in 2,709 engine
  tests and 47 assertions across nine expected app regressions (844 tests).
  These covered reset ownership, authorized synthesis teardown, Checkup
  retargeting/stale metadata, and replacement during reapply or teardown. The
  full xcresult was inspected because the Makefile prints only the first errors.
- Long HDR feedback clipping was separately reproduced using an offscreen AppKit
  layout, without presenting a window.

## Final verification

- `make test`: **2,709 engine tests passed**, exit 0.
- `make test-app`: **848 host-free app tests passed**, exit 0, with both opt-in
  rendering/capture tests enabled. The latest images are in
  `/tmp/candela-adversarial-ui-final`; light/dark duration controls and the dark
  OLED settings page were inspected for clipping.
- Independent final reviews found no further actionable issues in reset
  admission/cleanup, Checkup lifetime or scan-out recovery.
- `git diff --check` passed.

- `make markers SIGNING=adhoc`: Release built, and all six Mach-O files passed
  the debug-marker scan with its positive control, exit 0.
- `codesign --verify --deep --strict`: the candidate is valid on disk and
  satisfies its designated requirement, exit 0.

The local candidate is `DerivedData/Build/Products/Release/Candela.app` in this
worktree. It retains version metadata 1.0.4 and is an unreleased, ad-hoc-signed
test build. No source changed after the passing suites and build; the final
edits only record verification. Nothing was committed, pushed, posted or released.

Run logs: `/tmp/candela-adversarial-kit-final.log`,
`/tmp/candela-adversarial-app-final.log` and
`/tmp/candela-adversarial-release.log`.


## Limits

All regressions use fake hardware or offscreen UI. They do not replace the
[manual release checks](release-controls-verification.md), particularly physical
scan-out, lock brightness restoration, real NSMenu tracking and VoiceOver.
The earlier ImageRenderer displacement remains unexplained; this review does
not convert that diagnostic artifact into a claimed shipping UI fix.
