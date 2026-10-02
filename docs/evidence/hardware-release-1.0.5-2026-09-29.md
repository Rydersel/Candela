# 1.0.5 hardware verification: September 29, 2026

## Candidate and rig

Uncommitted candidate on `feature/everyday-display-controls`, based on
`bcc44c16`; the base commit alone does not identify this build. Product:
`DerivedData/Build/Products/Release/Candela.app` in the managed checkout.
`project.yml` now sets version 1.0.5. About visibly reports 1.0.5.

Apple M1 Pro, macOS 26.7 (25G229), built-in Color LCD and LG UltraFine 5K.
Initial/current geometry: built-in 1800 × 1169 logical, 3600 × 2338 framebuffer,
120 Hz; LG 2560 × 1440 logical, 5120 × 2880 framebuffer, 60 Hz. Neither
reports HDR modes. No OLED, MSI cropping-case panel, or second identical panel
is attached.

`make markers SIGNING=developer-id` passed, including all six Mach-O files.
`codesign --verify --deep --strict` passed outside the filesystem sandbox.
App and Sparkle share the configured Developer ID team. The ad-hoc Release
candidate failed at launch with DYLD library validation rejecting Sparkle's
missing team identity. The Developer ID build launches without changing runtime
security settings. The installed 1.0.4 app was closed; one candidate instance
was verified before hardware writes. Nothing was published or notarized here.

Raw captures, preference backup, readbacks and build log:
`/tmp/candela-hardware-2026-09-29/` and
`/tmp/candela-custom-time-hardware/` (local, temporary evidence).

The final candidate includes custom end-time selection and the HDR helper-copy
change. Its executable SHA-256 is
`ac7d0ce8429f7c33b1728a20915453430a1856be23917a904aadad9c21633b63`.
The signed candidate relaunched successfully after the pass.

## Observed results

- **Native panel:** dark menu visibly renders cleanly, including combined and
  individual brightness controls, resolution/mirroring, Keep Awake and footer.
  Controls expose distinct accessibility labels. This sampled opening did not
  reproduce issue #94; it does not resolve the intermittent renderer discrepancy.
- **Keep Awake:** opening duration choices leaves the toggle off. One hour
  creates a `Candela Keep Awake` macOS assertion owned by the candidate. Changing
  to Until Turned Off retains one assertion and changes accessible status.
  Turning off removes Candela's assertion. An unrelated `caffeinate` assertion
  remains; the system-wide sleep-prevention flag is therefore not the verdict.
  The real 15-minute test began at 22:02:47 UTC, deadline 22:17:47 UTC.
  Candela's assertion was still present at 22:16:22 UTC. At 22:18:13 UTC,
  with the menu closed and the candidate still running, assertion count was
  zero before any menu interaction: real-clock expiry passed. No system clock
  adjustment was used.
- **Brightness:** LG UI 0.52 corresponds to DDC 4/100 with the configured
  combined-dimming split. An accessibility increment produced UI 0.55 and
  independently read DDC 10/100. Decrement snapped to UI 0.50 / DDC 0/100.
  Writing the original DDC 4 outside the app was read back as 4, and Candela
  adopted UI 0.52 again. A separate software-floor test reached UI 0.45,
  DDC 0/100 and gamma top 0.9150. An external DDC write to 4/100 cleared
  gamma back to 1.0000 and the settled UI adopted 0.52. Both displays' gamma
  returned to 1.0000. This tests external readback across the floor, though
  the physical monitor OSD itself was not exercised. Native brightness
  remains built-in 1.0 and LG 0.6907608.
- **Resolution preview:** selecting 2880 × 1620 produced an inline keep/revert
  countdown. Independent CoreGraphics/NSScreen readback measured logical
  2880 × 1620, framebuffer 5760 × 3240, 60 Hz. The countdown automatically
  restored logical 2560 × 1440 / framebuffer 5120 × 2880. A second successful
  preview restored through Revert Now. No mirroring or virtual display remained.
- **Platform conformance:** rotation 0° → 90° → 0° verified on LG;
  DisplayServices writes/reads the unchanged built-in brightness 1.0.
  Descriptor bounds, field agreement, plausibility, density, platform symbols
  and DDC reply validation passed. `conform --apply` reports **19 pass,
  1 fail, 1 skip**. Do not report this command as green.
- **Hidden-mode canary limitation:** its failure assumes at least one attached
  panel reveals modes. Direct engine diagnostics account for all 167 entries:
  built-in 132 already published; LG 25 already published and ten marked
  unusable by macOS (`0x40000000`). No plausible eligible mode was rejected.
  This rig cannot provide a positive hidden-mode/apply control. The existing
  canary's failure remains in the raw record; no product filter was weakened.
