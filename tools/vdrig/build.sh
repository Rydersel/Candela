#!/bin/bash
# Build the rig and prove GUARD 1: the rig performs no display reconfiguration.
#
# The guard runs against comment-stripped source AND against each binary's
# undefined imports (`nm -u`), because those catch different things: a C call
# shows up in `nm -u`, an ObjC selector like `engageMirror` does not, and a
# comment mentioning a banned symbol must not trip either.
#
# The scanner is self-tested against a fixture that deliberately contains a
# banned symbol, every build, before it is trusted against the real sources.
# A check that has never been observed to fail proves nothing.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/build"
FRAMEWORKS=(-framework Foundation -framework AppKit -framework CoreGraphics -framework ColorSync)
CFLAGS=(-fobjc-arc -O2 -Wall -Wno-deprecated-declarations)

# Anything that could change display state, write prefs, or drive a panel.
# Substring match, so a prefix covers a family.
BANNED='CGBeginDisplayConfiguration
CGCompleteDisplayConfiguration
CGCancelDisplayConfiguration
CGRestorePermanentDisplayConfiguration
CGConfigureDisplay
CGDisplaySetDisplayMode
CGDisplaySetStereoOperation
CGDisplaySetInvertedPolarity
CGDisplayForceToGray
CGDisplayCapture
CGSetDisplayTransferBy
CGDisplayRestoreColorSyncSettings
CGAcquireDisplayFadeReservation
CGDisplayFade
CGSSetDisplay
CGSConfigureDisplay
SLSConfigureDisplay
engageMirror
setMirror
NSUserDefaults
CFPreferences
NSUbiquitousKeyValueStore
IOAVServiceWriteI2C
IOAVServiceReadI2C
IOI2CSendRequest
DisplayServicesSetBrightness
DisplayServicesSetLinearBrightness'

STRIPPER="$(mktemp -t vdrig-strip)"
FIXTURE_DIR=""
trap 'rm -f "$STRIPPER"; [ -n "$FIXTURE_DIR" ] && rm -rf "$FIXTURE_DIR"' EXIT
cat >"$STRIPPER" <<'PY'
import re, sys
src = open(sys.argv[1], errors="replace").read()
pat = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*.*?\*/|//[^\n]*', re.S)
sys.stdout.write(pat.sub(lambda m: " " if m.group(0)[:1] == "/" else m.group(0), src))
PY

fail=0

# Returns 0 when clean, 1 when a banned symbol is present.
scan_source() {
  local file="$1" hits
  hits="$(python3 "$STRIPPER" "$file" | grep -F -n -f <(echo "$BANNED") || true)"
  if [ -n "$hits" ]; then
    echo "GUARD1 FAIL  $file (comment-stripped source)"
    echo "$hits" | sed 's/^/    /'
    return 1
  fi
  return 0
}

scan_shell() {
  local file="$1" hits
  hits="$(grep -v '^[[:space:]]*#' "$file" | grep -F -n -f <(echo "$BANNED") || true)"
  if [ -n "$hits" ]; then
    echo "GUARD1 FAIL  $file (shell, comment lines excluded)"
    echo "$hits" | sed 's/^/    /'
    return 1
  fi
  return 0
}

scan_binary() {
  local bin="$1" hits
  hits="$(nm -u "$bin" | grep -F -f <(echo "$BANNED") || true)"
  if [ -n "$hits" ]; then
    echo "GUARD1 FAIL  $bin (undefined imports)"
    echo "$hits" | sed 's/^/    /'
    return 1
  fi
  return 0
}

# Positive control: the scanner must actually be able to fail.
FIXTURE_DIR="$(mktemp -d -t vdrig-fixture)"
cat >"$FIXTURE_DIR/tripwire.m" <<'OBJC'
#import <CoreGraphics/CoreGraphics.h>
// A comment naming CGConfigureDisplayOrigin must NOT trip the scanner.
int main(void) {
  CGDisplayConfigRef cfg;
  CGBeginDisplayConfiguration(&cfg);
  CGConfigureDisplayOrigin(cfg, CGMainDisplayID(), 0, 0);
  return CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
}
OBJC
cat >"$FIXTURE_DIR/clean.m" <<'OBJC'
#import <CoreGraphics/CoreGraphics.h>
// Mentions CGBeginDisplayConfiguration and engageMirror in a comment only.
int main(void) { return CGDisplayIsBuiltin(CGMainDisplayID()) ? 0 : 1; }
OBJC

echo "== guard self-test =="
if scan_source "$FIXTURE_DIR/tripwire.m" >/dev/null 2>&1; then
  echo "SELF-TEST FAIL: source scanner passed a file that calls CGConfigureDisplayOrigin"
  fail=1
else
  echo "  source scanner rejects a reconfiguring fixture     OK"
fi
if scan_source "$FIXTURE_DIR/clean.m" >/dev/null 2>&1; then
  echo "  source scanner ignores banned names in comments    OK"
else
  echo "SELF-TEST FAIL: source scanner tripped on a comment"
  fail=1
fi
clang "${CFLAGS[@]}" "$FIXTURE_DIR/tripwire.m" -o "$FIXTURE_DIR/tripwire" \
  -framework Foundation -framework CoreGraphics 2>/dev/null
if scan_binary "$FIXTURE_DIR/tripwire" >/dev/null 2>&1; then
  echo "SELF-TEST FAIL: nm scanner passed a binary importing CGBeginDisplayConfiguration"
  fail=1
else
  echo "  nm scanner rejects a reconfiguring binary          OK"
fi
[ "$fail" -eq 0 ] || { echo; echo "BUILD ABORTED: the guard cannot be trusted."; exit 1; }

echo
echo "== build =="
mkdir -p "$OUT"
for tool in holder topology; do
  if clang "${CFLAGS[@]}" "$SRC/$tool.m" -o "$OUT/$tool" "${FRAMEWORKS[@]}"; then
    echo "  $tool"
  else
    echo "  $tool FAILED"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

echo
echo "== guard 1: no display reconfiguration =="
for f in "$SRC"/*.m "$SRC"/*.h; do
  scan_source "$f" || fail=1
done
scan_shell "$HERE/rig.sh" || fail=1
for tool in holder topology; do
  scan_binary "$OUT/$tool" || fail=1
done

if [ "$fail" -eq 0 ]; then
  echo "  sources and binaries clean                         OK"
  echo
  echo "BUILD OK -> $OUT"
else
  echo
  echo "BUILD FAILED: guard 1 violated."
  exit 1
fi
