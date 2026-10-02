# Everyday controls release verification

Branch: `feature/everyday-display-controls`, based on `bcc44c16`.

## Scope

Timed Keep Awake, per-display timed OLED dimming pause, optional pointer-targeted
HDR shortcut, readable brightness fixes, scan-out verification and recovery,
and a bounded rendering investigation. No resolution shortcut, favorite expansion,
restore-setup feature, new dependency, or main-panel redesign.

## Automated evidence

Baseline: 2,668 engine tests and 797 app tests passed in the isolated checkout.
Independent review additionally identified native-geometry retention after mode
quarantine and early timer callbacks after clock changes; both were reproduced
in a full 2,697-test run before fixes.

New tests first failed on missing behavior: Keep Awake (five assertions), OLED
pause (seven engine and 30 app assertions), HDR shortcut (nine assertions), and
scan-out recovery. Brightness regression evidence is in
[brightness-readback.md](brightness-readback.md). OLED lifecycle evidence is in
[timed-oled-dimming-pause.md](timed-oled-dimming-pause.md). Rendering evidence is in
[panel-rendering.md](panel-rendering.md).

Initial implementation integration: **2,697 engine tests and 817 host-free app tests passed**
with `make check` (exit 0). The opt-in renderer and native light/dark capture tests
were enabled; artifacts are in `/tmp/candela-release-ui-capture`. The independent
source review has no remaining actionable findings after the two fixes above.
The original discrepancy artifacts remain in `/tmp/candela-release-render-probe`.
After correcting the diagnostic Settings fixture to use its supported dark
appearance and adding Keep Awake disclosure captures, the full app suite passed
again: **817 tests, exit 0**. Final images are in
`/tmp/candela-release-ui-final`; the Keep Awake choices, paused OLED status and
Dimming card were visually inspected without clipping. No power assertion was
activated by the capture test.
`make markers SIGNING=adhoc` passed (exit 0): Release built successfully and
all six Mach-O files passed the debug-marker scan. `codesign --verify --deep
--strict` also passed. The local candidate is
`DerivedData/Build/Products/Release/Candela.app` in this worktree. It retains the
existing 1.0.4 version metadata; this is an unreleased test build, not a published
version. A subsequent adversarial review found and fixed additional lifecycle issues; its
verification supersedes these initial counts. See
[adversarial-release-review.md](adversarial-release-review.md).

## Adversarial review, September 28

After the parallel review and fixes, **2,709 engine tests and 848 host-free app
tests passed**. Both opt-in UI captures were enabled. The final light/dark panel
and dark OLED settings captures are in `/tmp/candela-adversarial-ui-final` and
were inspected for clipping. The independent final reviews reported no remaining
actionable findings. See the [review record](adversarial-release-review.md) for
reproductions and fixes. The final `make markers SIGNING=adhoc` Release build
and six-file marker scan passed; strict deep code-signature verification passed.
The candidate at `DerivedData/Build/Products/Release/Candela.app` now includes
these fixes. Physical display behavior remains unverified.

## Hardware pass, September 29

The candidate now carries **1.0.5** metadata and is Developer ID signed. It
launched successfully, About reports 1.0.5, and strict deep signature validation
and the six-file marker gate pass. The earlier ad-hoc artifact failed at launch
under hardened-runtime Sparkle library validation; its successful build was not
launch evidence. No runtime security exception was added.

A partial hardware pass on macOS 26.7 used the built-in display and an LG
UltraFine 5K. See [the hardware record](hardware-release-1.0.5-2026-09-29.md)
for achieved-state measurements and the remaining hardware-specific gates.
The checklist below remains the complete release gate; a partial pass does not
certify the unavailable OLED/HDR/OSD cases.

## Custom end-time controls, September 29

Keep Awake and OLED dimming pause now offer Until… with one native date/time
picker. Existing presets remain available. Opening, editing or cancelling has
no effect until confirmation. Confirmation validates the future deadline and
rechecks the display's identity, enrollment and reset state for OLED pause.
Status text includes the date for deadlines beyond today.

**2711 engine tests and 856 host-free app tests passed.** The full app suite
also passed with opt-in light/dark menu and picker captures enabled. The
Developer ID Release build and six-file debug-marker gate passed. Live native
checks verified invalid-date layout, cancellation, Keep Awake assertion reuse
and real expiry, OLED overlay removal, pause expiry with a fresh idle grace
period, Resume Now and refusal after unenrollment. HDR shortcut recording,
unsupported-target dispatch, focus preservation and chord removal also passed.
See the [hardware record](hardware-release-1.0.5-2026-09-29.md) for the exact
candidate fingerprint, restoration and remaining physical-hardware gaps.

