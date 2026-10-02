# Brightness readback

Related issue: [#104](https://github.com/Rydersel/Candela/issues/104).

## Policy audit, September 27, 2026

The MSI MAG 341C's earlier write-only classification was incorrect. The DDC
request checksum was wrong; corrected requests returned usable values. The
[firmware evidence](oled-protection/firmware-boundary.md#independent-readback)
records that correction. A saved setting records app intent when reads fail;
it cannot confirm the monitor's current state or a successful write.

`AppModel.performRefresh` reads external brightness at launch and after menu
close, plus topology and wake refreshes. Kept controllers drain pending writes
before reading. Readable values update both the slider and saved brightness.
The brightness read does not depend on the General startup action; volume and
contrast reads do. Safe Mode skips the external brightness read entirely.

Opening the menu takes a synchronous native-brightness read, but does not send
DDC reads. DDC changes made in the monitor's OSD are therefore adopted on the
next completed refresh, normally after closing the menu. Reopening then shows
the adopted value. The periodic brightness poller reads only the native path;
this change adds no routine DDC polling.

Readback respects remapped registers, min/max overrides, curves and inversion.
A missing or invalid response preserves the saved value. A valid `current: 0,
max: 100` response is distinct from an unusable zero response. Two consecutive
matching failures can suspend reads until wake, reconfiguration, HDR changes
or a register change gives the connection another attempt. Silence during a
topology-settling pass does not count toward that suspension.

Reads skip forced-software and native/HDR paths, disabled DDC brightness,
active temporary dimming and interrupted-dim recovery markers. A write that
starts while a read is in flight supersedes its value. The panel's reported
maximum can still be retained without overwriting the user's newer brightness.

## Defects reproduced and fixed

The combined-brightness read used the raw register's zero as its ambiguity
check. That broke inverted settings and nonzero minimum overrides. It also
ignored an OSD move to the hardware minimum while the slider was above the
combined switching point. The check now uses the mapped hardware portion and
preserves an existing software-range value only when the read cannot
distinguish it from another value in that range.

An OSD rise from the software range updated the slider but left Candela's
gamma or shade dim in place. Adopting a hardware-range value now restores full
software brightness without writing the reported DDC value back to the panel.

`BrightnessReadbackTests` covers gamma and overlay cleanup, an OSD move to
zero from the hardware range, inverted register zero, and tuned hardware
floors with and without inversion. The new tests failed with 11 assertions
before the fix. The full hardware-free engine suite then passed 2,672 tests.
Existing coverage retains forced-software, temporary-dim, failed-read,
remapped-register and in-flight write guards.

## Physical verification still required

No connected display was changed during this investigation. Verify with the
MSI MAG 341C on its actual connection, recording the cable/adapter, HDR state
and build:

1. In SDR, change brightness through the monitor OSD. Close and reopen the
   Candela menu and confirm that the slider and saved brightness adopt the
   readable value. Check an ordinary nonzero setting and the hardware minimum.
2. Start below the combined switching point, then raise brightness through the
   OSD. After refresh, confirm that both the slider and visible output leave
   software dimming. Exercise Gamma and Overlay separately.
3. Repeat the hardware-floor check with any minimum, maximum or inversion
   settings used on that display. A floor read must preserve a software-range
   setting while a nonzero mapped hardware value must adopt the hardware range.
4. During temporary dimming, confirm that refresh does not save the dimmed
   register as the user's brightness. Resume and confirm the original level.
5. Confirm HDR/native and forced-software behavior remains consistent with its
   respective controls. Record any unavailable reads rather than treating a
   write acknowledgement as achieved output.
