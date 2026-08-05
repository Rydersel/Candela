#!/bin/bash
# Overruns its deadline AND spawns a grandchild, so the kill must reach the
# whole process tree rather than just the process the rig launched.
sleep 9000 &
echo "tester: grandchild $! ; now sleeping past the deadline"
sleep 9000
