import Foundation
import Testing
@testable import CandelaKit

/// The two unattended restore passes must not starve each other.
///
/// Both claim the same `DisplayReconfigurationGate`, and a refused pass hands its
/// arrival claims back and returns — which only works if something calls it
/// again. The mechanism relied on was the holder's own reconfiguration event, and
/// **neither pass produces one when it decides to apply nothing**, which is the
/// dominant case for both: no stored modes, or no saved layout, or a layout the
/// machine is already in. Fired back-to-back, whichever claimed second lost its
/// arrival for good.
///
/// `withoutSequencing…` below is the positive control for the rest of this suite:
/// it reproduces the loss, so the assertions that follow can fail.
@Suite("Unattended restore sequence")
@MainActor
struct UnattendedRestoreSequenceTests {
  /// One unattended pass, in the shape both of the real ones have: claim, decide,
  /// apply nothing, release. Records whether it got as far as deciding.
  private static func pass(
    _ claimant: ReconfigurationClaimant,
    gate: DisplayReconfigurationGate,
    log: PassLog
  ) async {
    guard await gate.claim(claimant).isGranted else {
      await log.noteRefused(claimant)
      return
    }
    // No `CGCompleteDisplayConfiguration` runs here, which is the whole point:
    // an unattended pass that applies nothing produces no reconfiguration event,
    // so nothing calls a refused sibling again.
    await log.noteRan(claimant)
    await gate.release(claimant)
  }

  private actor PassLog {
    private(set) var ran: [ReconfigurationClaimant] = []
    private(set) var refused: [ReconfigurationClaimant] = []
    func noteRan(_ claimant: ReconfigurationClaimant) { ran.append(claimant) }
    func noteRefused(_ claimant: ReconfigurationClaimant) { refused.append(claimant) }
  }

  /// POSITIVE CONTROL — the defect, reproduced. The mode pass is mid-flight
  /// holding the gate; the layout pass, fired back-to-back onto its own queue,
  /// claims, is refused, gives its arrivals back and returns. The mode pass then
  /// finishes having applied nothing, so no reconfiguration event follows and
  /// `TopologyArrivalTracker` — which re-arms only on an observed absence or a
  /// signature change — never offers that arrival again.
  @Test func withoutSequencingAFirstPassThatAppliesNothingStarvesTheSecond() async {
    let gate = DisplayReconfigurationGate()
    let log = PassLog()

    #expect(await gate.claim(.displayModes).isGranted)
    await Self.pass(.arrangement, gate: gate, log: log)
    await gate.release(.displayModes)

    #expect(await log.ran.isEmpty)
    #expect(await log.refused == [.arrangement])
  }

  /// C1. The same two passes through the sequence: the first has released before
  /// the second claims, so applying nothing costs the second nothing.
  @Test func aFirstPassThatAppliesNothingDoesNotPreventTheSecondFromRunning() async {
    let gate = DisplayReconfigurationGate()
    let log = PassLog()
    let sequence = UnattendedRestoreSequence()

    sequence.run([
      { await Self.pass(.displayModes, gate: gate, log: log) },
      { await Self.pass(.arrangement, gate: gate, log: log) },
    ])
    await sequence.settle()

    #expect(await log.ran == [.displayModes, .arrangement])
    #expect(await log.refused.isEmpty)
    #expect(await gate.holder == nil)
  }

  /// The reciprocal, which is the worse direction: the layout pass claiming first
  /// and applying nothing must not silently skip the stored-mode reapply — a
  /// regression to a shipped, hardware-verified feature.
  @Test func theReciprocalOrderStarvesNobodyEither() async {
    let gate = DisplayReconfigurationGate()
    let log = PassLog()
    let sequence = UnattendedRestoreSequence()

    sequence.run([
      { await Self.pass(.arrangement, gate: gate, log: log) },
      { await Self.pass(.displayModes, gate: gate, log: log) },
    ])
    await sequence.settle()

    #expect(await log.ran == [.arrangement, .displayModes])
    #expect(await log.refused.isEmpty)
  }

  /// §7.4 as a guarantee rather than an intent: a resolution change resizes the
  /// display, so a layout applied first would be tiled against footprints that
  /// are about to change. Ordering used to be whichever queue happened to get
  /// there.
  @Test func passesRunInTheOrderTheyWereGiven() async {
    let gate = DisplayReconfigurationGate()
    let log = PassLog()
    let sequence = UnattendedRestoreSequence()

    sequence.run([
      { await Self.pass(.displayModes, gate: gate, log: log) },
      { await Self.pass(.mirroring, gate: gate, log: log) },
      { await Self.pass(.arrangement, gate: gate, log: log) },
    ])
    await sequence.settle()

    #expect(await log.ran == [.displayModes, .mirroring, .arrangement])
  }

  /// A dock connect emits several callbacks, so two topology events can queue
  /// their pairs a moment apart. Their halves must not interleave — a layout
  /// restore from the first event landing after the second event's mode reapply
  /// would tile against footprints from the wrong instant.
  @Test func aSecondCallsPassesWaitForTheFirstCalls() async {
    let gate = DisplayReconfigurationGate()
    let first = PassLog()
    let second = PassLog()
    let sequence = UnattendedRestoreSequence()

    sequence.run([
      { await Self.pass(.displayModes, gate: gate, log: first) },
      { await Self.pass(.arrangement, gate: gate, log: first) },
    ])
    sequence.run([
      { await Self.pass(.displayModes, gate: gate, log: second) },
      { await Self.pass(.arrangement, gate: gate, log: second) },
    ])
    await sequence.settle()

    #expect(await first.ran == [.displayModes, .arrangement])
    #expect(await second.ran == [.displayModes, .arrangement])
  }

  /// A claimant that holds the gate around something genuinely outstanding still
  /// refuses a pass, and SHOULD: that is the case the released-claims premise is
  /// true for, because answering a preview is itself a reconfiguration. The
  /// sequence deliberately does not paper over it.
  @Test func aThirdClaimantWithSomethingOutstandingStillRefusesAPass() async {
    let gate = DisplayReconfigurationGate()
    let log = PassLog()
    let sequence = UnattendedRestoreSequence()

    #expect(await gate.claim(.rotation).isGranted)
    sequence.run([
      { await Self.pass(.displayModes, gate: gate, log: log) },
      { await Self.pass(.arrangement, gate: gate, log: log) },
    ])
    await sequence.settle()

    #expect(await log.ran.isEmpty)
    #expect(await log.refused == [.displayModes, .arrangement])
    #expect(await gate.holder == .rotation)
  }
}
