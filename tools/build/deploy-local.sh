#!/bin/bash
# Install a gated Release build as the daily driver and relaunch it.
#
#   tools/build/deploy-local.sh path/to/Candela.app [destination-dir]
#
# make deploy runs this after the build and marker gate; a failed build once
# installed the previous product under a new commit's name. Every step checks
# the state it achieved, since a zero exit proves nothing.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 path/to/Candela.app [destination-dir]" >&2
  exit 2
fi

app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
dest="${2:-/Applications}"
installed="$dest/Candela.app"
signing="scripts/verify-signing.sh"

fail() { echo "FAIL: $*"; exit 1; }

[ -x "$app/Contents/MacOS/Candela" ] || fail "no Release binary at $app"
[ -d "$dest" ] || fail "destination $dest does not exist"
# Without the signing check a deploy would install whatever signature the build produced.
[ -x "$signing" ] || fail "$signing is not available in this checkout; deploy is a maintainer step"

echo "==> signing check on the product"
"$signing" "$app" Release

# Checked before anything is quit so a refusal leaves the current copy running.
if [ -e "$installed" ]; then
  # Newer than this build means another session deployed while this one built;
  # two deploys sixty seconds apart once trashed each other.
  if [ "$installed/Contents/MacOS/Candela" -nt "$app/Contents/MacOS/Candela" ]; then
    fail "$installed is newer than this build; another session deployed, message them first"
  fi
fi

# One DDC writer at a time, so our own copies get quit. A copy running from any
# other path is another session's measurement; killing it ruins their run.
echo "==> running copies"
running="$(pgrep -f 'Candela\.app/Contents/MacOS/Candela$' || true)"
for pid in $running; do
  path="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  case "$path" in
    "$installed"/*|"$app"/*) echo "  quitting pid $pid ($path)"; kill -TERM "$pid" ;;
    "") ;;
    *) fail "another build is running from $path; quit it yourself if it is not measuring" ;;
  esac
done
for _ in $(seq 1 20); do
  pgrep -f 'Candela\.app/Contents/MacOS/Candela$' >/dev/null || break
  sleep 0.5
done
# LaunchServices can respawn a killed copy; check absence rather than assume it.
if pgrep -f 'Candela\.app/Contents/MacOS/Candela$' >/dev/null; then
  fail "a copy is still running: $(pgrep -fl 'Candela\.app/Contents/MacOS/Candela$')"
fi

if [ -e "$installed" ]; then
  echo "==> replacing $(codesign -dvv "$installed" 2>&1 | sed -n 's/^Authority=//p' | head -1 || echo 'unsigned') copy"
  # Finder, not rm: rm is refused for this path in the maintainer's setup, and
  # the old copy lands in the Trash instead of vanishing.
  osascript -e "tell application \"Finder\" to delete POSIX file \"$installed\"" >/dev/null
  [ ! -e "$installed" ] || fail "$installed is still present after the Finder delete"
fi

echo "==> installing"
# No re-sign: an ad-hoc re-sign once cost the Accessibility grant. -p keeps the
# mtime so redeploying the same product is not read as another session's copy.
cp -Rp "$app" "$dest/"
"$signing" "$installed" Release >/dev/null || fail "the installed copy does not pass the signing check"

echo "==> launching"
open "$installed"
for _ in $(seq 1 20); do
  pid="$(pgrep -f "^$installed/Contents/MacOS/Candela$" || true)"
  [ -n "$pid" ] && break
  sleep 0.5
done
[ -n "${pid:-}" ] || fail "no copy running from $installed after launch"
echo "deploy: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$installed/Contents/Info.plist") running as pid $pid from $installed"
