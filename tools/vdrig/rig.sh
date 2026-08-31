#!/bin/bash
# rig.sh — bring up N virtual displays, run a tester against them, tear down,
# and prove the machine came back to where it started.
#
# See README.md. The guards this script enforces, and why each exists, are
# GUARD 2 (teardown is not assumed), GUARD 3 (colour-profile count unchanged),
# GUARD 4 (deadlines, and teardown on every exit path) and GUARD 5 (the tester's
# exit code is propagated).
#
# This script never reconfigures a display. It starts holder, reads topology,
# runs the tester, and stops holder. `caffeinate -u` is the one recovery lever
# it pulls, and only when a display has already refused to die.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/build"
PROFILE_DIR="/Library/ColorSync/Profiles/Displays"
RIG_VENDOR="0xCA1D"   # every identity in src/vdrig.h; nothing else uses it

COUNT=1
TWINS=0
DEADLINE=120          # seconds the tester may run
WATCHDOG=0            # 0 -> derived from DEADLINE
READY_TIMEOUT=30      # seconds to wait for READY-ALL
TEARDOWN_TIMEOUT=20   # seconds to wait for the displays to actually go away
RUNDIR=""
KEEP_RUNDIR=0
KEEP_AWAKE=0

usage() {
  cat <<'EOF'
usage: rig.sh [options] [-- <tester command...>]

  --count N            1..3 virtual displays from the fixed slot table (default 1)
  --twins              two displays sharing vendor/product/serial (names A/B),
                       run as two holders. See README: macOS 26.6 REFUSES this
                       and the rig reports that refusal as exit 75.
  --deadline SECS      tester deadline, process tree killed on overrun (default 120)
  --watchdog SECS      whole-run bound (default: deadline + 120)
  --ready-timeout SECS wait for the holder's READY-ALL (default 30)
  --teardown-timeout S wait for the displays to disappear (default 20)
  --rundir DIR         where to write logs and topology dumps
  --keep-rundir        do not delete the run directory on success
  --keep-awake         hold a display-power assertion for the whole run
  -h, --help           this

--keep-awake exists because of a measured hazard, not for convenience. With the
built-in panel asleep a virtual display becomes the only ACTIVE display and
WindowServer refuses to reclaim it; it then stands with no owner process alive.
Holding the panel awake keeps the run out of that regime entirely, and a
sleeping panel also captures as solid black, so any screenshot tester wants it.
Leave it off when the asleep-panel behaviour is itself what you are testing.

The tester runs with these in its environment:
  VDRIG_COUNT          number of virtual displays
  VDRIG_DISPLAY_IDS    their CGDirectDisplayIDs, space separated, creation order
  VDRIG_TOPOLOGY       path to the topology binary
  VDRIG_BASELINE       path to the pre-create topology dump
  VDRIG_RUNDIR         the run directory

Exit codes:
  0    everything passed
  2    usage error
  70   the holder never reached READY-ALL
  71   the topology did not gain exactly --count displays
  72   TEARDOWN FAILED — a virtual display survived (overrides everything)
  73   the colour-profile count grew across the run
  74   a rig display was already online before the run started
  75   --twins: macOS refused the second, colliding identity
  124  the tester overran its deadline
  *    otherwise, the tester's own exit code
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --twins) TWINS=1; shift ;;
    --deadline) DEADLINE="$2"; shift 2 ;;
    --watchdog) WATCHDOG="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --teardown-timeout) TEARDOWN_TIMEOUT="$2"; shift 2 ;;
    --rundir) RUNDIR="$2"; shift 2 ;;
    --keep-rundir) KEEP_RUNDIR=1; shift ;;
    --keep-awake) KEEP_AWAKE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "rig.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ $# -eq 0 ]; then TESTER=(true); else TESTER=("$@"); fi
[ "$TWINS" -eq 1 ] && COUNT=2
[ "$WATCHDOG" -eq 0 ] && WATCHDOG=$((DEADLINE + 120))

if [ ! -x "$BIN/holder" ] || [ ! -x "$BIN/topology" ]; then
  echo "rig.sh: binaries missing — run $HERE/build.sh first" >&2
  exit 2
fi

if [ -z "$RUNDIR" ]; then
  RUNDIR="$(mktemp -d -t vdrig-run)"
fi
mkdir -p "$RUNDIR"

