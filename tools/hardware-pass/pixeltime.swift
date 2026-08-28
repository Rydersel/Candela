// Restore latency at the pixel, not the window list: ScreenCaptureKit samples
// of one rect around a synthetic mouse move. The first reading is the dimmed
// control, so a run with no overlay up reports "no dim to measure", not a latency.
// Usage: pixeltime <displayID> <localX> <localY>
import CoreGraphics
import Foundation
import ScreenCaptureKit

let a = CommandLine.arguments
let displayID = CGDirectDisplayID(a[1])!
let rect = CGRect(x: Double(a[2])!, y: Double(a[3])!, width: 160, height: 160)

@MainActor
func run() async throws {
  let content = try await SCShareableContent.current
  guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
    print("display \(displayID) not in ScreenCaptureKit's list"); exit(2)
  }
  let filter = SCContentFilter(display: display, excludingWindows: [])
  let cfg = SCStreamConfiguration()
  cfg.sourceRect = rect; cfg.width = 160; cfg.height = 160
  cfg.showsCursor = false; cfg.captureResolution = .nominal
  func mean() async -> Double {
    guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
          let data = img.dataProvider?.data as Data? else { return -1 }
    var sum = 0; var n = 0
    let bpr = img.bytesPerRow
    data.withUnsafeBytes { p in
      for row in 0..<img.height { for col in 0..<img.width {
        let i = row * bpr + col * 4
        sum += Int(p[i]) + Int(p[i+1]) + Int(p[i+2]); n += 3 } }
    }
    return n == 0 ? -1 : Double(sum) / Double(n)
  }
  let dimmed = await mean()
  print(String(format: "dimmed control: %.1f", dimmed))
  let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
  let loc = CGEvent(source: nil)?.location ?? CGPoint(x: 100, y: 100)
  let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                   mouseCursorPosition: CGPoint(x: loc.x + 8, y: loc.y + 8), mouseButton: .left)
  let start = Date()
  print("posted at \(f.string(from: start))")
  ev?.post(tap: .cghidEventTap)
  var samples: [(Double, Double)] = []
  while Date().timeIntervalSince(start) < 3 {
    let m = await mean()
    samples.append((Date().timeIntervalSince(start) * 1000, m))
  }
  let final = samples.last!.1
  print(String(format: "restored reading: %.1f (%d samples, %.1f ms apart)", final, samples.count, 3000 / Double(samples.count)))
  if final <= dimmed * 1.2 { print("no dim to measure (readings did not change)"); exit(1) }
  let mid = (dimmed + final) / 2
  if let first = samples.first(where: { $0.1 > mid }) {
    print(String(format: "pixels restored %.1f ms after the post", first.0))
  }
  exit(0)
}
Task { try await run() }
RunLoop.main.run()
