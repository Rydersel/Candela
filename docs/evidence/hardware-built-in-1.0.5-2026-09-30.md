# Built-in display verification, September 30, 2026

## Candidate and rig

Current uncommitted candidate on `feature/everyday-display-controls`, using the
signed Release application in this worktree. The executable SHA-256 is
`8be90b45e6815595df7f13fd8bd700b3f497ba40eefb4e620804953a61882431`.
The same candidate was relaunched to expose its status item after temporarily
closing Hidden Bar. It remains running as process 54414. No source change or
new build was made during this pass.

Only the physical Color LCD is connected. macOS 26.7, build 25G229. Original
mode is logical 1800 × 1169, framebuffer 3600 × 2338, 120 Hz, mode ID 66.
Native brightness was 0.5 at the beginning and end. HDR capability and state
both report false. Raw logs, screenshots and the preference snapshot are in
`/tmp/candela-built-in-2026-09-30/`.

## Observed results

- Actual native menu captures were inspected in light and dark appearance.
  The expanded layout and footer fit at 280 × 257 points. Per-window capture
  does not consistently include the duration thumb, so these images alone do
  not certify every composited slider layer. The preceding rendered-frame
  animation check and the user's successful visual check remain separate
  evidence. Original dark appearance was restored.
- Right Arrow changed the built-in brightness slider from 0.5 to 0.55.
  Independent DisplayServices readback measured 0.54999995. Returning the
  slider to 0.5 independently read back as 0.5.
- Actual VoiceOver output read the custom picker's hour and minute fields,
  AM/PM controls, deadline and Cancel. VoiceOver performed Cancel. It then
  read the native menu group, brightness slider, disclosure and toggle,
  activated the disclosure, and reached the duration slider and custom-time
  button. VoiceOver was turned off afterwards. No permission was changed.
- Ordinary Tab did not advance from the brightness slider, including after
  temporarily enabling keyboard navigation with Control-F7 and reopening the
  menu. The Right Arrow positive control proves keyboard events reached the
  slider. This is an unresolved keyboard-access result, not a passed check.
  The original global keyboard-navigation value, 0, was restored.
- The custom picker set a real September 30, 5:06 PM Central deadline. It
  created one Candela assertion, ID `0x0005a0bb00058ded`, owned by process
  54414. Sampling observed the assertion before expiry and zero assertions at
  5:06:00.327 PM, before reopening the menu after that deadline. A second
  post-deadline sample also reported zero. No system clock change was made.
- Published mode 12 was applied at preview scope for 20 seconds. Independent
  CoreGraphics and NSScreen measurements confirmed logical 1024 × 665,
  framebuffer 2048 × 1330, 120 Hz. The actual expanded menu was 280 × 257 at
  screen position 378,27, with its footer visible. The probe exited 0 and the
  display automatically returned to mode 66 and its original geometry.
- Platform conformance with apply enabled recorded 18 passes, one failure and
  two skips. Rotation 0 → 90 → 0 and a same-value brightness write/read passed.
  The failure is the previously recorded hidden-mode positive-control
  limitation: all 132 built-in modes are already published, leaving no
  additional revealed mode to apply. DDC and revealed-mode application were
  skipped. The command exited 1 and must not be reported as wholly green.
- `candela-probe regress --apply` recorded five passes, zero failures and seven
  skips. The running-app, log, gamma and Settings identifier controls passed.
  Display sleep/wake passed with actual sleep intake, wake intake and topology
  quiet-window log entries, and zero DDC writes after wake. External DDC,
  combined dimming, sync, mute and Release debug-dump cases were skipped.
  This proves display sleep/wake, not full system sleep across a deadline.

## Blockers and restoration

macOS locked the session after display sleep/wake. The subsequent HDR recorder
attempt could not operate the actual Settings UI. No shortcut was recorded or
saved. Foreground inspection identified `com.apple.loginwindow`; further
interactive work stops until the user unlocks the Mac.

Full system sleep across a deadline remains manual. Scheduling an unattended
wake requires administrator authentication, and `sudo -n -l` reported that a
password is required. No wake schedule was changed. Destructive Reset All was
not performed against the user's saved setup or wear history.

The final exported Candela preference domain exactly matches the initial
snapshot. Brightness, mode, rotation, dark appearance and keyboard-navigation
setting were restored. Keep Awake is off and no Candela power assertion remains.
Hidden Bar was relaunched. The original signed 1.0.5 candidate remains running.

Successful HDR switching and competing/cancelled transitions, OLED care and
measurement, physical monitor OSD changes, DDC behavior, scan-out versus OSD,
synthesized-size and cropped-timing recovery, same-model isolation and external
reconnect require the appropriate external monitor. Ordinary Tab traversal and
full system sleep remain separate manual or interactive checks.


## Current verification scope, October 1

The earlier remaining-check list reflects the scope at the time of this pass.
The scan-out safety hardware pass is now deferred from the 1.0.5 merge and
release requirements. An OLED panel is also not required: the dimming-pause
lifecycle can be verified on any enrolled external LCD. The historical results
above remain unchanged. The [current checklist](release-controls-verification.md)
and [pause checklist](timed-oled-dimming-pause.md) define the remaining work.
