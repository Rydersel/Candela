# Candela (working name)

A macOS menu-bar app for controlling external displays — brightness, volume,
contrast, HDR — with native polish. Successor to our MonitorControl fork;
long-term goal: a free, open competitor to BetterDisplay.

- Spec: `docs/superpowers/specs/2026-07-29-candela-v1-design.md`
- Engine: `CandelaKit/` (Swift package, no UI imports)
- App: `Candela/` (SwiftUI, generated via `xcodegen generate` — never edit the xcodeproj)
- Hardware smoke test: `cd CandelaKit && swift run candela-probe [list|get|set N|ramp from to step ms]`

Portions transplanted from [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT).
