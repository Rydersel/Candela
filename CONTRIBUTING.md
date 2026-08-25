# Contributing

## Layout

- `CandelaKit/` is the engine: a Swift package with no AppKit or SwiftUI
  imports. Display enumeration, DDC, the exposure model, and the mode logic
  live here, along with the test suite that covers them without hardware.
- `Candela/` is the app: SwiftUI, with a few AppKit islands (the HUD, the
  shade windows, the gamma enforcer) behind CandelaKit protocols.
- `NORTHSTAR.md` is the product constitution. Scope and positioning decisions
  run through its litmus tests; if a change contradicts it, one of the two
  gets a pull request.
- `docs/` holds the design specs, spike findings, engineering notes, and the
  hardware verification ledger.

## Building

The Xcode project is generated and not checked in. Edit `project.yml`, never
the `.xcodeproj`.

```sh
brew install xcodegen
make            # lists the targets
make build      # Debug build of the app
make check      # both test suites: the engine (swift test) and the app bundle
```

`make test-app` runs the app suite without launching the app, so it is safe
with monitors attached. The engine suite is fast whole; do not filter it.

For a hardware smoke test with no UI, `cd CandelaKit && swift run
candela-probe` prints the usage. It covers brightness, volume, contrast, DDC
capabilities, HDR, gamma, display topology and virtual displays, so check it
before hand-rolling an experiment.

## Local hooks

Optional, once per clone. It wires a pre-commit hook that runs the two
context gates locally in about a second, so a bad commit never exists rather
than being caught later by CI:

```sh
git config core.hooksPath .githooks
```

`core.hooksPath` is per-clone config that `git clone` does not carry, so
this is a command you run rather than something the repo can do for you.
The same gates run in CI on every push and pull request; the hook only
shortens the feedback loop, and `git commit --no-verify` skips it.

## What a change needs

- Tests in CandelaKit for anything hardware-free. Hardware truth comes from
  `candela-probe` and a real panel.
- A hardware verification section in the issue, and the verification run
  before the merge, in the same session that wrote the fix. The ledger in
  `docs/VERIFICATION-STATUS.md` records the result.
- No ticket numbers in source comments; name the mechanism instead.
- No em dashes in user-visible text or in new comments.
- English only. No localization tooling.

## Two rules that protect hardware

Read these before touching anything that writes to a display.

- Never send VCP 0xD6 (display power) to a panel. It left a monitor
  unreachable twice during development and the restore path reports a
  success it does not achieve.
- A DDC write acknowledgement is evidence of nothing, and neither is a
  successful return from a display configuration call. Check the achieved
  state. Monitors and macOS have both returned success without doing the
  thing.
