// Posts one synthetic left click at global coordinates, or a Control-Right
// arrow (next Space). Usage: click <x> <y> | click space-right
import CoreGraphics
import Foundation
let a = CommandLine.arguments
if a[1] == "space-right" {
  let d = CGEvent(keyboardEventSource: nil, virtualKey: 0x7C, keyDown: true)!
  d.flags = .maskControl; d.post(tap: .cghidEventTap)
  let u = CGEvent(keyboardEventSource: nil, virtualKey: 0x7C, keyDown: false)!
  u.flags = .maskControl; u.post(tap: .cghidEventTap)
  print("posted control-right"); exit(0)
}
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(30000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(40000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
print("clicked \(p)")
