// The independent readback for a synthesized-size (mirror synthesis) pass:
// three instruments in one process, none of them the app's own opinion.
//
//   1. CoreGraphics   online/active lists, per-display mode geometry and
//                     refresh, mirror flags. Phase 0's achieved-state check for
//                     a landed engage lives here: the physical reports the
//                     MASTER's logical and pixel geometry at its OWN refresh,
//                     under a fabricated ioModeID that is in no enumeration.
//   2. AppKit         the NSScreen roster and backingScaleFactor. A mirrored
//                     physical has no NSScreen at all (measured: absent from
//                     the roster, scale unreadable rather than 0.0), and the
//                     synthesis virtual display carries the 2.0 scale.
//   3. ColorSync      the system profile ledger: count and filenames. Every
//                     advertised virtual-display identity leaks one profile
//                     permanently, so this is the leak check.
//
// Run from a process that is NOT Candela. The creating process cannot read its
// own virtual display at all (even CGDisplayCopyDisplayMode is nil), which is
// exactly why the app's own claim about an engage is not evidence.
//
// Every line is `key=value` or `<section> key=value ...`, sorted, so two runs
// diff cleanly. `idle-seconds` rides along on every capture because OLED care
// dims the MAG after 300 idle seconds and a gamma or brightness reading taken
// past that is contaminated rather than wrong.
//
//   swift synthread.swift
import AppKit
import CoreGraphics
import Foundation

// NSScreen is read below; a plain command-line tool wants the shared app to
// exist before AppKit answers about screens.
_ = NSApplication.shared

func displayList(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
  var ids = [CGDirectDisplayID](repeating: 0, count: 32)
  var count: UInt32 = 0
  guard fetch(32, &ids, &count) == .success else { return [] }
  return Array(ids.prefix(Int(count)))
}

let online = displayList(CGGetOnlineDisplayList)
let active = displayList(CGGetActiveDisplayList)

/// Seconds since the last input event, the same signal OLED care's idle dim
/// reads. Reported rather than acted on: a reading is not wrong because the
/// machine went idle, it is unreadable, and that distinction has to survive
/// into the record.
func idleSeconds() -> Int {
  let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel, .flagsChanged]
  let idle = types.map {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
  }.min() ?? 0
  return Int(idle)
}

print("instrument=synthread")
print("captured-at=\(ISO8601DateFormatter().string(from: Date()))")
print("idle-seconds=\(idleSeconds())")
print("online-count=\(online.count)")
print("active-count=\(active.count)")
print("main-display-id=\(CGMainDisplayID())")

// MARK: - 1. CoreGraphics

for id in online.sorted() {
  var fields: [String] = ["id=\(id)"]
  fields.append("built-in=\(CGDisplayIsBuiltin(id) != 0 ? 1 : 0)")
  fields.append("vendor=\(CGDisplayVendorNumber(id))")
  fields.append("model=\(CGDisplayModelNumber(id))")
  fields.append("serial=\(CGDisplaySerialNumber(id))")
  fields.append("active=\(active.contains(id) ? 1 : 0)")
  fields.append("asleep=\(CGDisplayIsAsleep(id) != 0 ? 1 : 0)")
  // The engage tell, and the reason nothing may persist this descriptor: while
  // mirrored, the physical's mode is a synthetic report of the master's
  // geometry under a fabricated ioModeID.
  if let mode = CGDisplayCopyDisplayMode(id) {
    fields.append("logical=\(mode.width)x\(mode.height)")
    fields.append("fb=\(mode.pixelWidth)x\(mode.pixelHeight)")
    fields.append("hz=\(String(format: "%g", mode.refreshRate))")
    fields.append("modeid=\(mode.ioDisplayModeID)")
  } else {
    fields.append("logical=none fb=none hz=none modeid=none")
  }
  fields.append("mirrors=\(CGDisplayMirrorsDisplay(id))")
  fields.append("in-mirror-set=\(CGDisplayIsInMirrorSet(id) != 0 ? 1 : 0)")
  fields.append("hw-mirror=\(CGDisplayIsInHWMirrorSet(id) != 0 ? 1 : 0)")
  print("cg \(fields.joined(separator: " "))")
}

// MARK: - 2. AppKit

// The instrument's own positive control. An empty roster would report the
// mirrored panel as "absent from NSScreen" for the wrong reason and read as a
// clean pass, which is the whole failure mode this file exists to refuse.
let screens = NSScreen.screens
var rosterHasBuiltIn = false
for screen in screens {
  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  let id = CGDirectDisplayID(number?.uint32Value ?? 0)
  if CGDisplayIsBuiltin(id) != 0 { rosterHasBuiltIn = true }
  print(
    "nsscreen id=\(id) scale=\(String(format: "%.1f", screen.backingScaleFactor))"
      + " frame=\(Int(screen.frame.width))x\(Int(screen.frame.height))"
      + "@\(Int(screen.frame.origin.x)),\(Int(screen.frame.origin.y))")
}
print("nsscreen-count=\(screens.count)")
print("nsscreen-has-built-in=\(rosterHasBuiltIn ? 1 : 0)")

// MARK: - 3. ColorSync

let profilesDir = "/Library/ColorSync/Profiles/Displays"
let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: profilesDir)) ?? [])
  .filter { $0.hasSuffix(".icc") }
  .sorted()
print("colorsync-count=\(profiles.count)")
for name in profiles { print("colorsync name=\(name)") }
