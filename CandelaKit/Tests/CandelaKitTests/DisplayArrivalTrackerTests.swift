import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The gate that decides when reapply is allowed to have an opinion (DM7).
/// Extracted from the coordinator specifically so these cases can be stated —
/// both of them are about timing, and neither is reachable from
/// `ModeReapplyPolicy`, which sees one display at one instant.
@Suite("Display arrival tracker")
struct DisplayArrivalTrackerTests {
  private let dell: CGDirectDisplayID = 1
  private let mag: CGDirectDisplayID = 2

  @Test func everythingPresentAtLaunchIsAnArrival() {
    var tracker = DisplayArrivalTracker()
    #expect(tracker.claimArrivals(live: [dell, mag]) == [dell, mag])
  }

  /// The hostile direction. A reconfiguration event is also what a System
  /// Settings resolution change produces, and the display is still there — so
  /// there is nothing to act on, or Candela would undo that change a second
  /// later, for the rest of the session.
  @Test func aDisplayThatNeverLeftIsNeverAnArrivalAgain() {
    var tracker = DisplayArrivalTracker()
    _ = tracker.claimArrivals(live: [dell])
    tracker.noteObserved(live: [dell])
    #expect(tracker.claimArrivals(live: [dell]).isEmpty)
    #expect(tracker.claimArrivals(live: [dell]).isEmpty)
  }

  @Test func aReplugIsAnArrival() {
    var tracker = DisplayArrivalTracker()
    _ = tracker.claimArrivals(live: [dell, mag])
    tracker.noteObserved(live: [mag]) // the Dell is unplugged
    #expect(tracker.claimArrivals(live: [dell, mag]) == [dell])
  }

  /// **The fast-replug case, and the reason `noteObserved` takes a set rather
  /// than reading the display list itself.**
  ///
  /// Departures are observed asynchronously: the notification is posted, the
  /// handler runs later. On a dock or KVM blip — or on a main thread busy
  /// enough that both handlers run after the display is back, which this
  /// codebase documents happens during menu tracking — a handler that sampled
  /// the list at EXECUTION time would see the display present at both ends and
  /// conclude it never left. The remembered resolution would then silently not
  /// come back, in the exact case the feature is named for.
  ///
  /// Sampling at post time makes the departure a fact about when it happened
  /// rather than about when we got around to looking.
  @Test func aDepartureObservedAtPostTimeCountsEvenIfTheDisplayIsBackByThen() {
    var tracker = DisplayArrivalTracker()
    _ = tracker.claimArrivals(live: [dell])
    // Sampled synchronously inside the unplug notification block...
    tracker.noteObserved(live: [])
    // ...and delivered to a handler that runs after the replug, by which time
    // the live list has the display in it again.
    tracker.noteObserved(live: [dell])
    #expect(tracker.claimArrivals(live: [dell]) == [dell])
  }

  /// Claiming marks, so two passes racing one arrival cannot both act on it —
  /// that would be two session-scope reconfigurations of one display from one
  /// plug.
  @Test func oneArrivalIsClaimedOnce() {
    var tracker = DisplayArrivalTracker()
    #expect(tracker.claimArrivals(live: [dell]) == [dell])
    #expect(tracker.claimArrivals(live: [dell]).isEmpty)
  }

  /// A claim that was deliberately not acted on is given back, so it is retried
  /// rather than dropped for the rest of the connection.
  @Test func aReleasedClaimIsAnArrivalAgain() {
    var tracker = DisplayArrivalTracker()
    _ = tracker.claimArrivals(live: [dell])
    tracker.release(dell)
    #expect(tracker.claimArrivals(live: [dell]) == [dell])
  }

  /// A display nobody has seen leave is not resurrected by another display's
  /// departure.
  @Test func oneDisplayLeavingDoesNotReArmAnother() {
    var tracker = DisplayArrivalTracker()
    _ = tracker.claimArrivals(live: [dell, mag])
    tracker.noteObserved(live: [dell])
    #expect(tracker.claimArrivals(live: [dell, mag]) == [mag])
  }
}
