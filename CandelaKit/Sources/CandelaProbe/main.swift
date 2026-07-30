import CandelaKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let found = DisplayDiscovery.discover()

guard !found.isEmpty else {
  print("No DDC-capable external displays found. (Is the display in HDR mode? DDC is locked while HDR is on.)")
  exit(1)
}

switch arguments.first {
case "list", nil:
  for entry in found {
    print("\(entry.display.id)\t\(entry.display.name)")
  }
case "get":
  for entry in found {
    let result = await entry.writer.read(command: VCP.brightness)
    print("\(entry.display.name): \(result.map { "\($0.current)/\($0.max)" } ?? "read failed")")
  }
case "set":
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
default:
  print("usage: candela-probe [list|get|set <value>|ramp <from> <to> <step> <intervalMs>]")
  exit(2)
}
