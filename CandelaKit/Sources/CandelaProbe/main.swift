import CandelaKit
import CoreGraphics
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())

// Backlog #2: `--display <id>` narrows every subcommand to one display —
// without it, `native set`/`hdr on` fan out to the built-in and every
// external on a multi-monitor desk. Parsed once here, ahead of the switch,
// so the DDC subcommands inherit it for free.
var displayFilter: CGDirectDisplayID?
if let flagIndex = arguments.firstIndex(of: "--display") {
  guard flagIndex + 1 < arguments.count, let id = UInt32(arguments[flagIndex + 1]) else {
    print("usage: --display <CGDirectDisplayID> (see `candela-probe list`)")
    exit(2)
  }
  displayFilter = id
  arguments.removeSubrange(flagIndex ... flagIndex + 1)
}

let found = DisplayDiscovery.discover().filter { displayFilter == nil || $0.display.id == displayFilter }

let usage = """
usage: candela-probe [--display <id>] <subcommand>
  --display <id>                          limit any subcommand to one display
  list                                    online DDC-capable external displays
  get                                     DDC read of VCP 0x10
  set <0-100>                             DDC write of VCP 0x10
  ramp <from> <to> <step> <intervalMs>    DDC brightness sweep
  volume get|set <0-100>                  DDC read/write of VCP 0x62
  contrast get|set <0-100>                DDC read/write of VCP 0x12
  mute on|off                             DDC write of VCP 0x8D (1=mute, 2=unmute)
  vcp get <hex>|set <hex> <0-65535>       raw VCP prober
  modes                                   merged mode list, marking CGS-revealed entries
  caps                                    DDC/CI capabilities string (VCP 0xF3) + volume verdict
  audio devices                           default CoreAudio output + native-volume check
  native get                              DisplayServicesGetBrightness per display
  native set <0-1>                        DisplayServicesSetBrightness + read-back
  hdr status                              MonitorPanel hasHDRModes / preferHDRModes
  hdr on|off                              toggle HDR, poll up to 5 s for settle
  gamma <0-1> [holdSeconds=15]            uniform gamma scale, held then reset
  gamma reset                             CGDisplayRestoreColorSyncSettings
  watch [seconds=10]                      100 ms native-brightness delta log
"""

/// The DDC subcommands need a DDC-capable external display. The private-API
/// subcommands (native/hdr/gamma/watch) work on any online display — including
/// the built-in, and including an external whose DDC is locked by HDR mode.
struct ProbeDisplay {
  let id: CGDirectDisplayID
  let name: String
}

let online: [ProbeDisplay] = {
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
  return ids.prefix(Int(count)).map { id in
    let ddcName = found.first { $0.display.id == id }?.display.name
    let fallback = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    return ProbeDisplay(id: id, name: "\(ddcName ?? fallback) [\(id)]")
  }.filter { displayFilter == nil || $0.id == displayFilter }
}()

/// Appended to the "nothing to work on" messages so an unknown `--display` id
/// reads as a bad argument rather than as absent hardware.
let filterNote = displayFilter.map { " (filtered to --display \($0); `candela-probe list` shows the ids)" } ?? ""

func requireDDCDisplays() {
  guard found.isEmpty else { return }
  print("No DDC-capable external displays found.\(filterNote) (Is the display in HDR mode? DDC is locked while HDR is on.)")
  exit(1)
}

func requireOnlineDisplays() {
  guard online.isEmpty else { return }
  print("No online displays found.\(filterNote)")
  exit(1)
}

/// Hex VCP code parser that tolerates the `0x` prefix this tool itself prints
/// (`String(format: "0x%02x", …)`), so its own output pastes back in.
func parseHexByte(_ text: String) -> UInt8? {
  let body = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
  return UInt8(body, radix: 16)
}

/// Generic DDC read/write over `found`, shared by volume/contrast/mute/vcp.
func ddcGet(code: UInt8, label: String) async {
  requireDDCDisplays()
  for entry in found {
    let result = await entry.writer.read(command: code)
    // A read failure is normal on write-only panels (e.g. the MAG 341C, which
    // ACKs every write and returns all-zeros for every read) — not a tool fault.
    print("\(entry.display.name): \(label) \(result.map { "\($0.current)/\($0.max)" } ?? "read failed (panel may be write-only, or DDC is locked by HDR)")")
  }
}

