#!/bin/bash
# Minimal tester: prove the rig's contract is visible from a separate process.
set -u
echo "tester: VDRIG_COUNT=$VDRIG_COUNT ids=[$VDRIG_DISPLAY_IDS]"
for id in $VDRIG_DISPLAY_IDS; do
  "$VDRIG_TOPOLOGY" | grep "^display $id " || { echo "tester: display $id not in topology"; exit 1; }
done
exit 0
