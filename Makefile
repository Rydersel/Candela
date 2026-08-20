# Candela build, test and deploy targets.
#
# THE RULE THIS FILE EXISTS FOR: DD is a stable per-worktree DerivedData path,
# gitignored, and it must NOT be a session scratchpad path. A path that is
# unique per session makes every session rebuild from cold instead of
# incrementally, which is the difference between a long build and a short one.
# Ad-hoc names ($DD, ./DD, dd-main, build/DerivedData, .build-dd) each buy their
# own cold build for the same reason.
#
# DerivedData/ is the default because it is gitignored at each worktree root and
# is already the warm cache in the main checkout. dd/ is the documented scratch
# name (gitignored at any depth) for a build that must NOT touch that cache:
#   make release DD=dd
#
# CLAUDE.md §3 is the source of truth for the deploy sequence; the skill
# `candela-deploy` holds the measured detail behind each gate here.

SHELL := /bin/bash
.DEFAULT_GOAL := help

DD       ?= DerivedData
PROJ     := Candela.xcodeproj
PBXPROJ  := $(PROJ)/project.pbxproj
SCHEME   := Candela
APPTESTS := CandelaAppTests
XCB      := xcodebuild -project $(PROJ) -quiet
REL_APP  := $(DD)/Build/Products/Release/Candela.app
REL_BIN  := $(REL_APP)/Contents/MacOS/Candela
INSTALLED := /Applications/Candela.app

# The Release debug-marker gate. The control MUST be found or the method is
# broken and a zero marker count means nothing (candela-deploy: "a check whose
# failure mode is silence is not a check"). 31 bytes, so it clears the 16-byte
# floor below which `strings` cannot see a Swift literal at all.
# The marker is a PREFIX. CANDELA_DEBUG alone is 13 bytes, inline-stored, and
# `strings` can never emit it, so that grep could not fail; and the one switch
# that ever reached a Release build was CANDELA_TOOLBAR_STYLE, which no
# CANDELA_DEBUG grep would match. Every Mach-O in the bundle is scanned, not
# just the main binary. All real switches are #if DEBUG-gated, so any hit in a
# Release Mach-O is a defect.
CONTROL := Where this display has been lit
MARKER  := CANDELA_

.PHONY: help build release test test-app check markers deploy regen probe conform clean

help:
	@echo "Candela targets            (DD=$(DD))"
	@echo ""
	@echo "  make build       Debug build of the app"
	@echo "  make release     Release build of the app"
	@echo "  make test        CandelaKit engine suite      (hardware-free)"
	@echo "  make test-app    CandelaAppTests bundle       (host-free, safe with panels attached)"
	@echo "  make check       Both suites"
	@echo "  make markers     Release build + debug-marker gate with its positive control"
	@echo "  make deploy      markers + signing gate + quit check + copy to /Applications + launch"
	@echo "  make probe A='list'      candela-probe (run with no A= for its usage)"
	@echo "  make conform     Platform-conformance suite; the exit code is the verdict"
	@echo "  make regen       Force xcodegen generate"
	@echo "  make clean       Remove $(DD)/ and CandelaKit/.build"
	@echo ""
	@echo "The xcodeproj regenerates automatically when project.yml is newer."

# Generated and gitignored: never edit the xcodeproj by hand (CLAUDE.md §2).
# Making it a real dependency is what stops a stale project from failing a build
# for a reason that looks like a code error. It did exactly that on 2026-08-19:
# project.yml carried the Sparkle merge, the generated project did not, and the
# build failed with "cannot find 'UpdaterModel' in scope".
$(PBXPROJ): project.yml
	@echo "==> project.yml is newer than the generated project, regenerating"
	@xcodegen generate

regen:
	@xcodegen generate

build: $(PBXPROJ)
	$(XCB) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DD) build

release: $(PBXPROJ)
	$(XCB) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DD) build

