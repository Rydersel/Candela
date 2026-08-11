import CoreGraphics
import Foundation

// Reads back the gamma table actually loaded for each display and reports the
// top of the ramp. 1.0 means the software dimming leg is released; anything
// below it is the scale software dimming is currently applying. This is the
// achieved state for the gamma leg, which no DDC readback can answer and which
// the MAG cannot answer at all.

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)

for i in 0..<Int(count) {
  let id = ids[i]
  let cap = CGDisplayGammaTableCapacity(id)
  var red = [CGGammaValue](repeating: 0, count: Int(cap))
  var green = [CGGammaValue](repeating: 0, count: Int(cap))
  var blue = [CGGammaValue](repeating: 0, count: Int(cap))
  var sampleCount: UInt32 = 0
  let err = CGGetDisplayTransferByTable(id, cap, &red, &green, &blue, &sampleCount)
  guard err == .success, sampleCount > 0 else {
    print("id=\(id) gamma read failed (\(err.rawValue))")
    continue
  }
  let n = Int(sampleCount)
  let top = red[n - 1]
  let mid = red[n / 2]
  print(
    "id=\(id) samples=\(n) top=\(String(format: "%.4f", top)) "
      + "mid=\(String(format: "%.4f", mid)) "
      + "green_top=\(String(format: "%.4f", green[n - 1])) "
      + "blue_top=\(String(format: "%.4f", blue[n - 1]))")
}
