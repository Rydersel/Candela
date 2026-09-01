# ColorSync leak inspection and repair

A virtual display leaks TWO permanent system-wide artifacts per identity, not
one:

1. A colour profile in `/Library/ColorSync/Profiles/Displays/<name>-<UUID>.icc`
2. A **device registration** in the any-user-scope ColorSync device registry

Deleting the `.icc` removes only layer 1. The registration survives profile
deletion **and reboots**, and dead registrations are not inert: with enough of
them, `colorsync.useragent` / `colorsyncd` loop
`ColorSyncIterateDeviceProfiles` → `findDevice` → sync XPC, burning ~150%
aggregate CPU and freezing System Settings → Displays (which talks to
`colorsync.displayservices`, the service named in the original incident's watchdog trace).

[MEASURED 2026-08-05] 148 dead registrations — 5 from that day's rig run plus
~143 from the original orphan incident, whose profiles had been deleted but
whose registrations never were — kept this from boot until repaired.

## Tools

```sh
clang -framework Foundation -framework ColorSync -o csdevices csdevices.m
clang -framework Foundation -framework ColorSync -o csclean   csclean.m

./csdevices          # list every registered display device + its profile URL
sudo ./csclean       # unregister every device whose profile URL is dead
```

## Two measured traps

- A dead entry carries **`NSNull`** for `kColorSyncDeviceProfileURL`, not a
  missing key. A presence check finds nothing; check for NSNull too.
- `ColorSyncUnregisterDevice` **returns `true` from a non-root process while
  removing nothing** — the registrations live in the any-user scope. Run the
  cleanup as root, and verify with `csdevices` afterwards rather than trusting
  the return value. (The platform's "reports success it did not achieve"
  family, seventh member.)

## For the rig

Teardown must eventually do both layers and assert BOTH counts unchanged
across a run — profile files and registry entries. That integration is not
wired into `rig.sh` yet; until it is, run `csdevices` after any rig session
and `sudo csclean` if it shows dead entries.
