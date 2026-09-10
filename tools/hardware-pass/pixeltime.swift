// Restore latency at the pixel, not the window list: ScreenCaptureKit samples
// of one rect around a synthetic mouse move. The control is two readings 0.6 s
// apart rather than one, so a dim that is still fading in cannot be measured as
// though it had settled; a control that is still moving aborts, and a run with
// no overlay up reports "no dim to measure" rather than a latency.
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
  // Two samples: an idle dim or blackout fades in over OverlayFade.entrySeconds
  // (0.4 s), so a run started mid-fade would report a latency that is partly the
  // entry's. 0.6 is that fade plus margin, a literal because a standalone script
  // cannot import CandelaKit.
  let firstControl = await mean()
  try await Task.sleep(for: .seconds(0.6))
  let dimmed = await mean()
  // A failed capture returns -1, which looks exactly like a control that is still
  // moving. Exit 3 is the hardware pass's proof that a settle can fail, so a
  // capture failure must not wear it.
  guard firstControl >= 0, dimmed >= 0 else { print("capture failed"); exit(2) }
  // Mean channel value on 0...255. The sampled region is static while a dim is
  // up, so a move larger than this is the fade, not noise.
  let controlTolerance = 1.0
  if abs(dimmed - firstControl) > controlTolerance {
    print(String(format: "entry fade still in flight: control moved %.1f to %.1f. Rerun once the dim has settled",
                 firstControl, dimmed))
    exit(3)
  }
  print(String(format: "dimmed control: %.1f (steady over 0.6 s)", dimmed))
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
