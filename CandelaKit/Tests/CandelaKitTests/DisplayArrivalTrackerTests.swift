import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The gate that decides when reapply may have an opinion (DM7). Split out of the
/// coordinator so these timing cases can be stated at all: `ModeReapplyPolicy` sees
/// one display at one instant and cannot reach them.
@Suite("Display arrival tracker")
struct DisplayArrivalTrackerTests {
  private let dell: CGDirectDisplayID = 1
  private let mag: CGDirectDisplayID = 2

  @Test func everythingPresentAtLaunchIsAnArrival() {
    var tracker = DisplayArrivalTracker()
    #expect(tracker.claimArrivals(live: [dell, mag]) == [dell, mag])
  }

  /// A System Settings resolution change also raises a reconfiguration, with the
  /// display still there. Acting on it would undo the user's change a second later,
  /// for the rest of the session.
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

  /// Why `noteObserved` takes a set rather than reading the display list itself.
  /// Departures are observed asynchronously, so on a dock or KVM blip (or a main
  /// thread busy with menu tracking) a handler sampling at execution time sees the
  /// display at both ends and concludes it never left. Sampling at post time makes
  /// the departure a fact about when it happened.
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

  /// Claiming marks, so two passes racing one arrival cannot both act on it: that
  /// would be two session-scope reconfigurations from one plug.
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
