# Candela build and test targets.
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

SHELL := /bin/bash
.DEFAULT_GOAL := help

DD       ?= DerivedData
PROJ     := Candela.xcodeproj
SCHEME   := Candela
APPTESTS := CandelaAppTests
XCB      := xcodebuild -project $(PROJ) -quiet
REL_APP  := $(DD)/Build/Products/Release/Candela.app
REL_BIN  := $(REL_APP)/Contents/MacOS/Candela

# Keep the project's Developer ID settings unless local ad-hoc signing is
# explicitly requested. Clearing Release's timestamp flag also avoids needing
# Apple's timestamp service for a contributor build.
SIGNING ?= developer-id
ifeq ($(SIGNING),developer-id)
APP_SIGNING :=
else ifeq ($(SIGNING),adhoc)
APP_SIGNING := CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=
else
$(error Invalid SIGNING '$(SIGNING)'; use SIGNING=developer-id or SIGNING=adhoc)
endif

.PHONY: help build release test test-app check markers regen probe conform clean

help:
	@echo "Candela targets            (DD=$(DD))"
	@echo ""
	@echo "  make build       Debug build of the app       (SIGNING=$(SIGNING))"
	@echo "  make release     Release build of the app     (SIGNING=$(SIGNING))"
	@echo "  make test        CandelaKit engine suite      (hardware-free)"
	@echo "  make test-app    CandelaAppTests bundle       (host-free, safe with panels attached)"
	@echo "  make check       Both suites"
	@echo "  make markers     Release build + debug-marker gate with its positive control"
	@echo "  make probe A='list'      candela-probe (run with no A= for its usage)"
	@echo "  make conform     Platform-conformance suite; the exit code is the verdict"
	@echo "  make regen       Run xcodegen generate"
	@echo "  make clean       Remove $(DD)/ and CandelaKit/.build"
	@echo ""
	@echo "Contributors: make build SIGNING=adhoc (also works with release and markers)."
	@echo "The xcodeproj regenerates before each app build or test to track source changes."

# Generated and gitignored: never edit the xcodeproj by hand, edit project.yml.
# Directory membership can change without project.yml changing. Regenerate on
# every app operation so additions, renames, and deletions reach both targets.
regen:
	@xcodegen generate

build: regen
	$(XCB) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DD) $(APP_SIGNING) build

release: regen
	$(XCB) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DD) $(APP_SIGNING) build

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
test-app: regen
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
	@tools/build/check-release-markers.sh "$(REL_APP)"

A ?=
probe:
	cd CandelaKit && swift run candela-probe $(A)

conform:
	cd CandelaKit && swift run candela-probe conform

clean:
	rm -rf $(DD) CandelaKit/.build
