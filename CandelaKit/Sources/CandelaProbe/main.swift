import CandelaKit
import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let found = DisplayDiscovery.discover()

let usage = """
usage: candela-probe <subcommand>
  list                                    online DDC-capable external displays
  get                                     DDC read of VCP 0x10
  set <0-100>                             DDC write of VCP 0x10
  ramp <from> <to> <step> <intervalMs>    DDC brightness sweep
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
  }
}()

func requireDDCDisplays() {
  guard found.isEmpty else { return }
  print("No DDC-capable external displays found. (Is the display in HDR mode? DDC is locked while HDR is on.)")
  exit(1)
}

func requireOnlineDisplays() {
  guard online.isEmpty else { return }
  print("No online displays found.")
  exit(1)
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
    print("\(entry.display.id)\t\(entry.display.name)")
  }
case "get":
  requireDDCDisplays()
  for entry in found {
    let result = await entry.writer.read(command: VCP.brightness)
    print("\(entry.display.name): \(result.map { "\($0.current)/\($0.max)" } ?? "read failed")")
  }
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
    print("gamma: CAVEAT — gamma set by this process is restored the moment the process exits;")
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
default:
  print(usage)
  exit(2)
}