HOLDER_PIDS=""
TESTER_PID=""
WATCHDOG_PID=""
AWAKE_PID=""
RIG_IDS=""
TESTER_CODE=0
TIMED_OUT=0
GUARD_CODE=0
LEAKED=0
CLEANED=0
PROFILES_BEFORE=0

note() { echo "[rig] $*"; }
loud() {
  echo
  echo "################################################################"
  echo "# $*"
  echo "################################################################"
  echo
}

first_guard() { [ "$GUARD_CODE" -eq 0 ] && GUARD_CODE="$1"; }

profile_count() { ls -1 "$PROFILE_DIR" 2>/dev/null | wc -l | tr -d ' '; }

# Survivors are found by IDENTITY, not by display ID.
#
# MEASURED 2026-08-04, and it is why this is not the obvious loop: after an
# abrupt teardown WindowServer re-enumerated the whole display set — the
# built-in went from ID 1 to ID 36 and started reporting builtin=0 with an
# "(AirPlay)" name — and a slot2 virtual display came back as ID 37. Every ID
# the rig had recorded was gone, so an ID-based check reported a clean teardown
# while an orphan stood on the machine. Vendor 0xCA1D belongs to the rig alone,
# so matching on it cannot be fooled by renumbering.
rig_displays_still_online() {
  local surviving="" line id
  for line in $("$BIN/topology" | grep "vendor=$RIG_VENDOR" | awk '{print $2}'); do
    surviving="$surviving $line"
  done
  # Belt and braces: an ID we were told about that is still present but somehow
  # no longer advertises the rig vendor.
  for id in $RIG_IDS; do
    case " $surviving " in *" $id "*) continue ;; esac
    if "$BIN/topology" --ids-only | grep -qx "$id"; then
      surviving="$surviving $id"
    fi
  done
  echo "$surviving"
}

# A rig identity that is NOT currently online, so a recovery attempt cannot be
# refused for colliding with the very orphan it is trying to clear.
recovery_identity() {
  local models cand lbl m
  models=" $("$BIN/topology" | grep "vendor=$RIG_VENDOR" \
             | sed 's/.*model=\([^ ]*\).*/\1/' | tr '\n' ' ') "
  for cand in slot1:0x1001 slot2:0x1002 slot3:0x1003; do
    lbl="${cand%%:*}"; m="${cand##*:}"
    case "$models" in *" $m "*) continue ;; esac
    echo "$lbl"; return 0
  done
  echo ""
}

