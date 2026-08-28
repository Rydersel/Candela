// Lists Candela's OLED care overlay windows as CoreGraphics sees them.
// Usage: overlayread | overlayread wait-gone|nudge <displayID> [timeoutMs]
// Run it with an overlay UP first; a NONE with no positive control means nothing.
import CoreGraphics
import Foundation

func overlays() -> [(name: String, display: String, onscreen: Bool, alpha: Double, layer: Int, bounds: String)] {
  guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
  return list.compactMap { w in
    guard let name = w[kCGWindowName as String] as? String,
          name.hasPrefix("Candela OLED Care Overlay") else { return nil }
    let display = name.components(separatedBy: " ").last ?? "?"
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let bounds = "\(b["X"] ?? "?"),\(b["Y"] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?")"
    return (name, display, onscreen, alpha, layer, bounds)
  }
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "wait-gone" {
  let target = args[2]
  let timeout = args.count >= 4 ? Double(args[3])! : 5000
  let start = Date()
  while Date().timeIntervalSince(start) * 1000 < timeout {
    if !overlays().contains(where: { $0.display == target && $0.onscreen }) {
      print(String(format: "gone after %.1f ms", Date().timeIntervalSince(start) * 1000))
      exit(0)
    }
    usleep(1000)
  }
  print("STILL UP after \(Int(timeout)) ms")
  exit(1)
}
if args.count >= 3, args[1] == "nudge" {
  // Post the move and time the departure in one process so a shell round trip
  // never lands in the latency.
  let target = args[2]
  let timeout = args.count >= 4 ? Double(args[3])! : 5000
  let loc = CGEvent(source: nil)?.location ?? CGPoint(x: 100, y: 100)
  let to = CGPoint(x: loc.x + 8, y: loc.y + 8)
  let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: to, mouseButton: .left)
  let start = Date()
  let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
  print("posted at \(f.string(from: start))")
  ev?.post(tap: .cghidEventTap)
  while Date().timeIntervalSince(start) * 1000 < timeout {
    if !overlays().contains(where: { $0.display == target && $0.onscreen }) {
      print(String(format: "restored %.1f ms after the synthetic move", Date().timeIntervalSince(start) * 1000))
      exit(0)
    }
    usleep(500)
  }
  print("STILL UP after \(Int(timeout)) ms")
  exit(1)
}
let o = overlays()
if o.isEmpty { print("NONE") }
for w in o { print("display=\(w.display) onscreen=\(w.onscreen) alpha=\(w.alpha) layer=\(w.layer) bounds=\(w.bounds)") }
