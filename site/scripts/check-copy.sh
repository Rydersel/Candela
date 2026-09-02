#!/usr/bin/env bash
# Copy gate for the site: no em dashes anywhere in site copy, no placeholder
# markers left over from the build phase.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
if grep -rn $'—' src --include='*.ts' --include='*.tsx' --include='*.css' --include='*.md'; then
  echo "FAIL: em dash in site/src"; fails=1
fi
# Separate call on purpose: --include filters out an explicitly named path, so
# folding index.html into the grep above silently checks nothing. The title and
# meta description live here, the og tags will once the deploy phase adds them,
# and this file is where the last em dash was found.
# Same guard as functions below: grep on a missing file exits non-zero, which
# reads as a pass.
if [ ! -f index.html ]; then
  echo "FAIL: site/index.html is missing, so its em-dash check proves nothing"; fails=1
elif grep -n $'—' index.html; then
  echo "FAIL: em dash in site/index.html"; fails=1
fi
# Pages Functions live outside src, so the first grep never sees them. A missing
# directory is a failure, not a pass: grep would exit non-zero either way, so
# the check has to be that the directory is there before it can be cleared.
if [ ! -d functions ]; then
  echo "FAIL: site/functions is missing, so its em-dash check proves nothing"; fails=1
elif grep -rn $'—' functions; then
  echo "FAIL: em dash in site/functions"; fails=1
fi
if grep -rn 'PLACEHOLDER-ASSET' src/content/assets.ts 2>/dev/null && [ "${ALLOW_PLACEHOLDERS:-0}" != "1" ]; then
  echo "FAIL: placeholder assets still referenced (set ALLOW_PLACEHOLDERS=1 during Phase A)"; fails=1
fi
exit $fails