func ddcSet(code: UInt8, value: UInt16, label: String) async {
  requireDDCDisplays()
  for entry in found {
    let ok = await entry.writer.write(command: code, value: value)
    print("\(entry.display.name): \(label) write \(value) -> \(ok ? "ok" : "FAILED")")
  }
}

/// Uniformly scales the display's *current* transfer table. Quartz hands back
/// the ColorSync default in a fresh process, so this is a scale of the default.
func applyGammaScale(_ scale: Float, to displayID: CGDirectDisplayID) -> Bool {
  let capacity = Int(CGDisplayGammaTableCapacity(displayID))
  guard capacity > 0 else { return false }
  var red = [CGGammaValue](repeating: 0, count: capacity)
  var green = [CGGammaValue](repeating: 0, count: capacity)
  var blue = [CGGammaValue](repeating: 0, count: capacity)
  var sampleCount: UInt32 = 0
  guard CGGetDisplayTransferByTable(displayID, UInt32(capacity), &red, &green, &blue, &sampleCount) == .success,
        sampleCount > 0
  else { return false }
  let used = Int(sampleCount)
  let scaledRed = red[0 ..< used].map { $0 * scale }
  let scaledGreen = green[0 ..< used].map { $0 * scale }
  let scaledBlue = blue[0 ..< used].map { $0 * scale }
  return CGSetDisplayTransferByTable(displayID, sampleCount, scaledRed, scaledGreen, scaledBlue) == .success
}