## Slider and picker refinement, September 30

Keep Awake now has a stepped duration slider inside its disclosure, while the
compact row retains a simple toggle. The shared custom end-time window uses
Settings' dark window, card and button styles. See
[panel-rendering.md](panel-rendering.md) for the native tracking defect, its
regressions and the difference between host captures and actual menu sizing.

The final app suite passed **858 tests in 85 suites**, and all seven Panel sizing
tests passed with `TEST_RUNNER_CANDELA_NATIVE_MENU_TEST=1`. That opt-in run
verifies the real menu grows, stays visible with the complete footer, and closes
for the custom end-time picker. The Developer ID Release build, six-file marker
gate and strict deep signature validation passed. Final logs are
`/tmp/candela-panel-refit-final-app.log`,
`/tmp/candela-tracking-picker-settled.log` and
`/tmp/candela-panel-refit-final-release.log`.

The final signed candidate launched successfully as process 9435 from this
worktree's `DerivedData/Build/Products/Release/Candela.app`, reporting 1.0.5.
Its executable SHA-256 is
`b99497c374715380e4fc32508955cf1f1631558430701d53b561b95385df2314`.
The live verification used the built-in Color LCD only. No external display was
connected during this pass, so it adds no new OLED, external HDR or OSD results.

The actual menu grew from **154 to 257 points** on expansion and returned to
154 on collapse. The slider disappeared when collapsed. Selecting one hour
while off left Keep Awake off. Turning on started that duration; changing to
15 minutes and then indefinite reused the same power assertion. Switching off
removed the Candela assertion. Custom end time opened the styled window with
no menu remaining behind it, and Cancel left Keep Awake off. One current
candidate remains running, the test dialog is closed and no Candela Keep Awake
assertion remains. Live output and actual window captures are in
`/tmp/candela-timer-refinement-live/verification.txt`,
`/tmp/candela-timer-refinement-live/single-display-expanded.png` and
`/tmp/candela-timer-refinement-live/end-time-restyled.png`.

## Custom picker and anchored animation, September 30

The shared end-time dialog now uses a custom calendar, separate spacious hour
and minute fields, and an AM/PM control when the locale uses a 12-hour clock.
The window uses the existing Settings appearance and remains 420 × 399 points
with both valid and invalid input. The draft rejects invalid time fields,
past deadlines, out-of-range dates and nonexistent local times. Unit coverage
includes 12/24-hour formats, midnight/noon and DST transitions. Earlier live
checks confirmed invalid hour/minute values disable confirmation, month
navigation updates the date, and Cancel leaves Keep Awake off. Calendar focus
supports arrow keys and Space/Return. The final live check on the build below
selected October 1 using Right Arrow and Space, displayed the matching 4:14 PM
deadline, and enabled confirmation.

The final app suite passed **868 tests in 86 suites**, including native tracking
checks for both the built-in-only and scripted external-display layouts. Both
measured zero brightness-control movement while opening, closing and reopening
Keep Awake. The same tracking window stays open and its top edge stays fixed.
See [panel-rendering.md](panel-rendering.md) for the reproduced causes and fixes.
Log: `/tmp/candela-slider-anchor-full-app.log`.

The Developer ID Release build, six-file debug-marker gate and strict deep
signature validation passed. Build log: `/tmp/candela-slider-anchor-release.log`.
The new candidate is running from the release worktree as process **32148**,
reporting **1.0.5**, with executable SHA-256
`ce800b132ba24887cca2b91f8dfa8ac5ee5273bfa93347e4700de46ee0782a43`.

On the running app with Color LCD only, the native menu expanded from **154 to
257 points** and collapsed back to **154**, passing through intermediate sizes.
It retained the same window and top edge. The Color LCD brightness slider stayed
at `(1168, 81, 252, 30)` in global screen coordinates with **0 points** of measured
movement. Live collapse output is in
`/tmp/candela-slider-anchor-live-collapse.log`. A later expansion sample captured
only its endpoints, so that sample is not additional animation-timing evidence.

