#!/bin/bash
# Scan every Mach-O in a Release app, including embedded frameworks.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 path/to/Candela.app" >&2
  exit 2
fi

app=$1
binary="$app/Contents/MacOS/Candela"
# This positive control clears the 16-byte floor below which strings cannot
# see a Swift literal. Without it, a clean marker count proves nothing.
control='Where this display has been lit'
# Scan the whole prefix: CANDELA_TOOLBAR_STYLE once reached a Release build
# and would not have matched CANDELA_DEBUG. Real switches are DEBUG-gated.
marker='CANDELA_'

if [ ! -x "$binary" ]; then
  echo "FAIL: no Release binary at $binary"
  exit 1
fi
if ! contents=$(strings -a "$binary"); then
  echo "FAIL: could not inspect strings in $binary"
  exit 1
fi
ctl=$(grep -c "$control" <<< "$contents") || [ "$?" -eq 1 ]
if [ "$ctl" -eq 0 ]; then
  echo "FAIL: positive control found nothing in $binary."
  echo "      The grep method or the path is wrong, so a clean marker"
  echo "      result would mean nothing. Fix the method, do not ship it."
  exit 1
fi

nbin=0
hits=0
# Complete discovery first so a traversal error cannot produce a clean scan.
file_list=$(mktemp)
trap 'rm -f "$file_list"' EXIT
if ! find "$app" -type f -print0 > "$file_list"; then
  echo "FAIL: could not enumerate files under $app"
  exit 1
fi
while IFS= read -r -d '' b; do
  if ! description=$(file -E -b "$b"); then
    echo "FAIL: could not identify file type for $b"
    exit 1
  fi
  if [[ "$description" != *Mach-O* ]]; then
    continue
  fi
  nbin=$((nbin + 1))
  if ! contents=$(strings -a "$b"); then
    echo "FAIL: could not inspect strings in $b"
    exit 1
  fi
  n=$(grep -c "$marker" <<< "$contents") || [ "$?" -eq 1 ]
  if [ "$n" -ne 0 ]; then
    hits=$((hits + n))
    echo "FAIL: $n debug marker(s) matching '$marker*' in $b:"
    grep "$marker" <<< "$contents" | sort -u | sed 's/^/        /'
  fi
done < "$file_list"
if [ "$nbin" -eq 0 ]; then
  echo "FAIL: no Mach-O files found under $app; the scan is broken."
  exit 1
fi
[ "$hits" -eq 0 ] || exit 1
echo "markers: control found ($ctl hits), no '$marker*' in any of $nbin Mach-Os. OK"
echo "         NOTE: strings cannot see a Swift literal of 15 bytes or fewer;"
echo "         name debug switches CANDELA_DEBUG_<thing> so they clear 16."
