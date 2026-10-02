# Timed OLED dimming pause

Implemented on 2026-09-27. The September 29 LG UltraFine 5K LCD pass observed
custom pause, cancellation, expiry, overlay removal, Resume Now and unenrollment
refusal. Remaining lifecycle cases are listed below. No automated test changes
a connected display or launches Candela.

## Automated coverage

The host-free coordinator tests exercise pause deadlines, replacement,
independent display keys, session-only storage, reconnects, sleep-length time
jumps, immediate resume, reset and disconnected unenrollment. They drive the
production coordinator's dimming decision and telemetry qualification to
check that pausing lifts blackout, clears regional masks, keeps measurement
eligible and books an undimmed effective brightness. Mirror and checkup
suspensions retain their precedence.

Capture lifecycle tests delay real pipeline completions across pause and
resume. Obsolete captures are rejected without claiming the replacement
reservation. Engine tests cover idle, blackout, lock and unfocused dimming,
and a fresh idle interval after a pause expires during sleep.

All of these pass in the host-free app suite and the engine suite. The panel's
care line, the OLED Care page's Status line and its pause row are derived in
tested functions, which pin that a mirror or checkup suspension outranks a
pause on both surfaces.

## Manual verification still required

Record the display model, connection and observed results for each hardware
pass. Any enrolled external display, including an LCD, is suitable. An OLED
panel is not a merge or release requirement. Use two enrolled displays when
available; panel-specific wear or compensation testing is outside this change.

1. Let idle dimming or blackout engage. Pause that display for 15 minutes and
   confirm the picture returns immediately while the other display's care
   behavior is unchanged. Repeat while regional protection is visible.
2. Pause for one hour, then choose Resume Now. Confirm the shown deadline
   clears, the display stays bright for a fresh idle interval and normal
   dimming returns afterward. Regional dimming must gather new static evidence.
3. Pause before locking the Mac. Confirm lock dimming stays off and unlocking
   leaves saved brightness unchanged. Pausing an already active lock dim
   requires a deliberate manual harness because the pause controls are not
   available on the lock screen; verify the temporary brightness restore too.
4. Sleep through the deadline, then wake. Confirm no stale blackout or lock
   dim appears immediately. Check that macOS sleep behavior is unchanged.
5. Disconnect and reconnect before the deadline. Confirm the same physical
   display remains paused despite a changed display ID. Repeat after expiry;
   the display should start a fresh idle interval.
6. During an awake, unlocked pause, confirm hours and enabled Health readings
   continue. Check that ordinary mirror, checkup and sleep measurement gates
   still apply.
7. Turn enrollment off and back on, reset the display, reset all settings,
   and restart Candela in separate passes. None should retain the pause.
8. Replace a 15-minute pause with one hour and confirm the earlier deadline
   does not resume dimming. Check keyboard and VoiceOver access in both menus.

Real window-server removal, temporary brightness restoration, system sleep,
reconnection identity and accessibility are manual observations. The tests
above do not establish those hardware outcomes.