switch arguments.first {
case "list", nil:
  requireDDCDisplays()
  for entry in found {
    // Column 2 is the persistence key: every per-display `defaults write`
    // key is suffixed with it (docs/ADVANCED-SETTINGS.md).
    print("\(entry.display.id)\t\(entry.display.persistenceKey)\t\(entry.display.name)")
  }
case "modes":
  // Reports the merged list THROUGH CoreGraphicsDisplayConfigurator, so what
  // prints here is exactly what the app's pickers see — revelation included.
  let configurator = CoreGraphicsDisplayConfigurator()
  print(
    "hidden-mode revelation: \(configurator.revealsHiddenModes ? "available" : "UNAVAILABLE")")
  // The probe reads its OWN defaults domain, not the app's, so this is the
  // guard's default rather than whatever the app is running with (#110).
  print("wire-timing guard: \(configurator.guardsWireTiming ? "on" : "OFF")")
  for display in online where displayFilter == nil || display.id == displayFilter {
    let all = configurator.modes(for: display.id)
    let published = all.filter { $0.provenance == .coreGraphics }
    let revealed = all.filter { $0.provenance == .coreGraphicsServices }
    let withheld = configurator.modesWithheldByWireTimingGuard(for: display.id)
    print(
      "\n\(display.name)  published \(published.count)  revealed \(revealed.count)"
        + (withheld > 0 ? "  withheld-wire-timing \(withheld)" : ""))
    if withheld > 0 {
      let parents = CGSModeRevelation.nativeParentRefreshes(
        in: published,
        nativePixelWidth: published.first(where: \.isNative)?.pixelWidth ?? 0,
        nativePixelHeight: published.first(where: \.isNative)?.pixelHeight ?? 0)
      print(
        "  native-width timings: "
          + parents.sorted(by: >).map { String(format: "%g", $0) }.joined(separator: ", ")
          + " Hz — revealed modes at any other rate are withheld")
    }
    for mode in revealed.sorted(by: {
      ($0.logicalWidth, $0.refreshHz) > ($1.logicalWidth, $1.refreshHz)
    }) {
      print(
        "  \(mode.logicalWidth)x\(mode.logicalHeight)"
          + "  fb \(mode.pixelWidth)x\(mode.pixelHeight)"
          + "  @\(String(format: "%g", mode.refreshHz))Hz"
          + "  id \(mode.ioModeID)")
    }
  }
case "curated":
  // What the DEFAULT picker actually shows, after DisplayModeCatalog curation.
  let cur = CoreGraphicsDisplayConfigurator()
  for display in online where displayFilter == nil || display.id == displayFilter {
    let all = cur.modes(for: display.id)
    guard let native = all.first(where: { $0.isNative }) else { continue }
    let rows = DisplayModeCatalog.curated(
      all, nativePixelWidth: native.pixelWidth, nativePixelHeight: native.pixelHeight)
    let revealedRows = rows.filter { $0.mode.provenance == .coreGraphicsServices }
    print("\n\(display.name): \(all.count) modes -> \(rows.count) rows, \(revealedRows.count) of them revealed")
    for row in rows {
      let m = row.mode
      print("  \(m.logicalWidth)x\(m.logicalHeight) fb \(m.pixelWidth)x\(m.pixelHeight) @\(Int(m.refreshHz))Hz id \(m.ioModeID) \(m.provenance) hidpi=\(m.isHiDPI)")
    }
    let groups = Dictionary(grouping: all) { "\($0.logicalWidth)x\($0.logicalHeight)" }
    for (size, group) in groups.sorted(by: { $0.key < $1.key }) {
      let cgOnly = group.filter { $0.provenance == .coreGraphics }
      let cgsOnly = group.filter { $0.provenance == .coreGraphicsServices }
      if !cgOnly.isEmpty && !cgsOnly.isEmpty {
        print("  COLLISION \(size): cg=\(cgOnly.count) cgs=\(cgsOnly.count)")
      }
    }
  }
case "modeapply":
  // Applies one mode BY ID at preview scope, through the real configurator, so
  // the revealed apply path and its post-commit verification are both exercised.
  // Preview scope self-reverts when this process exits.
  guard arguments.count >= 2, let wanted = Int32(arguments[1]) else {
    print("usage: candela-probe --display <id> modeapply <ioModeID> [holdSeconds=5]")
    exit(2)
  }
  let holdSeconds = arguments.count >= 3 ? UInt32(arguments[2]) ?? 5 : 5
  // Third arg picks the scope. Session scope OUTLIVES this process, so the
  // caller is responsible for putting the display back.
  let applyScope: DisplayConfigScope =
    (arguments.count >= 4 && arguments[3] == "session") ? .session : .preview
  guard let target = displayFilter else {
    print("modeapply requires --display <id>")
    exit(2)
  }
  let configurator = CoreGraphicsDisplayConfigurator()
  guard let mode = configurator.modes(for: target).first(where: { $0.ioModeID == wanted }) else {
    print("no mode with id \(wanted) on display \(target)")
    exit(3)
  }
  let before = configurator.currentMode(for: target)
  print("before: \(before.map { "\($0.logicalWidth)x\($0.logicalHeight) fb \($0.pixelWidth)x\($0.pixelHeight) id \($0.ioModeID)" } ?? "unknown")")
  print("applying: \(mode.logicalWidth)x\(mode.logicalHeight) fb \(mode.pixelWidth)x\(mode.pixelHeight) id \(mode.ioModeID) provenance \(mode.provenance)")
  do {
    try configurator.apply(mode, to: target, scope: applyScope)
    let after = configurator.currentMode(for: target)
    print("after:  \(after.map { "\($0.logicalWidth)x\($0.logicalHeight) fb \($0.pixelWidth)x\($0.pixelHeight) id \($0.ioModeID)" } ?? "unknown")")
    print("scope: \(applyScope); holding \(holdSeconds)s...")
    sleep(holdSeconds)
    print("exiting: preview scope reverts now.")
  } catch {
    print("apply FAILED: \(error)")
    exit(4)
  }
case "caps":
  requireDDCDisplays()
  for entry in found {
    guard let capabilities = await entry.writer.readCapabilityString() else {
      // Expected on the MAG 341C and every other write-only panel.
      print("\(entry.display.name): capabilities read FAILED -> unknown (volume slider stays enabled)")
      continue
    }
    print("\(entry.display.name): \(capabilities)")
    print("  VCP 0x62 (volume): \(CapabilityString.support(forVCP: VCP.audioSpeakerVolume, in: capabilities))")
  }
case "get":
  await ddcGet(code: VCP.brightness, label: "brightness")
case "set":
  requireDDCDisplays()
  guard arguments.count == 2, let value = UInt16(arguments[1]) else {
    print("usage: candela-probe set <0-100>")
    exit(2)
  }
  for entry in found {
    let ok = await entry.writer.write(command: VCP.brightness, value: value)
    print("\(entry.display.name): write \(value) -> \(ok ? "ok" : "FAILED")")
  }
case "ramp":
  // Sweeps VCP 0x10 in-process with Task.sleep pacing — no UI, no coalescer.
  // Isolates the monitor's DDC apply-path latency from everything app-side.
  requireDDCDisplays()
  guard arguments.count == 5,
        let from = Int(arguments[1]), let to = Int(arguments[2]),
        let step = Int(arguments[3]), step > 0,
        let intervalMs = Int(arguments[4]), intervalMs >= 0,
        (0 ... 100).contains(from), (0 ... 100).contains(to)
  else {
    print("usage: candela-probe ramp <from 0-100> <to 0-100> <step >0> <intervalMs>")
    exit(2)
  }
  for entry in found {
    print("\(entry.display.name): ramp \(from) -> \(to) step \(step) every \(intervalMs) ms")
    let start = ContinuousClock.now
    let direction = from <= to ? step : -step
    var value = from
    while true {
      let ok = await entry.writer.write(command: VCP.brightness, value: UInt16(value))
      let elapsed = start.duration(to: .now)
      print("  +\(elapsed) write \(value) -> \(ok ? "ok" : "FAILED")")
      if value == to { break }
      try? await Task.sleep(for: .milliseconds(intervalMs))
      value = from <= to ? min(value + direction, to) : max(value + direction, to)
    }
    print("\(entry.display.name): ramp done in \(start.duration(to: .now))")
  }
case "native":
  // DisplayServices (private, dlsym'd). Succeeds on Apple displays and — the
  // point of M3 — on an external display while macOS HDR owns its brightness.
  requireOnlineDisplays()
  switch arguments.count > 1 ? arguments[1] : nil {
  case "get":
    for display in online {
      let value = DisplayServices.getBrightness(for: display.id)
      print("\(display.name): \(value.map { "\($0)" } ?? "unavailable")")
    }
  case "set":
    guard arguments.count == 3, let value = Float(arguments[2]), (0 ... 1).contains(value) else {
      print("usage: candela-probe native set <0-1>")
      exit(2)
    }
    for display in online {
      let ok = DisplayServices.setBrightness(value, for: display.id)
      let readBack = DisplayServices.getBrightness(for: display.id)
      print("\(display.name): set \(value) -> \(ok ? "ok" : "FAILED"), read-back \(readBack.map { "\($0)" } ?? "unavailable")")
    }
  default:
    print("usage: candela-probe native [get|set <0-1>]")
    exit(2)
  }
case "hdr":
  requireOnlineDisplays()
  let service = MonitorPanelService()
  switch arguments.count > 1 ? arguments[1] : nil {
  case "status":
    for display in online {
      let supports = await service.supportsHDR(displayID: display.id)
      let enabled = await service.isHDREnabled(displayID: display.id)
      print("\(display.name): hasHDRModes=\(supports) preferHDRModes=\(enabled)")
    }
  case let sub where sub == "on" || sub == "off":
    let enabled = sub == "on"
    for display in online {
      guard await service.supportsHDR(displayID: display.id) else {
        print("\(display.name): skipped (hasHDRModes=false)")
        continue
      }
      let issued = await service.setHDR(displayID: display.id, enabled: enabled)
      print("\(display.name): setHDR(\(enabled)) -> \(issued ? "issued" : "FAILED (lock busy or unavailable)")")
      guard issued else { continue }
      // The service caches its own optimistic write for 2 s, so every poll tick
      // must clear that cache first or we just read our own answer back.
      let start = ContinuousClock.now
      var settled = false
      while start.duration(to: .now) < .seconds(5) {
        try? await Task.sleep(for: .milliseconds(100))
        await service.displaysReconfigured()
        if await service.isHDREnabled(displayID: display.id) == enabled {
          print("  settled after \(start.duration(to: .now))")
          settled = true
          break
        }
      }
      if !settled {
        print("  NOT settled after 5 s (preferHDRModes still \(await service.isHDREnabled(displayID: display.id)))")
      }
    }
  default:
    print("usage: candela-probe hdr [status|on|off]")
    exit(2)
  }
case "gamma":
  // Public Quartz gamma — the software-dimming backend. NOTE: Quartz restores
  // this process's gamma the instant the process exits, so a one-shot set is
  // just a flash; we hold, then reset explicitly.
  requireOnlineDisplays()
  guard arguments.count >= 2 else {
    print("usage: candela-probe gamma <0-1> [holdSeconds=15] | gamma reset")
    exit(2)
  }
  if arguments[1] == "reset" {
    CGDisplayRestoreColorSyncSettings()
    print("gamma: restored ColorSync settings for all displays")
  } else {
    guard let scale = Float(arguments[1]), (0 ... 1).contains(scale) else {
      print("usage: candela-probe gamma <0-1> [holdSeconds=15] | gamma reset")
      exit(2)
    }
    let holdSeconds = arguments.count > 2 ? Double(arguments[2]) ?? 15 : 15
    print("gamma: scale \(scale), holding \(holdSeconds) s.")
    print("gamma: CAVEAT. Gamma set by this process is restored the moment the process exits;")
    print("       observe the display during the hold, not after.")
    for display in online {
      print("\(display.name): scale \(scale) -> \(applyGammaScale(scale, to: display.id) ? "ok" : "FAILED")")
    }
    try? await Task.sleep(for: .seconds(holdSeconds))
    CGDisplayRestoreColorSyncSettings()
    print("gamma: hold over, ColorSync settings restored")
  }
case "watch":
  // Echo-tolerance calibration: how fast, and in what increments, does the OS
  // move native brightness when something else (Control Center, media keys,
  // ambient light) drives it?
  requireOnlineDisplays()
  let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 10 : 10
  var last: [CGDirectDisplayID: Float] = [:]
  let start = ContinuousClock.now
  for display in online {
    let value = DisplayServices.getBrightness(for: display.id)
    print("+0 \(display.name): \(value.map { "\($0)" } ?? "unavailable")")
    if let value { last[display.id] = value }
  }
  while start.duration(to: .now) < .seconds(seconds) {
    try? await Task.sleep(for: .milliseconds(100))
    for display in online {
      guard let value = DisplayServices.getBrightness(for: display.id) else { continue }
      guard let previous = last[display.id] else {
        print("+\(start.duration(to: .now)) \(display.name): appeared \(value)")
        last[display.id] = value
        continue
      }
      if value != previous {
        print("+\(start.duration(to: .now)) \(display.name): \(previous) -> \(value) (delta \(value - previous))")
        last[display.id] = value
      }
    }
  }
  print("watch: done after \(start.duration(to: .now))")
case "volume", "contrast":
  let code = arguments[0] == "volume" ? VCP.audioSpeakerVolume : VCP.contrast
  switch arguments.count > 1 ? arguments[1] : nil {
  case "get":
    await ddcGet(code: code, label: arguments[0])
  case "set":
    guard arguments.count == 3, let value = UInt16(arguments[2]), value <= 100 else {
      print("usage: candela-probe \(arguments[0]) set <0-100>")
      exit(2)
    }
    await ddcSet(code: code, value: value, label: arguments[0])
  default:
    print("usage: candela-probe \(arguments[0]) [get|set <0-100>]")
    exit(2)
  }
case "mute":
  guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
    print("usage: candela-probe mute on|off")
    exit(2)
  }
  // VCP spec (and fork) wire values: 1 = mute, 2 = unmute.
  await ddcSet(code: VCP.audioMuteScreenBlank, value: arguments[1] == "on" ? 1 : 2, label: "mute")
