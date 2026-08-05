# vdrig — the two-process virtual-display test rig

Brings up 1–3 `CGVirtualDisplay`s, runs your tester against the resulting
topology, tears everything down, and **proves** the machine came back to where
it started. It exists so that arrangement, mirroring, topology matching and
multi-display behaviour can be verified on a Mac with one panel attached.

It has been built and thrown away twice. It is committed now.

```sh
tools/vdrig/build.sh                                   # build + guard 1
tools/vdrig/rig.sh --count 3 --keep-awake -- ./my-test # run something
tools/vdrig/build/topology                             # just look
```

---

## Read this before you run it

Three measured facts shape every design decision below. Each cost real damage
once.

**1. A virtual display is not always reclaimed when its owner dies.** With the
built-in panel asleep, a virtual display becomes the only *active* display, and
WindowServer will not remove the machine's last active display. One survived
object release, survived `SIGKILL`, and stood for **over two minutes with no
owner process alive**. It vanished within a second of `caffeinate -u`.
`caffeinate -dis` does **not** wake a sleeping panel. So the rig never assumes
its displays die with it — it verifies, escalates, and shouts if it fails.
(S1 §5A.)

**2. A virtual display permanently leaks a colour profile per identity.** macOS
writes an `.icc` per display identity into `/Library/ColorSync/Profiles/Displays/`
and **never removes it** — not on teardown, not on process death, not on reboot.
A previous rig minted a fresh identity per run and per case and left **143
orphaned profiles**, which drove the ColorSync daemons to 59% CPU; removing the
143 took the same daemon PIDs to 0.0% with no reboot. So this rig has a **fixed
identity table** in `src/vdrig.h`, reused by every run forever, and it asserts
the profile count is unchanged across every run. (S1 §5B.)

**3. One process can enumerate display modes for only the *first* virtual
display it creates.** Later ones report zero modes; neither the run loop nor the
reconfiguration callback helps. That is why this is a *two-process* rig: the
`holder` owns the displays, and your tester runs somewhere else.

---

## The pieces

| | |
|---|---|
| `src/holder.m` | Owns 1–3 virtual displays, created in a burst. Announces `READY <id> <w>x<h>` per display and `READY-ALL <n>`, then parks. Tears down on SIGTERM/SIGINT/SIGHUP, and self-terminates after `--max-life` so an orphan cannot live forever. |
| `src/topology.m` | Read-only. Dumps the display topology sorted by display ID, one line each, in a form `diff` can compare. |
| `src/vdrig.h` | The private `CGVirtualDisplay*` interfaces, and **the fixed identity table**. |
| `rig.sh` | The orchestrator. Start holder → wait for `READY-ALL` → run tester under a deadline → tear down → verify. |
| `build.sh` | Builds both tools and enforces guard 1. |
| `examples/` | Three tiny testers: one that passes, one that exits 17, one that overruns its deadline with a grandchild. |

Build output lands in `build/`, which is gitignored. **The binaries are not
checked in — run `build.sh` first.**

### Your tester's contract

`rig.sh` runs whatever follows `--`, with these in the environment:

| variable | |
|---|---|
| `VDRIG_COUNT` | how many virtual displays are up |
| `VDRIG_DISPLAY_IDS` | their `CGDirectDisplayID`s, space separated, in creation order |
| `VDRIG_TOPOLOGY` | path to the `topology` binary |
| `VDRIG_BASELINE` | path to the pre-create topology dump |
| `VDRIG_RUNDIR` | the run directory (logs, all topology dumps, profile listings) |

The tester's exit code is the rig's exit code. See the precedence rule below.

### Topology dump format

```
display 44 origin=1800,0 size=1920x1080 main=0 builtin=0 active=1 asleep=0 \
  vendor=0xCA1D model=0x1001 serial=0x1 mirrors=0 unit=3 uuid=1381… name="Candela Rig Slot 1"
count 4
```

- Enumerated with `CGGetOnlineDisplayList`, **never** `CGGetActiveDisplayList` —
  online means active *or mirrored or sleeping*, and with the panels asleep the
  active list reads zero.
- `builtin` is printed raw because `CGDisplayIsBuiltin` returns **-1**, not 0,
  for an unknown display ID.
- `vendor`/`model`/`serial` are Candela's `DisplayConfigIdentity`, printed so a
  reader can see a collision rather than assume it from the descriptor.
- `--stable` omits `active`, `asleep` and `name`. Those are not topology: the
  panel dozes off on its own, the rig's own recovery wakes it, and `NSScreen`
  drops mirror slaves so a name can vanish without anything moving. The restore
  check diffs `--stable`; the full dumps are kept alongside.