Confirming the custom October 1 deadline dismissed the dialog and created
`Candela Keep Awake` assertion `0x000586e500058926`, owned by process 32148.
Reopening the menu showed the chosen deadline and the on toggle. Turning it off
removed the Candela assertion. The test dialog and menu are closed. Hidden Bar
was temporarily stopped to expose the status icon and was relaunched afterwards.
Only the current signed candidate remains running. This adds no new external
HDR, OLED, scan-out or OSD hardware results.

## Manual release gate

Use the built application on the intended monitors before release:

1. Open the menu in light and dark appearance, use the duration disclosures with
   keyboard and VoiceOver, and confirm core sliders and footer remain reachable
   on a short screen and with multiple displays.
2. Choose timed Keep Awake. Check `pmset -g assertions` for **Candela Keep Awake**;
   verify replacement, off, expiry with the menu closed, and sleep past expiry.
3. On any enrolled external display, including an LCD, trigger each enabled
   dimming mode, then pause. Confirm
   overlays clear and temporary lock brightness restores; measurement still
   advances. Test Resume Now, expiry, reconnect, unenrollment and app relaunch.
4. Assign the HDR shortcut. Test each external display, built-in pointer,
   unsupported display, active preview, Checkup, settings reset and synthesized
   size. Try the panel HDR button and shortcut during the same transition. Confirm the result
   on the monitor, one target only, and no unwanted focus change from feedback.
5. On a readable external display with physical OSD controls, change brightness in the
   software-dim and hardware ranges. Verify the menu adopts it and clears stale
   software dimming without changing saved resume intent.
6. Start Checkup, cancel or close during HDR, and confirm HDR cleanup finishes
   before mode restoration. Confirm other display changes and settings reset
   stay blocked until cleanup finishes. Repeat after disconnecting the target.
7. With a display preview open, confirm Reset Settings refuses before changing
   anything. Start reset and confirm mode, rotation, mirroring, arrangement and
   HDR changes remain blocked through cleanup. For Reset All, assign an HDR
   shortcut first and verify its old chord is released after reset.
8. Inspect the actual native menu for issue #94. The renderer probe has localized
   inconsistent first-frame glyph placement but does not establish a product UI
   defect; no warm-up or tolerance workaround was applied.

No connected-display changes or app installation are performed by the automated
suite. This checklist is the remaining hardware/accessibility verification, not
a claim that physical behavior has already been certified.


## Current candidate after compact-header correction, September 30

The earlier anchored-animation candidate was superseded after a real pointer-click
recording reproduced a one-frame Keep Awake header flash in the 154-point menu.
The corrected candidate uses synchronous native disclosure ownership and a panel
layout that reserves the existing display viewport. The final recording contains
81 captured frames across two expansions and two collapses, with no displaced
Keep Awake header. Details are in [panel-rendering.md](panel-rendering.md).

The full app suite passed **869 tests in 86 suites** with native tracking checks
enabled. The no-banner, banner and scripted-external fixtures all measured zero
points of existing-control movement. The Developer ID Release build passed the
six-binary marker gate and strict deep signature verification. Build log:
`/tmp/candela-awake-owned-release.log`; test log:
`/tmp/candela-awake-owned-full-app.log`.

The currently running signed 1.0.5 candidate is process **50586**, launched from
`DerivedData/Build/Products/Release/Candela.app` in this release worktree.
Executable SHA-256:
`8be90b45e6815595df7f13fd8bd700b3f497ba40eefb4e620804953a61882431`.
The menu is closed, Keep Awake is off, and no Candela power assertion remains.
Hidden Bar was relaunched after testing and is running. This verification used
only the physical Color LCD and adds no external HDR, OLED, scan-out or OSD
hardware results; the manual release gate above still applies.


## Built-in verification, September 30

The compact-header candidate above underwent another physical built-in-display
pass. Independent brightness movement and restoration, custom real-clock expiry
with the menu closed, actual VoiceOver navigation, temporary short-screen layout
and native display sleep/wake were observed. No product code changed. Full
system sleep and ordinary Tab traversal remain unresolved, and macOS locked the
session after display sleep/wake. See
[the built-in hardware record](hardware-built-in-1.0.5-2026-09-30.md) for exact
verdicts, skipped checks, restoration and external-display blockers.

## Slider activation and merged-main sync, October 1