# GUARD 2 + GUARD 4. Runs on every exit path, including the watchdog and ^C.
cleanup() {
  [ "$CLEANED" -eq 1 ] && return
  CLEANED=1

  if [ -n "$WATCHDOG_PID" ]; then kill "$WATCHDOG_PID" 2>/dev/null; fi
  # AWAKE_PID is released at the END of cleanup, not here: the panel must stay
  # awake until the displays are confirmed gone.

  # Kill any tester still running (watchdog / ^C path).
  if [ -n "$TESTER_PID" ] && kill -0 "$TESTER_PID" 2>/dev/null; then
    kill -TERM -"$TESTER_PID" 2>/dev/null
    sleep 1
    kill -KILL -"$TESTER_PID" 2>/dev/null
  fi

  # Let the tester's death settle before pulling the displays out. Two abrupt
  # teardowns in the same instant is the shape that produced the WindowServer
  # re-enumeration described above.
  [ -n "$TESTER_PID" ] && sleep 1

  local hp waited
  for hp in $HOLDER_PIDS; do
    note "teardown: SIGTERM -> holder $hp"
    kill -TERM "$hp" 2>/dev/null
    waited=0
    while kill -0 "$hp" 2>/dev/null && [ "$waited" -lt "$TEARDOWN_TIMEOUT" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$hp" 2>/dev/null; then
      note "teardown: holder $hp ignored SIGTERM, sending SIGKILL"
      kill -KILL "$hp" 2>/dev/null
      sleep 2
    fi
  done

  # The holder being gone does NOT mean the displays are gone. With the
  # built-in panel asleep a virtual display becomes the only ACTIVE display and
  # WindowServer will not reclaim it: one survived object release, survived
  # SIGKILL, and stood for over two minutes with no owner (S1 §5A). Verify.
  if true; then
    local waited=0 surviving
    surviving="$(rig_displays_still_online)"
    while [ -n "$surviving" ] && [ "$waited" -lt "$TEARDOWN_TIMEOUT" ]; do
      sleep 1
      waited=$((waited + 1))
      surviving="$(rig_displays_still_online)"
    done

    if [ -n "$surviving" ]; then
      loud "TEARDOWN DID NOT TAKE — displays still online:$surviving"
      # The only lever measured to work: make a real display active again.
      # caffeinate -dis does NOT wake a sleeping panel; -u does.
      note "attempting recovery: caffeinate -u -t 3"
      caffeinate -u -t 3 2>/dev/null
      sleep 2
      surviving="$(rig_displays_still_online)"
    fi

    if [ -n "$surviving" ]; then
      # Second lever, for the WindowServer re-enumeration failure described on
      # rig_displays_still_online. Measured twice on 2026-08-04: creating one
      # short-lived virtual display and releasing it restores the built-in panel
      # to its own display ID and clears the orphan, and caffeinate -u then
      # clears the display the recovery itself created. caffeinate -u alone does
      # not do it once the panel is already awake.
      local rid
      rid="$(recovery_identity)"
      if [ -n "$rid" ]; then
        note "attempting recovery: re-enumerate via a short-lived holder ($rid)"
        "$BIN/holder" --identity "$rid" --max-life 6 >/dev/null 2>&1 &
        local rp=$!
        sleep 6
        kill -TERM "$rp" 2>/dev/null
        sleep 3
        caffeinate -u -t 4 >/dev/null 2>&1
        sleep 3
        surviving="$(rig_displays_still_online)"
      fi
    fi

    if [ -n "$surviving" ]; then
      LEAKED=1
      loud "ORPHANED VIRTUAL DISPLAY(S):$surviving — NO OWNER PROCESS EXISTS"
      echo "  Both recovery levers were tried and failed. Nothing in this rig"
      echo "  can remove them; there is no process to ask. Try by hand:"
      echo "    caffeinate -u -t 5"
      echo "    $BIN/holder --identity slot1 --max-life 6   # then ^C it"
      echo "  and re-check with: $BIN/topology"
      echo
    else
      note "teardown: all rig displays gone"
    fi
  fi

  # Topology restoration. Diffed on --stable, which excludes active/asleep:
  # those move on their own and the caffeinate recovery above changes them by
  # construction. The full dumps are kept alongside for the record.
  if [ -f "$RUNDIR/topology.before.stable.txt" ]; then
    "$BIN/topology" >"$RUNDIR/topology.after.txt" 2>/dev/null
    "$BIN/topology" --stable >"$RUNDIR/topology.after.stable.txt" 2>/dev/null
    if diff -u "$RUNDIR/topology.before.stable.txt" "$RUNDIR/topology.after.stable.txt" \
        >"$RUNDIR/topology.diff.txt" 2>&1; then
      note "topology restored exactly (stable diff empty)"
    else
      LEAKED=1
      loud "TOPOLOGY NOT RESTORED"
      cat "$RUNDIR/topology.diff.txt"
    fi
  fi

  # GUARD 3 — colour profiles.
  if [ "$PROFILES_BEFORE" -gt 0 ]; then
    local after
    after="$(profile_count)"
    ls -1 "$PROFILE_DIR" 2>/dev/null >"$RUNDIR/profiles.after.txt"
    if [ "$after" -eq "$PROFILES_BEFORE" ]; then
      note "colour profiles unchanged ($after in $PROFILE_DIR)"
    else
      first_guard 73
      loud "COLOUR PROFILE COUNT GREW: $PROFILES_BEFORE -> $after"
      echo "  macOS writes one .icc per display identity and NEVER removes it —"
      echo "  not on teardown, not on process death, not on reboot. New files:"
      diff "$RUNDIR/profiles.before.txt" "$RUNDIR/profiles.after.txt" \
        | grep '^>' | sed 's/^/    /'
      echo
      echo "  Expected exactly once per identity in src/vdrig.h, the first time"
      echo "  that identity is ever used on this machine. If you see it on a"
      echo "  repeat run of the same mode, an identity is varying — find it."
      echo
    fi
  fi

  if [ -n "$AWAKE_PID" ]; then kill "$AWAKE_PID" 2>/dev/null; fi

  # Final ledger. Printed on every path, so a guard failure can never be
  # invisible behind a propagated exit code.
  local guards="ok"
  [ "$GUARD_CODE" -ne 0 ] && guards="FAILED($GUARD_CODE)"
  [ "$LEAKED" -eq 1 ] && guards="FAILED(72 teardown)"
  echo "[rig] RIG-RESULT tester=$TESTER_CODE timed_out=$TIMED_OUT guards=$guards rundir=$RUNDIR"

  if [ "$KEEP_RUNDIR" -eq 0 ] && [ "$LEAKED" -eq 0 ] && [ "$GUARD_CODE" -eq 0 ] \
     && [ "$TESTER_CODE" -eq 0 ]; then
    rm -rf "$RUNDIR"
  fi
}

on_signal() {
  if [ -f "$RUNDIR/watchdog-fired" ]; then
    loud "WATCHDOG FIRED after ${WATCHDOG}s — tearing down"
  else
    loud "rig interrupted — tearing down"
  fi
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

# Outer watchdog. Both fds go to /dev/null: a long-lived background child that
# holds the script's stdout keeps a pipe's write end open, so `rig.sh | tail`
# would block for the whole watchdog period. The signal trap reports the firing.
( sleep "$WATCHDOG"; touch "$RUNDIR/watchdog-fired"; kill -TERM $$ 2>/dev/null ) \
  >/dev/null 2>&1 &
WATCHDOG_PID=$!

if [ "$KEEP_AWAKE" -eq 1 ]; then
  # -u is the only assertion measured to actually wake a sleeping panel;
  # -dis does not (S1 §5A). The wake is not instant — measured at ~2s — so
  # confirm it rather than sleeping a guessed interval and assuming.
  # >/dev/null matters: a background child that inherits stdout holds the pipe
  # open, so `rig.sh | tail` would hang until the assertion expired.
  caffeinate -u -t $((WATCHDOG + 120)) >/dev/null 2>&1 &
  AWAKE_PID=$!
  waited=0
  while [ "$waited" -lt 50 ]; do
    "$BIN/topology" | grep -q 'asleep=1' || break
    sleep 0.2
    waited=$((waited + 1))
  done
  if "$BIN/topology" | grep -q 'asleep=1'; then
    note "WARNING: a display is still asleep after 10s of caffeinate -u."
    note "         This run is in the regime where teardown is not guaranteed."
  else
    note "panel awake and held (caffeinate -u, pid $AWAKE_PID)"
  fi
fi

PREEXISTING="$("$BIN/topology" | grep "vendor=$RIG_VENDOR" | awk '{print $2}' | tr '\n' ' ')"
if [ -n "$PREEXISTING" ]; then
  loud "A RIG DISPLAY IS ALREADY ONLINE BEFORE THIS RUN: $PREEXISTING"
  echo "  A previous run leaked it. Nothing owns it; try: caffeinate -u -t 5"
  echo "  Refusing to start on top of it — the baseline would be wrong."
  exit 74
fi

PROFILES_BEFORE="$(profile_count)"
ls -1 "$PROFILE_DIR" 2>/dev/null >"$RUNDIR/profiles.before.txt"
note "baseline: $PROFILES_BEFORE colour profiles"

"$BIN/topology" >"$RUNDIR/topology.before.txt"
"$BIN/topology" --stable >"$RUNDIR/topology.before.stable.txt"
BASE_N="$(grep -c '^display ' "$RUNDIR/topology.before.txt" | tr -d ' ')"
note "baseline topology: $BASE_N display(s)"

# Returns 0 once the holder announces READY-ALL, 1 if it fails or never gets
# there. $1 = holder arguments, $2 = log path.
start_holder() {
  local args="$1" log="$2" pid w
  "$BIN/holder" $args --max-life $((WATCHDOG + 60)) >"$log" 2>&1 &
  pid=$!
  HOLDER_PIDS="$HOLDER_PIDS $pid"
  w=0
  while [ "$w" -lt "$((READY_TIMEOUT * 5))" ]; do
    grep -q '^READY-ALL ' "$log" 2>/dev/null && break
    grep -q '^FAIL ' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
    w=$((w + 1))
  done
  if grep -q '^READY-ALL ' "$log" 2>/dev/null; then
    # Record the IDs as soon as they exist, so a later failure still leaves the
    # teardown check knowing what it has to prove is gone.
    RIG_IDS="$(cat "$RUNDIR"/holder*.log | grep '^READY ' | awk '{printf "%s%s", (NR>1?" ":""), $2}')"
    return 0
  fi
  return 1
}

if [ "$TWINS" -eq 1 ]; then
  # Two holders, one identity each. A single process cannot hold both, and
  # neither can two — see the refusal handling below.
  note "starting holder --identity twinA"
  if ! start_holder "--identity twinA" "$RUNDIR/holder.twinA.log"; then
    loud "HOLDER (twinA) NEVER REACHED READY-ALL"
    sed 's/^/    /' "$RUNDIR/holder.twinA.log"
    first_guard 70
    exit 70
  fi
  sed 's/^/    /' "$RUNDIR/holder.twinA.log"

  note "starting holder --identity twinB (the colliding identity)"
  if ! start_holder "--identity twinB" "$RUNDIR/holder.twinB.log"; then
    sed 's/^/    /' "$RUNDIR/holder.twinB.log"
    loud "TWINS REFUSED BY macOS — this is a finding, not a rig bug"
    cat <<'EOM'
  macOS will not create a second virtual display that advertises the same
  vendor+product pair as a standing one. Measured 2026-08-04 on 26.6:

    * serialNum, name and sizeInMillimeters do NOT separate them
    * the refusal follows the ADVERTISED identity, not the descriptor: a
      descriptor with a distinct productID that injects a colliding
      DisplayProductID via -setDisplayInfoValue: is refused too, and creates
      fine on its own
    * each twin identity works alone; only the pair is refused

  DisplayConfigIdentity is vendor-model-serial, so a synthesized collision
  needs exactly the pair macOS forbids. Two REAL identical monitors are
  unaffected — this is the virtual-display service's registry, not a display
  rule. Re-run this command on a future macOS to re-test; if it starts
  passing, the twin spike becomes possible and AR11 can be revisited.
EOM
    first_guard 75
    exit 75
  fi
  sed 's/^/    /' "$RUNDIR/holder.twinB.log"
else
  note "starting holder --count $COUNT"
  if ! start_holder "--count $COUNT" "$RUNDIR/holder.log"; then
    loud "HOLDER NEVER REACHED READY-ALL"
    sed 's/^/    /' "$RUNDIR/holder.log"
    first_guard 70
    exit 70
  fi
  sed 's/^/    /' "$RUNDIR/holder.log"
fi

"$BIN/topology" >"$RUNDIR/topology.during.txt"
DURING_N="$(grep -c '^display ' "$RUNDIR/topology.during.txt" | tr -d ' ')"
if [ "$DURING_N" -ne "$((BASE_N + COUNT))" ]; then
  loud "TOPOLOGY GAINED $((DURING_N - BASE_N)) DISPLAY(S), EXPECTED $COUNT"
  cat "$RUNDIR/topology.during.txt"
  first_guard 71
  exit 71
fi
note "topology: $BASE_N -> $DURING_N display(s), ids:$RIG_IDS"

note "running tester (deadline ${DEADLINE}s): ${TESTER[*]}"
export VDRIG_COUNT="$COUNT"
export VDRIG_DISPLAY_IDS="$RIG_IDS"
export VDRIG_TOPOLOGY="$BIN/topology"
export VDRIG_BASELINE="$RUNDIR/topology.before.txt"
export VDRIG_RUNDIR="$RUNDIR"

# Job control gives the tester its own process group, so an overrun can be
# killed as a TREE rather than leaving orphaned grandchildren behind.
set -m
( exec "${TESTER[@]}" ) &
TESTER_PID=$!
set +m

tenths=0
limit=$((DEADLINE * 5))
while kill -0 "$TESTER_PID" 2>/dev/null; do
  if [ "$tenths" -ge "$limit" ]; then
    TIMED_OUT=1
    loud "TESTER EXCEEDED ${DEADLINE}s — killing process group $TESTER_PID"
    kill -TERM -"$TESTER_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$TESTER_PID" 2>/dev/null
    sleep 1
    break
  fi
  sleep 0.2
  tenths=$((tenths + 1))
done

wait "$TESTER_PID" 2>/dev/null
TESTER_CODE=$?
if [ "$TIMED_OUT" -eq 1 ]; then
  TESTER_CODE=124
  strays="$(pgrep -g "$TESTER_PID" 2>/dev/null | tr '\n' ' ')"
  if [ -n "$strays" ]; then
    loud "STRAY PROCESSES SURVIVED THE KILL: $strays"
  else
    note "no strays: process group $TESTER_PID is empty"
  fi
fi
note "tester exited $TESTER_CODE"

# cleanup runs from the EXIT trap and may raise LEAKED / GUARD_CODE.
cleanup
[ "$LEAKED" -eq 1 ] && exit 72
[ "$TESTER_CODE" -ne 0 ] && exit "$TESTER_CODE"
exit "$GUARD_CODE"