- **Checkup:** EDID observed; brightness read 4, wrote 4, read 4/100;
  contrast explicitly refused for no read reply; volume explicitly not observed
  because not advertised. Native 5120 × 2880 and 60 Hz sweep observed, with
  independent geometry readback. Reset All Settings was disabled while the
  Checkup held its operation claim. Closing before subjective visual fields
  restored reset availability and left original geometry and brightness intact.
- **HDR shortcut:** recorded Control-Option-Command-H through the native recorder.
  With the pointer on LG, dispatch reported no HDR modes. With the pointer on
  the built-in display, it requested an external target. Finder stayed frontmost
  during feedback. Clearing the recorder removed the saved chord; sending it
  again produced no feedback. Native readout remained HDR false for both panels.
  Successful HDR transitions still need a supported panel.
- **Custom Keep Awake:** opening and cancelling Until… created no assertion.
  A past date disabled confirmation and showed validation without clipping.
  The custom 22:45:00 UTC deadline created one assertion; reopening retained the
  deadline and cancelling retained the same assertion ID. Real-clock expiry
  removed the assertion. No clock adjustment was used.
- **Custom OLED pause:** temporarily enrolled LG to test the software flow.
  Cancelling left it unpaused. Confirming 22:47:00 UTC showed the chosen deadline
  in Settings; usage counting advanced during the pause. Exposure capture stayed
  disabled. After expiry and a fresh idle grace period, the actual dimming overlay
  appeared. A second custom pause removed that observed overlay. Resume Now
  cleared the pause. Unenrolling while the picker was open caused confirmation
  to refuse the stale target. Enrollment and the five-minute idle delay were
  restored. This validates dimming software on an LCD, not physical OLED behavior
  or exposure measurement. The final relaunch left no care overlay.
- **Active scan-out:** independent timing reads reported built-in 3024 × 1964
  at 120.000473 Hz and LG 5120 × 2880 at 59.999893 Hz. These distinguish panel
  timing from the built-in's larger framebuffer. No monitor OSD comparison was
  available. A synthesized-size UI check was attempted, but Settings would not
  take focus and the native Size menu did not open through automation. No mode
  was applied, and More sizes was restored to off. This check is incomplete.
- **Reset during preview:** the entry button remains enabled; refusal occurs
  in the shared gate when reset is requested. Destructive confirmation was not
  exercised against real saved settings. Existing automated gate tests cover
  refusal, but this is not a completed hardware check.

## Remaining release gates

Physical OLED behavior, exposure measurement, lock-dimming restoration and
reconnect; successful HDR transitions, cancellation/disconnect cleanup and
competing HDR actions; physical brightness OSD changes including the software
floor; scan-out versus monitor OSD, synthesized-size verification, MSI cropped
timing restoration and same-model isolation; sleep across the Keep Awake
deadline; VoiceOver and keyboard traversal, live light appearance and short-screen
menu access; destructive reset/shortcut release on a disposable setup.
The normal notarization and publication gates have not been performed.

After the custom-time changes, full source suites passed: **2711 engine and
856 host-free app tests**. The 856-test app suite also passed with opt-in UI
captures enabled. The Release build, all six debug-marker checks and strict
deep signature verification passed. Logs are in `/tmp/candela-custom-time-*.log`.
Live dialog screenshots in the custom-time hardware folder verify native layout;
offscreen dialog captures alone do not certify AppKit rendering.

## Final restoration

One signed 1.0.5 candidate instance remains running from the managed checkout;
the `/Applications` copy is still 1.0.4. Both original display modes, native
brightness readings, LG DDC 4/100 and gamma top 1.0000 were verified after
relaunch. No Candela Keep Awake assertion or care overlay remains. More sizes
is off, LG is unenrolled, the idle delay is back to its original default, and
the temporary shortcut is removed. Test-created explicit default keys were
removed after quitting. The final preference comparison retains the usage and
wear history accrued during temporary enrollment; control preferences match
the pre-test backup. No user history was rolled back.


## Current verification scope, October 1

The earlier remaining-check list reflects the scope at the time of this pass.
The scan-out safety hardware pass is now deferred from the 1.0.5 merge and
release requirements. An OLED panel is also not required: the dimming-pause
lifecycle can be verified on any enrolled external LCD. The historical results
above remain unchanged. The [current checklist](release-controls-verification.md)
and [pause checklist](timed-oled-dimming-pause.md) define the remaining work.
