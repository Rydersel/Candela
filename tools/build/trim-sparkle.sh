#!/bin/bash
# Trim the embedded Sparkle.framework to what this app uses, then re-sign it.
#
#   tools/build/trim-sparkle.sh <Sparkle.framework> <identity> [codesign flags...]
#
# Runs as the app target's post-build phase, after Embed Frameworks and before
# the app's own seal. It removes:
#   - XPCServices, which Sparkle uses only for a sandboxed host whose Info.plist
#     opts in (SUEnableInstallerLauncherService and related keys). This app does neither.
#   - Slices other than the app's single ARCHS.
#   - Localizations other than Base and en. The app is English-only.
# Updater.app and Autoupdate stay because the installer needs both.
#
# Sparkle ships its helpers ad-hoc signed, a plain `xcodebuild build` does not
# re-sign them (Archive does), and the notary rejects ad-hoc nested code. The
# trim breaks those signatures anyway, so this re-signs innermost first with the
# app's identity. Never --deep: the components carry differing requirements.
#
# Idempotent. An incremental build finds nothing to trim and only verifies.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "error: usage: $0 <Sparkle.framework> <identity> [codesign flags...]" >&2
  exit 2
fi
fw=$1
identity=$2
shift 2

fail() { echo "error: trim-sparkle: $*" >&2; exit 1; }

[ -d "$fw" ] || fail "no framework at $fw (not embedded yet? this phase must run after Embed Frameworks)"
current="$fw/Versions/$(readlink "$fw/Versions/Current" || echo Current)"
[ -d "$current" ] || fail "no Versions/Current under $fw"

changed=0

# 1. XPC services.
if [ -e "$current/XPCServices" ]; then
  rm -rf "$current/XPCServices"
  changed=1
fi
[ ! -e "$current/XPCServices" ] || fail "XPCServices still present after removal"

# 2. Localizations. The two kept are what an English-only host resolves to.
for lproj in "$current"/Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  case "$(basename "$lproj")" in
    Base.lproj|en.lproj) ;;
    *) rm -rf "$lproj"; changed=1 ;;
  esac
done
leftover=$(find "$current/Resources" -maxdepth 1 -name '*.lproj' ! -name Base.lproj ! -name en.lproj | wc -l | tr -d ' ')
[ "$leftover" -eq 0 ] || fail "$leftover foreign localizations survived"

# 3. Architecture slices. Only when the app builds exactly one architecture;
#    a universal app keeps a universal updater.
arch="${ARCHS:-}"
if [ -n "$arch" ] && [ "$(wc -w <<< "$arch" | tr -d ' ')" -eq 1 ]; then
  for bin in "$current/Sparkle" "$current/Autoupdate" "$current/Updater.app/Contents/MacOS/Updater"; do
    [ -f "$bin" ] || fail "expected Mach-O missing: $bin"
    archs=$(lipo -archs "$bin")
    case " $archs " in
      *" $arch "*) ;;
      *) fail "$bin has no $arch slice (has: $archs)" ;;
    esac
    if [ "$(wc -w <<< "$archs" | tr -d ' ')" -gt 1 ]; then
      lipo "$bin" -thin "$arch" -output "$bin.thin"
      mv -f "$bin.thin" "$bin"
      changed=1
    fi
    [ "$(lipo -archs "$bin")" = "$arch" ] || fail "$bin is still $(lipo -archs "$bin") after thinning"
  done
fi

# 4. Re-sign innermost first. Xcode hands the phase its expanded identity ("-"
#    when ad-hoc) and the configuration's own flags (--timestamp on Release).
if [ "$changed" -eq 1 ]; then
  for item in "$current/Autoupdate" "$current/Updater.app" "$fw"; do
    codesign -f -s "$identity" -o runtime "$@" "$item"
  done
fi
codesign --verify --strict "$fw" || fail "framework does not verify after trim"
for item in "$current/Autoupdate" "$current/Updater.app"; do
  codesign --verify --strict "$item" || fail "$item does not verify after trim"
done

if [ "$changed" -eq 1 ]; then
  echo "trim-sparkle: trimmed and re-signed $fw"
else
  echo "trim-sparkle: already trimmed, nothing to do"
fi