# The engine suite is hardware-free and fast whole, so it is never worth
# filtering: the saving is negligible and a filter can hide a regression
# outside it.
test:
	cd CandelaKit && swift test

# Host-free bundle: the app never launches, so this is safe with panels attached.
#
# NOT -quiet, and NOT trusting the exit code or "** TEST SUCCEEDED **" either.
# Both lie about an empty run: filtering the suite to a name that matches nothing
# prints "** TEST SUCCEEDED **" and exits 0 having executed zero tests
# [MEASURED 2026-08-19, the same positive control the app-test-target work used].
# The only honest evidence is the "Test run with N tests" line with N > 0.
test-app: $(PBXPROJ)
	@out=$$(xcodebuild -project $(PROJ) -scheme $(APPTESTS) -destination 'platform=macOS' \
	          -derivedDataPath $(DD) test 2>&1); rc=$$?; \
	summary=$$(echo "$$out" | grep -E "Test run with [0-9]+ test" | tail -1); \
	if [ -z "$$summary" ]; then \
	  echo "FAIL: no 'Test run with N tests' line; the suite did not run."; \
	  echo "$$out" | grep -E "error:|\*\* TEST" | tail -5; exit 1; \
	fi; \
	n=$$(echo "$$summary" | sed -E 's/.*Test run with ([0-9]+) test.*/\1/'); \
	if [ "$$n" -eq 0 ]; then echo "FAIL: the run executed 0 tests: $$summary"; exit 1; fi; \
	echo "$$summary"; \
	if [ $$rc -ne 0 ] || echo "$$summary" | grep -q "failed"; then \
	  echo "$$out" | grep -E "error:|✘|recorded an issue" | head -20; exit 1; \
	fi

check: test test-app

markers: release
	@set -euo pipefail; \
	if [ ! -x "$(REL_BIN)" ]; then \
	  echo "FAIL: no Release binary at $(REL_BIN)"; exit 1; \
	fi; \
	ctl=$$(strings -a "$(REL_BIN)" | grep -c "$(CONTROL)" || true); \
	if [ "$$ctl" -eq 0 ]; then \
	  echo "FAIL: positive control found nothing in $(REL_BIN)."; \
	  echo "      The grep method or the path is wrong, so a clean marker"; \
	  echo "      result would mean nothing. Fix the method, do not deploy."; \
	  exit 1; \
	fi; \
	machos=$$(find "$(REL_APP)" -type f -print0 | xargs -0 file \
	          | grep "Mach-O" | cut -d: -f1 \
	          | sed 's/ (for architecture.*$$//' | sort -u); \
	if [ -z "$$machos" ]; then \
	  echo "FAIL: no Mach-O files found under $(REL_APP); the scan is broken."; exit 1; \
	fi; \
	nbin=0; hits=0; \
	while IFS= read -r b; do \
	  nbin=$$((nbin + 1)); \
	  n=$$(strings -a "$$b" | grep -c "$(MARKER)" || true); \
	  if [ "$$n" -ne 0 ]; then \
	    hits=$$((hits + n)); \
	    echo "FAIL: $$n debug marker(s) matching '$(MARKER)*' in $$b:"; \
	    strings -a "$$b" | grep "$(MARKER)" | sort -u | sed 's/^/        /'; \
	  fi; \
	done <<< "$$machos"; \
	[ "$$hits" -eq 0 ] || exit 1; \
	echo "markers: control found ($$ctl hits), no '$(MARKER)*' in any of $$nbin Mach-Os. OK"; \
	echo "         NOTE: strings cannot see a Swift literal of 15 bytes or fewer;"; \
	echo "         name debug switches CANDELA_DEBUG_<thing> so they clear 16."

