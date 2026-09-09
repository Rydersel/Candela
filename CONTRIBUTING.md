# Contributing

Bug reports and hardware reports are the most useful things you can send, and
the issue templates ask for what actually settles them. If you are reporting a
security problem, do not open an issue: see [SECURITY.md](SECURITY.md).

## Layout

- `CandelaKit/` is the engine: a Swift package with no AppKit or SwiftUI
  imports. Display enumeration, DDC, the exposure model, and the mode logic
  live here, along with the test suite that covers them without hardware.
- `Candela/` is the app: SwiftUI, with a few AppKit islands (the HUD, the
  shade windows, the gamma enforcer) behind CandelaKit protocols.
- `docs/` holds the user guides (`docs/guide/`) and the advanced settings
  reference.
- `tools/` holds the instruments for verifying the app against real displays:
  a virtual-display rig for multi-display work on a one-panel Mac, and the
  scripts that drive a hardware pass from a shell.

## Building

Install Xcode 26 or later, including its macOS 26 SDK and command-line tools.
The app runs on macOS 14 or later, but compiling it requires the newer SDK.
Select that Xcode installation in Xcode > Settings > Locations > Command Line
Tools before building.

The Xcode project is generated and not checked in. Edit `project.yml`, never
the `.xcodeproj`. App builds and tests regenerate it automatically so added,
renamed, and removed source files stay in sync.

```sh
brew install xcodegen
make                       # lists the targets
make build SIGNING=adhoc    # Debug build without a Developer ID certificate
make check                 # both test suites: the engine and the app bundle
```

Use `make release SIGNING=adhoc` for a Release build, or `make markers
SIGNING=adhoc` to also check it for debug markers. Build products and the
incremental build cache stay in `DerivedData/` within each checkout.

Ad-hoc builds are for local testing only. Rebuilding can require granting
Accessibility permission again. These commands only build the app; they do
not install or launch it. The default, `SIGNING=developer-id`, preserves the
project's maintainer Developer ID certificate and team settings.

`make test-app` runs the app suite without launching the app, so it is safe
with monitors attached. The engine suite is fast whole; do not filter it.
App changes run both suites and a Release build in CI. Documentation and site
changes receive explicit gate results for the checks relevant to their scope.

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
  untouched bug look identical. The maintainers keep the measured records, and
  every feature issue carries a `## Hardware verification` section that is the
  script for the run.
- If the verification genuinely cannot run, because nobody has the hardware or
  the test would be disruptive, say so out loud on the issue and name what is
  blocking it. Deferring is allowed. Deferring silently is not.
- No ticket numbers in source comments; name the mechanism instead, because the
  numbers go stale and the mechanism does not.
- No em dashes in user-visible text or in new comments.
- English only. No localization tooling.

## GitHub release notes

After the changes, append the contents of
[`.github/RELEASE_NOTES_FOOTER.md`](.github/RELEASE_NOTES_FOOTER.md) to the
GitHub release description. GitHub does not apply this file automatically;
include it when preparing the description, including when using generated
release notes.

Keep the original change-only notes for Sparkle. Its appcast generator
accepts only `New`, `Changed`, `Fixed`, and `Removed` sections with change
bullets, so the GitHub support footer belongs only in the GitHub description.

## Two rules that protect hardware

Read these before touching anything that writes to a display.

- Never send VCP 0xD6 (display power) to a panel. It left a monitor
  unreachable twice during development and the restore path reports a
  success it does not achieve.
- A DDC write acknowledgement is evidence of nothing, and neither is a
  successful return from a display configuration call. Check the achieved
  state. Monitors and macOS have both returned success without doing the
  thing.
