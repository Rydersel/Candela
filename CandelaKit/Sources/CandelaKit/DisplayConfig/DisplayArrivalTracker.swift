import CoreGraphics
import Foundation

/// Which displays count as having just ARRIVED.
///
/// DM7 as a rule rather than scattered bookkeeping: reapply at launch and
/// reconnect, never continuously. Reapply must fire when a display shows up and
/// must NOT fire again until it leaves, because a reconfiguration event is also
/// what the user changing resolution in System Settings produces. A pass that
/// reasserted on every event would undo their change a second later, every time.
/// Missing a genuine replug is the milder failure: the remembered resolution
/// just does not come back.
///
/// Departures are observed asynchronously, so a fast unplug/replug (or a main
/// thread busy enough to run both handlers after the display is back) samples a
/// list where the display never left. `noteObserved(live:)` takes the set
/// SAMPLED AT POST TIME, which makes a departure count whenever the handler
/// gets to run.
public struct DisplayArrivalTracker: Sendable, Equatable {
  /// Displays whose arrival has already been acted on and that have not been
  /// observed absent since.
  private var handled: Set<CGDirectDisplayID> = []

  public init() {}

  /// Records a display set sampled at a point in time, typically inside a
  /// notification block before any hop to another executor. Anything missing
  /// from `live` counts as departed, so its next appearance is an arrival;
  /// being seen is not itself a reason to reapply.
  public mutating func noteObserved(live: Set<CGDirectDisplayID>) {
    handled.formIntersection(live)
  }

  /// The displays in `live` that have not been handled since they arrived,
  /// marked handled as they are returned.
  ///
  /// Claiming and marking are one operation: the work that follows is async, so
  /// a second pass landing before the first finishes would otherwise make two
  /// session-scope reconfigurations of one display from one arrival.
  public mutating func claimArrivals(live: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
    noteObserved(live: live)
    let arrivals = live.subtracting(handled)
    handled.formUnion(arrivals)
    return arrivals
  }

  /// Gives a claimed display back so the next pass treats it as an arrival
  /// again. For work claimed and then deliberately skipped: leaving it handled
  /// would mean "never" rather than "not now".
  public mutating func release(_ displayID: CGDirectDisplayID) {
    handled.remove(displayID)
  }
}