---

## The guards, and why each exists

### Guard 1 — the rig performs no display reconfiguration of its own

It creates and destroys virtual displays. It never sets origins, modes,
mirroring or prefs. If it did, it would be changing the thing it is supposed to
be measuring.

`build.sh` enforces this mechanically against **comment-stripped source** and
against **each binary's undefined imports** (`nm -u`). Both are needed and catch
different things: a C call shows up in `nm -u`, an ObjC selector like
`engageMirror` does not, and a comment naming a banned symbol must trip neither.

**The scanner is self-tested on every build**, before it is trusted: a fixture
that really calls `CGConfigureDisplayOrigin` must be rejected, a fixture that
only names banned symbols in comments must pass, and a compiled binary importing
`CGBeginDisplayConfiguration` must be rejected. A check nobody has ever seen fail
proves nothing — this project has been burned by exactly that once.

The banned list lives at the top of `build.sh`. Add to it when you add a hazard.

### Guard 2 — teardown is verified, never assumed

This is the most important one. See fact 1 above.

`rig.sh` escalates, and reports at every step:

1. `SIGTERM` the holder(s); wait up to `--teardown-timeout`.
2. Still alive? `SIGKILL`.
3. **Poll the topology for survivors — by identity, not by display ID.**
4. Survivors? `caffeinate -u -t 3`. This is the only lever measured to clear the
   asleep-panel case, and it works within about a second.
5. Still there? Create one short-lived virtual display and release it, then
   `caffeinate -u` again. This clears the re-enumeration failure below.
6. Still there? Print a very loud banner naming the orphaned display IDs, tell
   the reader what to try by hand, and exit 72.
7. Finally, diff the full `--stable` topology against the baseline.

**Survivors are matched on vendor `0xCA1D`, not on the IDs the holder announced.**
That is not defensive coding, it is a measured requirement: after an abrupt
teardown WindowServer re-enumerated the entire display set — the built-in went
from ID 1 to ID 36 and started reporting `builtin=0` with an `" (AirPlay)"` name,
and a slot-2 virtual display came back as ID 37. Every ID the rig had recorded
was gone, so an ID-based check reported a clean teardown **while an orphan stood
on the machine**. Only the topology diff caught it. Both checks are kept.

`rig.sh` also **refuses to start** if a `0xCA1D` display is already online
(exit 74) — a previous run leaked one and the baseline would be a lie.

### Guard 3 — the colour-profile count must be unchanged

See fact 2 above. `rig.sh` counts `/Library/ColorSync/Profiles/Displays/` before
and after, names any new files, and fails with exit 73 if the count grew.

**This guard fires for real.** It fired on the first-ever run of each slot
identity — that is the one legitimate growth, one file per row of the identity
table, once on this machine, forever. Captured output from the first slot-1 run:

```
# COLOUR PROFILE COUNT GREW: 25 -> 26
    > Candela Rig Slot 1-13819AB4-82F0-4B09-8825-A7319906B424.icc
```

and from every run since, with the same identities:

```
[rig] colour profiles unchanged (30 in /Library/ColorSync/Profiles/Displays)
```

If you see it fire on a **repeat** run of the same mode, an identity is varying.
Find it. That is the whole point of the check.

**The identity table is a guard, not a convenience.** Everything in
`kVDRigSlots` is a compile-time constant — including the pixel geometry and the
physical size, because those feed the EDID and a new EDID may mint a new file.
`holder` deliberately has no `--width`/`--height`. Adding a row, or making any
field vary at runtime, costs a permanent file per new value.

The rig's total permanent footprint on this machine is four files: slot 1,
slot 2, slot 3, twin A. (Twin B reuses twin A's profile — see below. A fifth,
a second slot-2 file, was minted during the WindowServer re-enumeration incident
described above and is an artifact of that bug, not of normal operation.)

### Guard 4 — deadlines, and teardown on every exit path

- `--deadline` bounds the tester. On overrun its **whole process group** is
  `SIGTERM`ed then `SIGKILL`ed — job control gives it its own process group
  precisely so grandchildren cannot be orphaned — and the rig reports 124. It
  then checks the group is actually empty and says so.
- `--watchdog` bounds the entire run and defaults to `--deadline` + 120s. It
  signals the rig, which runs the same teardown as any other exit.
- Teardown runs from an `EXIT` trap, so it happens on success, on failure, on
  the watchdog, and on `^C`. It is idempotent.

### Guard 5 — the tester's exit code is propagated

