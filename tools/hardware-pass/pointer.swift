import CoreGraphics
import Foundation

// Prints each online display's bounds, and optionally warps the pointer to the
// centre of one of them. Brightness-key targeting defaults to "the display
// under the pointer", so this is how a key press is aimed at a chosen panel.
//
// usage: swift pointer.swift              list displays
//        swift pointer.swift <displayID>  warp to that display's centre

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)

let args = CommandLine.arguments
if args.count > 1, let want = UInt32(args[1]) {
  let b = CGDisplayBounds(want)
  let centre = CGPoint(x: b.midX, y: b.midY)
  CGWarpMouseCursorPosition(centre)
  CGAssociateMouseAndMouseCursorPosition(1)
  print("warped to \(want) centre \(centre)")
} else {
  for i in 0..<Int(count) {
    let id = ids[i]
    let b = CGDisplayBounds(id)
    print("id=\(id) origin=(\(b.origin.x), \(b.origin.y)) size=\(b.width)x\(b.height) builtin=\(CGDisplayIsBuiltin(id) != 0)")
  }
}
