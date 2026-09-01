# Contributing

Bug reports and hardware reports are the most useful things you can send, and
the issue templates ask for what actually settles them. If you are reporting a
security problem, do not open an issue: see [SECURITY.md](SECURITY.md).
Participation is under the [Code of Conduct](CODE_OF_CONDUCT.md).

## Layout

- `CandelaKit/` is the engine: a Swift package with no AppKit or SwiftUI
  imports. Display enumeration, DDC, the exposure model, and the mode logic
  live here, along with the test suite that covers them without hardware.
- `Candela/` is the app: SwiftUI, with a few AppKit islands (the HUD, the
  shade windows, the gamma enforcer) behind CandelaKit protocols.
- `docs/` holds the user guides (`docs/guide/`), the spike findings that decided
  the hard questions (`docs/spikes/`), the engineering notes, the advanced
  settings reference, and the hardware verification ledger.
- `ROADMAP.md` is the scope document. It says what is planned and what has been
  ruled out, each with its reason. A change that contradicts it wants a
  conversation in an issue first, because the roadmap changes by pull request
  too.

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
with monitors attached. The engine suite is fast whole; do not filter it. Both
suites and a Release build run in CI on every pull request.

For a hardware smoke test with no UI, `cd CandelaKit && swift run
candela-probe` prints the usage. It covers brightness, volume, contrast, DDC
capabilities, HDR, gamma, display topology and virtual displays, so check it
before hand-rolling an experiment.

## Pull requests

Pull requests are squash-merged, so the pull request title and description
become the commit message. Write them for someone reading `git log` in a year.

Keep a branch to one change. A pull request that fixes a bug and reorganizes
three files is two pull requests, and the second one is the reason the first
takes a week.

## What a change needs

- Tests in CandelaKit for anything hardware-free. Hardware truth comes from
  `candela-probe` and a real panel.
- **A change that touches hardware behaviour states how it was verified**:
  which monitor, which connection, and what you observed. Do this before the
  merge, not after: from the outside, a merged but unverified fix and an
  untouched bug look identical. `docs/VERIFICATION-STATUS.md` records what has
  and has not been verified, and every feature issue carries a
  `## Hardware verification` section that is the script for the run.
- If the verification genuinely cannot run, because nobody has the hardware or
  the test would be disruptive, say so out loud on the issue and name what is
  blocking it. Deferring is allowed. Deferring silently is not.
- No ticket numbers in source comments; name the mechanism instead, because the
  numbers go stale and the mechanism does not.
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
