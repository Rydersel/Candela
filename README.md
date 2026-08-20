# Candela

A macOS menu-bar app that looks after external displays: panel health, burn-in
protection, and the everyday controls (brightness, volume, contrast, HDR) with
native polish. Successor to our MonitorControl fork. Positioning and scope live
in [`NORTHSTAR.md`](NORTHSTAR.md), the product constitution: display care, a
category of one.

- Constitution: `NORTHSTAR.md`
- Spec: `docs/superpowers/specs/2026-07-29-candela-v1-design.md`
- Engine: `CandelaKit/` (Swift package, no UI imports)
- App: `Candela/` (SwiftUI, generated via `xcodegen generate` — never edit the xcodeproj)
- Hardware smoke test: `cd CandelaKit && swift run candela-probe [list|get|set N|ramp from to step ms]`

## Local setup

Optional, once per clone. It wires a pre-commit hook that runs the two context
gates locally in about a second, so a bad commit never exists rather than being
caught later by CI:

```sh
git config core.hooksPath .githooks
```

`core.hooksPath` is per-clone config and `git clone` does not carry it, so this
is a command you run rather than something the repo can do for you — deliberately.
Skipping it costs nothing but feedback latency: the same gates run in CI on every
push and pull request, and CI is the enforcing layer. The hook is advisory and
`git commit --no-verify` skips it, which is a legitimate escape hatch.

## License and attribution

Candela is MIT licensed: see [`LICENSE`](LICENSE).

It exists because of
[MonitorControl](https://github.com/MonitorControl/MonitorControl), and the
relationship is closer than "inspired by". Candela began as a fork of it, and
its DDC/CI transport for Apple Silicon and Intel, its media-key handling, its
software-dimming approach and its HDR toggle were transplanted or adapted from
that project. Where Candela behaves differently, MonitorControl is the baseline
the difference is measured against. It is MIT licensed, and every file carrying
its code carries its attribution header.

[`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md) reproduces the full notice
for MonitorControl, for [MediaKeyTap](https://github.com/nhurden/MediaKeyTap)
(which reached us through it), and for
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), the only
third-party package Candela links against. It also records the one place the
provenance chain runs out, so nobody has to rediscover it.
