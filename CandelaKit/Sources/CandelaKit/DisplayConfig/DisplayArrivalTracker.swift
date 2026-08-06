import CoreGraphics
import Foundation

/// Which displays count as having just ARRIVED.
///
/// This is the whole of DM7 — "reapply at launch and reconnect, never
/// continuously" — expressed as a rule rather than as scattered bookkeeping.
/// Reapply must fire when a display shows up and must NOT fire again until it
/// leaves, because a reconfiguration event is also what the user changing
/// resolution in System Settings produces: a pass that reasserted on every
/// event would undo their change a second later, every time.
///
/// Two failure directions, one on each side, and they are not symmetric:
///
/// - Too eager (a still-present display treated as an arrival) means fighting
///   the user for the rest of the session. That is the feature being hostile.
/// - Too shy (a genuine replug missed) means the remembered resolution silently
///   does not come back. That is the feature not existing.
///
/// The second is what `noteObserved(live:)` exists for. Departures are observed
/// asynchronously — a notification is posted, and the handler runs some time
/// later — so a fast unplug/replug, or a main thread busy enough to run both
/// handlers after the display is back, would sample a list where the display
/// never left. Feeding the set SAMPLED AT POST TIME through this method makes a
/// departure count as a departure regardless of when the handler gets to run.
public struct DisplayArrivalTracker: Sendable, Equatable {
  /// Displays whose arrival has already been acted on and that have not been
  /// observed absent since.
  private var handled: Set<CGDirectDisplayID> = []

  public init() {}

  /// Records a display set observed at some point in time — in particular, one
  /// sampled inside a notification block before any hop to another executor.
  ///
  /// Anything missing from `live` is treated as departed, so its next
  /// appearance is an arrival. Anything present is left exactly as it was:
  /// merely being seen is not a reason to reapply to it.
  public mutating func noteObserved(live: Set<CGDirectDisplayID>) {
    handled.formIntersection(live)
  }

  /// The displays in `live` that have not been handled since they arrived,
  /// marked handled as they are returned.
  ///
  /// Claiming and marking are one operation on purpose. The work that follows
  /// is asynchronous, so a second pass landing before the first finishes would
  /// otherwise act on the same displays twice — two session-scope
  /// reconfigurations of one display, from one arrival.
  public mutating func claimArrivals(live: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
    noteObserved(live: live)
    let arrivals = live.subtracting(handled)
    handled.formUnion(arrivals)
    return arrivals
  }

  /// Gives a claimed display back, so the next pass treats it as an arrival
  /// again. For work that was claimed and then deliberately not done — the
  /// arrival is still outstanding, and marking it handled would mean "never"
  /// rather than "not now".
  public mutating func release(_ displayID: CGDirectDisplayID) {
    handled.remove(displayID)
  }
}