The primary `main` checkout and this release worktree were updated to GitHub
`main` at `0022079d57f00ecfc9dbcfae39dbef7dcdb1f4c1`. The pending 1.0.5
changes were preserved, including a retained pre-sync stash and backups in
`/tmp/candela-release-pre-sync-2026-10-01.patch` and
`/tmp/candela-release-pre-sync-untracked.tar.gz`.

The candidate now includes Sparkle 2.10.0, KeyboardShortcuts 3.1.0, timer
tolerance, the merged engine fixes and the panel/setup/test changes. Integration
retains the new auto-hidden-menu height calculation, display viewport anchoring,
scroll bounce policy, unfiltered achieved-mode evidence and hermetic test
preferences. The pending scanout verification API remains alongside the merged
`achievedMode(for:)` API. Stale calls and preference cleanup left by the merge
were corrected; no unresolved conflicts remain.

Selecting a Keep Awake duration now enables its assertion even when the toggle
was off. This supersedes the earlier September 30 observation that selecting
while off only previewed a duration. The slider still appears only when expanded;
the compact row retains its on/off toggle. A small native stepped-slider wrapper
reports mouse selection after tracking finishes, including a click on the
already-selected stop. The binding avoids restarting an already-active hold
when the selected duration is unchanged.

Actual menu clicks against the preserved September 30 executable reproduced the
bug: selecting one hour moved the slider but left the toggle off, with no Candela
power assertion. The final signed candidate, process 9075, passed these real
menu checks using accessibility state and independent `pmset -g assertions`
readback:

| Interaction while off | Observed result |
| --- | --- |
| Click one hour | Toggle on, one-hour deadline, one assertion `0x00065a01000584bc` |
| Click the same one-hour stop again after switching off | Toggle on, one-hour deadline, one assertion `0x00065a0a000584be` |
| Drag from one hour to two hours | Toggle on, two-hour deadline, one assertion `0x00065a23000584c1` |
| Accessibility increment from two hours | Toggle on, four-hour deadline, one assertion `0x00065a2b000584c3` |
| Click the indefinite stop | Toggle on, “Until turned off”, one assertion `0x00065a44000584c5` |

The native menu remained 280 × 257 points expanded. Its duration slider stayed
centered at the same position; its native accessibility value now reads the
duration text. The compact row again exposed only the disclosure and toggle.
A window capture was inspected for layout; as in the earlier hardware record,
per-window capture can omit the separate composited thumb layer.

Final `make check` passed 2,723 engine tests and 875 app tests. Final
`make markers SIGNING=developer-id` passed its positive control and found no
debug markers in six Mach-O files. No new compiler warnings remain. All embedded
code objects and the app were signed with Developer ID; strict deep signature
verification passed. Logs are `/tmp/candela-synced-release-final-check.log` and
`/tmp/candela-synced-release-build.log`.

The executable SHA-256 is
`bc40d804eb8bccfd7307a7a71d21e4dd5c4f5bf057afbcdd3c401473efb6d6ac`.
The running app is this worktree's `DerivedData/Build/Products/Release/Candela.app`,
version 1.0.5. Keep Awake is off, no Candela power assertion remains, the menu is
closed, Hidden Bar has been restored, and built-in brightness remains 0.5.
The applicable external-display and full-system-sleep release gates remain
outstanding, subject to the scope update below; this check does not replace them.


## Verification scope update, October 1

The scan-out safety hardware pass is deferred from both the 1.0.5 merge and
release requirements. MSI cropped-timing reproduction, monitor-OSD timing
comparison and same-model timing isolation are optional follow-up investigations.
Their observed limitations and automated coverage remain recorded in
[the scan-out evidence](display-scanout-verification.md); deferral is not a
claim that those physical tests passed.

An OLED panel is not required for testing the new dimming-pause controls.
Any enrolled external LCD can exercise overlay removal, resume, deadlines,
lock-brightness restoration, usage/capture continuity, reconnect and reset.
Panel-specific OLED wear or compensation behavior is outside this change's
verification scope. Successful HDR switching still requires an HDR-capable
external display, which can also be an LCD.

The LG UltraFine 5K LCD pass already observed custom-pause cancellation,
confirmation, usage counting during pause, real-clock expiry, overlay removal,
Resume Now and refusal after unenrollment. Remaining pause checks concern the
software lifecycle on an enrolled external display, not its panel technology.
See [the original pass](hardware-release-1.0.5-2026-09-29.md) for exact evidence
and [the pause checklist](timed-oled-dimming-pause.md) for follow-up cases.