Precedence, in order:

1. **72** (a display survived) wins over everything. It is a machine-state
   hazard and must not be hidden behind an ordinary test failure.
2. Otherwise the tester's exit code, when non-zero (124 for an overrun).
3. Otherwise the first guard failure (70, 71, 73, 74, 75).
4. Otherwise 0.

A guard failure is **never** silent even when it loses the precedence contest:
every run ends with a ledger line naming all of it.

```
[rig] RIG-RESULT tester=17 timed_out=0 guards=ok rundir=/var/folders/…
```

---

## `--keep-awake`

Not a convenience. With the built-in panel asleep, the run is in the regime
where teardown is not guaranteed (fact 1), and a sleeping panel also captures as
solid black — so any tester that takes screenshots wants it. On this machine the
panel re-sleeps within about eight seconds of the assertion expiring, so almost
every run wants it.

The wake is not instant (~2s measured), so `rig.sh` **confirms** the panel woke
rather than sleeping a guessed interval, and warns if it did not.

Leave it off when the asleep-panel behaviour is itself what you are testing.

---

## Twins mode — and what it measured

`rig.sh --twins` asks for two displays with a deliberately colliding
`DisplayConfigIdentity` (`vendor-model-serial`), so the twin-identity question
in the arrangement research (§6.3) can be settled without two identical physical
monitors, which this setup can never provide. Because they must be identical, it
is the single deliberate exception to guard 3's one-identity rule, and it uses
exactly **two** fixed identities — never one per run.

**As of macOS 26.6, macOS refuses to create them, and `rig.sh --twins` reports
that refusal as exit 75 with the evidence inline.** Measured 2026-08-04:

- A second virtual display advertising the same **vendor+product** pair as a
  standing one is refused: `initWithDescriptor:` returns an object whose
  `displayID` stays 0. Polling three seconds does not help.
- It is refused **in-process and cross-process alike**. Two holders does not
  help.
- `serialNum` does **not** separate them. Nor does `name`. Nor does
  `sizeInMillimeters`.
- The refusal follows the **advertised** identity, not the descriptor: a
  descriptor with a distinct `productID` that injects a colliding
  `DisplayProductID` through `-setDisplayInfoValue:forKey:` is refused too — and
  creates fine on its own. That override *does* reach `CGDisplayModelNumber`,
  which is how we know the refusal is keyed on the advertised value.
- Each twin identity works perfectly **alone**. Only the pair is refused. Twin A
  and twin B produced the *same* `CGDisplayCreateUUIDFromDisplayID` and reused
  the *same* `.icc` despite different names and different serials.

Two **real** identical monitors are unaffected by any of this — it is the
virtual-display service's registry, not a rule about displays.

Consequence for #13: the twin spike's premise is unavailable through this route,
so **AR11 stands by default** — a layout is not restored when two attached
displays share an identity and nothing separates them. The rig keeps the mode so
a future macOS can be re-tested in one command; if `--twins` ever starts
succeeding, the spike becomes possible and AR11 can be revisited.

---

## Known hazard: WindowServer re-enumeration

**Intermittent**, seen twice on 2026-08-04, both times with `--count 2` and an
*abrupt* teardown (watchdog fire, deadline kill). Not once on a clean run.

Symptoms: the built-in panel is renumbered, reports `builtin=0` and a
`" (AirPlay)"` name, `system_profiler` reports **`Virtual Device: Yes` for the
built-in panel**, and one rig display stands orphaned under a new ID.

Recovery, measured twice and now automated as escalation step 5:

```sh
tools/vdrig/build/holder --identity slot1 --max-life 6   # then let it exit
caffeinate -u -t 5
tools/vdrig/build/topology                               # should read count 1
```

Creating and releasing one virtual display makes WindowServer re-enumerate and
restores the built-in to its own ID; `caffeinate -u` then clears the display the
recovery itself created. `caffeinate -u` **alone** does not fix it once the panel
is already awake. Nothing here needed a reboot, and the built-in's resolution
came back on its own.

---

## What this rig cannot do

- **It cannot substitute for a physical panel in the per-display settings UI.**
  `DisplayDiscovery` filters on `service != nil` and a `CGVirtualDisplay` has no
  `IOAVService`, so a virtual display never produces a per-display settings pane.
  Arrangement is the exception, and the reason the rig is a genuine oracle
  there: arrangement is about *origins*, and virtual displays have real origins
  in real CoreGraphics topology.
- **It cannot synthesize an identity collision** — see twins above.
- **It does not verify DDC anything.** A virtual display has no I2C.
