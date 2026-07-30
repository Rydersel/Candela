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
default:
  print("usage: candela-probe [list|get|set <value>]")
  exit(2)
}