# Chained on the build's success throughout (candela-deploy): a deploy whose
# build step failed and whose copy step ran anyway installs a STALE bundle that
# passes signing, notarization and every string grep aimed at what it already had.
# Freshness needs no wall-clock gate: deploy -> markers -> release run in THIS
# invocation, and xcodebuild only succeeds when the product matches the current
# sources, so a stale product cannot survive the chain. (A 600 s mtime gate was
# tried here and refused the no-change incremental build it exists to allow.)
# The signing gate is verify-signing.sh, run BEFORE installing (candela-deploy
# step 5): `codesign --verify` has passed on a Release build that notarization
# rejects, so it proves nothing. No re-sign step: cp -R preserves the Developer
# ID signature, and the old ad-hoc re-sign destroyed the identity and its TCC
# grant (CLAUDE.md §3). The trash step is Finder's own delete: rm -rf on the
# installed bundle is permission-denied in this setup, and Finder's lands it in
# the Trash where a clobbered build can be recovered (candela-deploy step 6).
deploy: markers
	@set -euo pipefail; \
	running=$$(pgrep -lf "MacOS/Candela" | grep -v 'MacOS/Candela.debug' || true); \
	if [ -n "$$running" ]; then \
	  if echo "$$running" | grep -qv "$(INSTALLED)"; then \
	    echo "REFUSING: a Candela is running from somewhere other than $(INSTALLED):"; \
	    echo "$$running" | sed 's/^/    /'; \
	    echo "  A DerivedData, worktree or scratchpad path means another session owns it."; \
	    echo "  Only one DDC writer at a time (CLAUDE.md §2). Coordinate, then retry."; \
	    exit 1; \
	  fi; \
	fi; \
	echo "==> signing gate: scripts/verify-signing.sh (achieved state, not exit codes)"; \
	scripts/verify-signing.sh "$(REL_APP)" Release; \
	if [ -f "$(INSTALLED)/Contents/MacOS/Candela" ]; then \
	  inst_m=$$(stat -f %m "$(INSTALLED)/Contents/MacOS/Candela"); \
	  rel_m=$$(stat -f %m "$(REL_BIN)"); \
	  if [ "$$inst_m" -gt "$$rel_m" ] && \
	     ! cmp -s "$(INSTALLED)/Contents/MacOS/Candela" "$(REL_BIN)"; then \
	    echo "REFUSING: $(INSTALLED) is newer than the build being installed, and"; \
	    echo "  differs from it. Another session deployed while this build was made;"; \
	    echo "  the running-process check above cannot see a copied-but-not-launched"; \
	    echo "  bundle (candela-deploy step 4). Coordinate (ListAgents), then retry."; \
	    exit 1; \
	  fi; \
	fi; \
	echo "==> quitting the installed Candela"; \
	osascript -e 'tell application "Candela" to quit' 2>/dev/null || true; \
	for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Candela >/dev/null || break; sleep 0.5; done; \
	if pgrep -x Candela >/dev/null; then pkill -x Candela 2>/dev/null || true; sleep 1; fi; \
	sleep 2; \
	if pgrep -lx Candela; then \
	  echo "REFUSING: Candela is still running after the quit (a slow quit, or"; \
	  echo "  LaunchServices respawned it; a kill is not proof it stays down)."; \
	  echo "  Installing over a live process risks two DDC writers (CLAUDE.md §2)."; \
	  echo "  Re-check pgrep once it is really down, then retry."; \
	  exit 1; \
	fi; \
	echo "==> installing $(REL_APP) -> $(INSTALLED)"; \
	if [ -e "$(INSTALLED)" ]; then \
	  osascript -e 'tell application "Finder" to delete POSIX file "$(INSTALLED)"' >/dev/null; \
	fi; \
	cp -R "$(REL_APP)" "$(INSTALLED)"; \
	scripts/verify-signing.sh "$(INSTALLED)" Release; \
	open "$(INSTALLED)"; \
	echo "==> launched. Readiness is still a fixed wait here; polling is a separate change."

A ?=
probe:
	cd CandelaKit && swift run candela-probe $(A)

conform:
	cd CandelaKit && swift run candela-probe conform

clean:
	rm -rf $(DD) CandelaKit/.build
