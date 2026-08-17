import CoreGraphics
import Foundation

/// What a refresh should do with the per-display state it already holds.
public struct DisplayReconciliationPlan: Equatable, Sendable {
  /// Held state that still describes the panel on the other end: reuse it, so a
  /// display that never went away keeps its controllers, its last-written
  /// values and its queues.
  public var reused: Set<CGDirectDisplayID> = []
  /// Needs state built from scratch: a genuinely new arrival, or a DIFFERENT
  /// panel now sitting on an ID we already held.
  public var built: Set<CGDirectDisplayID> = []
  /// Held state to drop and announce: unplugged, or replaced by another panel.
  /// A replacement is in BOTH `built` and `departed`, which is the point: one
  /// monitor left and another arrived on the same ID.
  public var departed: Set<CGDirectDisplayID> = []

  public init(
    reused: Set<CGDirectDisplayID> = [],
    built: Set<CGDirectDisplayID> = [],
    departed: Set<CGDirectDisplayID> = []
  ) {
    self.reused = reused
    self.built = built
    self.departed = departed
  }
}

/// Decides which held display state survives a topology change.
///
/// A `CGDirectDisplayID` is a slot, not a monitor. macOS reassigns IDs across a
/// replug (measured: the MAG went 3 to 2 and the Dell 2 to 3 across one dock
/// cycle), so "the same ID is still present" does not mean "the same panel is
/// still there". The persistence key (the EDID UUID) is the only stable
/// per-panel identity available: `IOAVService` is rebuilt on every discovery
/// pass and compares unequal regardless, and the service location names the
/// PORT, so it is unchanged in exactly the different-monitor-same-port swap
/// this exists to catch.
///
/// Reconciling on the ID alone gave a newly attached panel the departed one's
/// controllers, which persist brightness under the departed panel's storage key
/// and read its tuning: min/max overrides, curve, invert, availability flags.
public enum DisplayReconciliation {
  public static func plan(
    held: [CGDirectDisplayID: String],
    discovered: [CGDirectDisplayID: String]
  ) -> DisplayReconciliationPlan {
    var plan = DisplayReconciliationPlan()
    for (id, discoveredKey) in discovered {
      if held[id] == discoveredKey {
        plan.reused.insert(id)
      } else {
        plan.built.insert(id)
        // Still occupied, so nothing else will notice this one leaving: a
        // replacement has to be announced here or the departed panel's HUD
        // outlives it and the diagnostics ring shows an arrival with no
        // matching departure.
        if held[id] != nil { plan.departed.insert(id) }
      }
    }
    for id in held.keys where discovered[id] == nil {
      plan.departed.insert(id)
    }
    return plan
  }
}