case "vcp":
  // Fully generic prober — the escape hatch for remap experiments.
  switch arguments.count > 1 ? arguments[1] : nil {
  case "get":
    guard arguments.count == 3, let code = parseHexByte(arguments[2]) else {
      print("usage: candela-probe vcp get <hex code>")
      exit(2)
    }
    await ddcGet(code: code, label: String(format: "0x%02x", code))
  case "set":
    guard arguments.count == 4, let code = parseHexByte(arguments[2]), let value = UInt16(arguments[3]) else {
      print("usage: candela-probe vcp set <hex code> <0-65535>")
      exit(2)
    }
    await ddcSet(code: code, value: value, label: String(format: "0x%02x", code))
  default:
    print("usage: candela-probe vcp [get <hex>|set <hex> <value>]")
    exit(2)
  }
case "audio":
  guard arguments.count == 2, arguments[1] == "devices" else {
    print("usage: candela-probe audio devices")
    exit(2)
  }
  let provider = CoreAudioDeviceProvider()
  if let device = provider.defaultOutputDevice() {
    print("default output: \(device.name) [\(device.id)] canSetOwnVolume=\(device.canSetOwnVolume)")
    // The real tap rule checks ddcDisplaysExist FIRST, so with no DDC-capable
    // display the keys stay with macOS whatever the device reports.
    if found.isEmpty {
      print("volume keys stay with macOS regardless: no DDC-capable displays\(filterNote)")
    } else {
      print("volume keys would be \(device.canSetOwnVolume ? "RELEASED to macOS" : "WATCHED by Candela") outside name-matching mode")
    }
  } else {
    print("no default output device")
  }
default:
  print(usage)
  exit(2)
}
