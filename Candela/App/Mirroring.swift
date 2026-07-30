//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from
//  Support/DisplayManager.swift (engageMirror).

import CoreGraphics

/// Cmd+BrightnessDown mirroring toggle: break any existing mirror set, else
/// mirror every other display onto the first non-builtin display. Returns
/// false when there is at most one online display (the executor then falls
/// through to a plain brightness-down step — fork behavior).
enum Mirroring {
  @MainActor
  static func engageMirror() -> Bool {
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success, displayCount > 1 else {
      return false
    }
    // Break display mirror if there is any
    var mirrorBreak = false
    var displayConfigRef: CGDisplayConfigRef?
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      if CGDisplayIsInHWMirrorSet(onlineDisplayID) != 0 || CGDisplayIsInMirrorSet(onlineDisplayID) != 0 {
        if mirrorBreak == false {
          CGBeginDisplayConfiguration(&displayConfigRef)
        }
        CGConfigureDisplayMirrorOfDisplay(displayConfigRef, onlineDisplayID, kCGNullDirectDisplay)
        mirrorBreak = true
      }
    }
    if mirrorBreak {
      CGCompleteDisplayConfiguration(displayConfigRef, CGConfigureOption.permanently)
      return true
    }
    // Build display mirror
    var mainDisplayId = kCGNullDirectDisplay
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 {
      if CGDisplayIsBuiltin(onlineDisplayID) == 0, mainDisplayId == kCGNullDirectDisplay {
        mainDisplayId = onlineDisplayID
      }
    }
    guard mainDisplayId != kCGNullDirectDisplay else {
      return false
    }
    CGBeginDisplayConfiguration(&displayConfigRef)
    for onlineDisplayID in onlineDisplayIDs where onlineDisplayID != 0 && onlineDisplayID != mainDisplayId {
      CGConfigureDisplayMirrorOfDisplay(displayConfigRef, onlineDisplayID, mainDisplayId)
    }
    CGCompleteDisplayConfiguration(displayConfigRef, CGConfigureOption.permanently)
    return true
  }
}
