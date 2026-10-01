import CoreGraphics
import Foundation

/// Restores a hovered window without changing its content-stability evidence.
/// Bounds are display-local, independent of the coarse capture grid or rotation.
/// `eligible` nil means every window may be hovered.
struct AdaptiveWindowRestoration: Sendable {
  private var hovered: UInt32?
  private var leftAt: [UInt32: Date] = [:]
  var needsInputTracking: Bool { hovered != nil || !leftAt.isEmpty }
  var isReturning: Bool { !leftAt.isEmpty }

  mutating func update(pointer: CGPoint?, windows: [WindowSnapshot], at now: Date,
                       eligible: Set<UInt32>? = nil) -> [UInt32: Double]
  {
    let present = Set(windows.map(\.windowID))
    leftAt = leftAt.filter { present.contains($0.key) }
    if let hovered, !present.contains(hovered) { self.hovered = nil }
    // Hit the frontmost rectangle before considering its layer. A menu or
    // overlay must not grant a hover to the ordinary window behind it.
    let hit = pointer.flatMap { point in windows.first { $0.bounds.contains(point) } }
    let current = hit.flatMap {
      $0.layer == 0 && eligible?.contains($0.windowID) != false ? $0.windowID : nil
    }
    if current != hovered {
      if let hovered { leftAt[hovered] = now }
      hovered = current
    }
    if let current { leftAt.removeValue(forKey: current) }
    var scales: [UInt32: Double] = [:]
    for (window, left) in leftAt {
      // A backwards wall-clock adjustment restarts the grace, never jumps dark.
      let elapsed = max(0, now.timeIntervalSince(left))
      if now < left { leftAt[window] = now }
      if elapsed >= 3 {
        leftAt.removeValue(forKey: window)
      } else {
        // Two seconds clear, then a one-second fade back to the eligible depth.
        scales[window] = max(0, elapsed - 2)
      }
    }
    if let current { scales[current] = 0 }
    return scales
  }
}
