import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Records the engage/disengage sequence in order, since every safety property
/// of this session is a claim about which call happened, where, and when.
///
/// `@unchecked Sendable` is justified by confinement: every stored property
/// lives behind `lock` and the accessors are the only way in. The session is an
/// actor, so its calls run on the actor's executor while the test body reads
/// `calls` from its own task.
final class FakeSynthesisDriver: SynthesisDriving, @unchecked Sendable {
  enum Call: Equatable {
    case engage(SyntheticSize, CGDirectDisplayID, String)
    case disengage(CGDirectDisplayID)
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var _engageFailure: SynthesisFailure?
  private var _engageFailureTearsDownFirst = false
  private var _disengageFailure: SynthesisFailure?
  private var _table: [CGDirectDisplayID: SynthesisPairing] = [:]
  private var _nextSlot = VirtualDisplayIdentity.synthesisSlotRange.lowerBound

  var calls: [Call] { lock.withLock { _calls } }

  var engageFailure: SynthesisFailure? {
    get { lock.withLock { _engageFailure } }
    set { lock.withLock { _engageFailure = newValue } }
  }

  /// Models the engine's real ordering: an engage on an already-paired display
  /// tears the old pairing down FIRST, so a failure at a later step leaves the
  /// display with no pairing at all.
  var engageFailureTearsDownFirst: Bool {
    get { lock.withLock { _engageFailureTearsDownFirst } }
    set { lock.withLock { _engageFailureTearsDownFirst = newValue } }
  }

  var disengageFailure: SynthesisFailure? {
    get { lock.withLock { _disengageFailure } }
    set { lock.withLock { _disengageFailure = newValue } }
  }

  /// A fresh slot per engage, so two pairings are never equal by accident: the
  /// stale-intent tests depend on a re-engage producing a distinguishable value.
  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    lock.withLock { _calls.append(.engage(size, displayID, identityKey)) }
    if let failure = engageFailure {
      if engageFailureTearsDownFirst { lock.withLock { _table[displayID] = nil } }
      return .failure(failure)
    }
    return lock.withLock {
      let slot = _nextSlot
      _nextSlot += 1
      let pairing = SynthesisPairing(
        physicalDisplayID: displayID,
        physicalIdentityKey: identityKey,
        virtualDisplayID: CGDirectDisplayID(900 + slot),
        slot: slot,
        size: size
      )
      _table[displayID] = pairing
      return .success(pairing)
    }
  }

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure> {
    lock.withLock { _calls.append(.disengage(displayID)) }
    if let failure = disengageFailure { return .failure(failure) }
    lock.withLock { _table[displayID] = nil }
    return .success(())
  }

  func pairing(forPhysical displayID: CGDirectDisplayID) async -> SynthesisPairing? {
    lock.withLock { _table[displayID] }
  }
}

/// A driver whose engage and disengage PARK until the test lets them through.
/// Every hardware step is awaited, so another task can enter the actor mid-call,
/// and a driver that returns straight away cannot reach those states.
actor ParkedSynthesisDriver: SynthesisDriving {
  enum Call: Equatable {
    case engage(CGDirectDisplayID)
    case disengage(CGDirectDisplayID)
  }

  private(set) var calls: [Call] = []
  private var isParking = false
  private var parked: [CheckedContinuation<Void, Never>] = []
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var table: [CGDirectDisplayID: SynthesisPairing] = [:]
  private var nextSlot = VirtualDisplayIdentity.synthesisSlotRange.lowerBound

  /// Later driver calls park instead of returning. Off at the start so a test
  /// can set the scene with ordinary calls.
  func startParking() { isParking = true }

  /// Resumes as soon as a call is parked, so a test acts inside the suspension
  /// window rather than guessing at timing.
  func waitForParkedCall() async {
    guard parked.isEmpty else { return }
    await withCheckedContinuation { arrivalWaiter = $0 }
  }

  /// Lets every parked call through, and stops parking new ones.
  func release() {
    isParking = false
    let waiting = parked
    parked = []
    for continuation in waiting { continuation.resume() }
  }

  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    calls.append(.engage(displayID))
    await park()
    let slot = nextSlot
    nextSlot += 1
    let pairing = SynthesisPairing(
      physicalDisplayID: displayID,
      physicalIdentityKey: identityKey,
      virtualDisplayID: CGDirectDisplayID(900 + slot),
      slot: slot,
      size: size
    )
    table[displayID] = pairing
    return .success(pairing)
  }

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure> {
    calls.append(.disengage(displayID))
    await park()
    table[displayID] = nil
    return .success(())
  }

  /// Never parks. `confirm` asks this question while holding the gate, and a
  /// query that parked would deadlock a test trying to park a sequence.
  func pairing(forPhysical displayID: CGDirectDisplayID) -> SynthesisPairing? {
    table[displayID]
  }

  /// Cancellation releases everything parked, or the reentrancy tests' time
  /// limits could not fire: a cancelled task waiting on a plain continuation
  /// waits forever.
  private func park() async {
    guard isParking else { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        parked.append(continuation)
        arrivalWaiter?.resume()
        arrivalWaiter = nil
      }
    } onCancel: {
      Task { await self.release() }
    }
  }
}

@Suite("Synthesis preview session")
struct SynthesisPreviewSessionTests {
  private let physical: CGDirectDisplayID = 7
  private let otherPhysical: CGDirectDisplayID = 9
  private let key = "MSI-MAG-341C"
  private let otherKey = "DELL-U2725QE"

  private func size(_ percent: Int) -> SyntheticSize {
    SyntheticSize(
      logicalWidth: 3440 * percent / 100, logicalHeight: 1440 * percent / 100,
      percentOfNative: percent
    )
  }

  private func begin(
    _ session: SynthesisPreviewSession, _ percent: Int = 95,
    on displayID: CGDirectDisplayID? = nil, identityKey: String? = nil
  ) async -> Result<PreviewedSynthesis, SynthesisPreviewRefusal> {
    await session.begin(
      size: size(percent),
      onPhysical: displayID ?? physical,
      identityKey: identityKey ?? key
    )
  }

  @Test func beginningAPreviewEngagesTheSizeAndStartsTheCountdown() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)

    let result = await begin(session)

    #expect(driver.calls == [.engage(size(95), physical, key)])
    guard case let .success(previewed) = result else {
      Issue.record("expected the engage to succeed")
      return
    }
    #expect(previewed.physicalDisplayID == physical)
    #expect(previewed.size == size(95))
    #expect(await session.previewedSynthesis == previewed)
    #expect(await session.hasOutstandingPreview)
    #expect(await session.isCountingDown)
    #expect(await session.secondsRemaining == 3)
  }

  @Test func aRefusedEngageLeavesNothingOutstandingAndNoCountdown() async {
    let driver = FakeSynthesisDriver()
    driver.engageFailure = .noFreeSlot
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)

    #expect(await begin(session) == .failure(.engine(.noFreeSlot)))
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
    #expect(await session.previewedSynthesis == nil)
  }

  @Test func theCountdownDefaultsToDisengagingNotKeeping() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    _ = await begin(session)

    #expect(await session.tick() == nil)
    #expect(await session.tick() == nil)
    #expect(await session.tick() == .reverted)

    #expect(driver.calls == [.engage(size(95), physical, key), .disengage(physical)])
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
  }

  @Test func confirmingKeepsThePairingAndStopsTheCountdown() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await begin(session) else {
      Issue.record("expected the engage to succeed")
      return
    }

    #expect(await session.confirm(previewed) == .committed(previewed.pairing))
    #expect(await session.isCountingDown == false)
    #expect(await session.hasOutstandingPreview == false)
    // Nothing was taken down, and nothing was re-applied: the engage already
    // landed at session scope, so confirming is a decision rather than an apply.
    #expect(driver.calls == [.engage(size(95), physical, key)])
    #expect(await session.tick() == nil)
    #expect(driver.calls == [.engage(size(95), physical, key)])
  }

  @Test func confirmingRefusesAPairingTheEngineNoLongerHolds() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(first) = await begin(session, 95) else { return }

    // A same-display re-preview that tore the first pairing down and then failed
    // at a later step: the size the user is still looking at a panel for is not
    // on the glass any more.
    driver.engageFailure = .mirrorRefused
    driver.engageFailureTearsDownFirst = true
    #expect(await begin(session, 90) == .failure(.engine(.mirrorRefused)))

    #expect(await session.confirm(first) == .stale)
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
    // Refused without inventing a reversion it did not perform.
    #expect(await session.confirm(first) == .stale)
  }

  @Test func anAnswerForASupersededPreviewResolvesNothing() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(first) = await begin(session, 95) else { return }
    guard case let .success(second) = await begin(session, 90) else { return }

    #expect(await session.confirm(first) == .stale)
    #expect(await session.previewedSynthesis == second)
    #expect(await session.isCountingDown)
    #expect(await session.confirm(second) == .committed(second.pairing))
  }

  @Test func aRevertForAnotherPreviewTakesNothingDown() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await begin(session) else { return }

    let strangerPairing = SynthesisPairing(
      physicalDisplayID: otherPhysical, physicalIdentityKey: otherKey,
      virtualDisplayID: 42, slot: 5, size: size(90)
    )
    #expect(await session.revert(PreviewedSynthesis(pairing: strangerPairing)) == .stale)
    #expect(await session.previewedSynthesis == previewed)
    #expect(driver.calls == [.engage(size(95), physical, key)])
  }

  @Test func previewingAnotherDisplayEndsTheFirstPreviewInsteadOfMixingThemUp() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    _ = await begin(session, 95)

    guard case let .success(second) = await begin(
      session, 90, on: otherPhysical, identityKey: otherKey
    ) else {
      Issue.record("expected the second engage to succeed")
      return
    }

    #expect(driver.calls == [
      .engage(size(95), physical, key),
      .disengage(physical),
      .engage(size(90), otherPhysical, otherKey),
    ])
    #expect(await session.previewedSynthesis == second)
  }

  @Test func previewingAnotherDisplayIsRefusedWhenTheFirstCannotBeDisengaged() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(first) = await begin(session, 95) else { return }
    driver.disengageFailure = .unwindIncomplete

    let result = await begin(session, 90, on: otherPhysical, identityKey: otherKey)

    #expect(result == .failure(.engine(.unwindIncomplete)))
    // The second display was never engaged: a second synthesis set on top of one
    // that would not come down is the state this refusal exists to prevent.
    #expect(driver.calls == [.engage(size(95), physical, key), .disengage(physical)])
    #expect(await session.previewedSynthesis == first)
  }

  @Test func switchingStopsOnTheSameDisplayLeavesTheTeardownToTheEngine() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    _ = await begin(session, 95)
    _ = await session.tick()

    guard case let .success(second) = await begin(session, 90) else { return }

    #expect(driver.calls == [.engage(size(95), physical, key), .engage(size(90), physical, key)])
    #expect(await session.previewedSynthesis == second)
    #expect(await session.secondsRemaining == 3)
  }

  @Test func aFailedReEngageOnTheSameDisplayKeepsTheOriginalPreviewRevertible() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(first) = await begin(session, 95) else { return }
    driver.engageFailure = .unwindIncomplete

    #expect(await begin(session, 90) == .failure(.engine(.unwindIncomplete)))
    #expect(await session.previewedSynthesis == first)
    #expect(await session.isCountingDown)
  }

  @Test func aFailedRevertSurfacesUnwindIncompleteAndStaysRevertible() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await begin(session) else { return }
    driver.disengageFailure = .unwindIncomplete

    #expect(await session.revert(previewed) == .failed(.unwindIncomplete))
    #expect(await session.previewedSynthesis == previewed)
    #expect(await session.isCountingDown)

    driver.disengageFailure = nil
    #expect(await session.revert(previewed) == .reverted)
    #expect(await session.hasOutstandingPreview == false)
  }

  @Test func aFailedExpiryStopsCountingDownAndStaysRevertible() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 1)
    guard case let .success(previewed) = await begin(session) else { return }
    driver.disengageFailure = .unwindIncomplete

    #expect(await session.tick() == .failed(.unwindIncomplete))
    // The clock fires once. Re-attempting is `revert()`'s job, on a person's
    // say-so, and the preview stays outstanding so that retry has a target.
    #expect(await session.isCountingDown == false)
    #expect(await session.hasOutstandingPreview)
    #expect(await session.tick() == nil)

    driver.disengageFailure = nil
    #expect(await session.revert(previewed) == .reverted)
  }

  @Test func aDisengageThatSaysNotEngagedReadsAsReverted() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await begin(session) else { return }
    driver.disengageFailure = .notEngaged

    #expect(await session.revert(previewed) == .reverted)
    #expect(await session.hasOutstandingPreview == false)
  }

  @Test func aDepartedDisplayIsDisengagedRatherThanDropped() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    _ = await begin(session)

    #expect(await session.revertOnDeparture(displayID: otherPhysical) == nil)
    #expect(driver.calls == [.engage(size(95), physical, key)])

    #expect(await session.revertOnDeparture(displayID: physical) == .reverted)
    #expect(driver.calls == [.engage(size(95), physical, key), .disengage(physical)])
    #expect(await session.hasOutstandingPreview == false)
  }

  @Test func aDepartedDisplayThatWillNotDisengageIsReportedOnceAndDropped() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    _ = await begin(session)
    driver.disengageFailure = .unwindIncomplete

    #expect(await session.revertOnDeparture(displayID: physical) == .failed(.unwindIncomplete))
    // Dropped: no tick, no person and no error UI is coming for a departed
    // panel, and a preview held for it would refuse every future begin.
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)

    driver.disengageFailure = nil
    guard case let .success(next) = await begin(
      session, 90, on: otherPhysical, identityKey: otherKey
    ) else {
      Issue.record("a departed display must not wedge the next preview")
      return
    }
    #expect(await session.previewedSynthesis == next)
    // The departed display was not disengaged a second time: the engine retains
    // the stranded pairing and is the authority on it.
    #expect(driver.calls == [
      .engage(size(95), physical, key),
      .disengage(physical),
      .engage(size(90), otherPhysical, otherKey),
    ])
  }

  @Test func answeringTwiceRepeatsTheOutcomeItAlreadyProduced() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await begin(session) else { return }

    #expect(await session.confirm(previewed) == .committed(previewed.pairing))
    #expect(await session.confirm(previewed) == .committed(previewed.pairing))
    #expect(await session.revert(previewed) == .committed(previewed.pairing))
    #expect(driver.calls == [.engage(size(95), physical, key)])
  }

  @Test func answeringABeginThatNeverHappenedRevertsNothing() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    let pairing = SynthesisPairing(
      physicalDisplayID: physical, physicalIdentityKey: key,
      virtualDisplayID: 904, slot: 4, size: size(95)
    )

    #expect(await session.confirm(PreviewedSynthesis(pairing: pairing)) == .reverted)
    #expect(await session.tick() == nil)
    #expect(driver.calls.isEmpty)
  }

  @Test func aFailedBeginDoesNotEraseTheOutcomeAlreadyReported() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await begin(session) else { return }
    #expect(await session.confirm(previewed) == .committed(previewed.pairing))

    driver.engageFailure = .mirrorRefused
    #expect(await begin(session, 90) == .failure(.engine(.mirrorRefused)))
    #expect(await session.confirm(previewed) == .committed(previewed.pairing))
  }

  @Test func theDefaultCountdownIsThirtySeconds() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver)
    _ = await begin(session)

    #expect(await session.secondsRemaining == 30)
  }

  // MARK: - Reentrancy, driven through a parked driver

  // Time-limited: a regression that lets a second entrant reach the parked
  // driver blocks the test's own task rather than failing an expectation. The
  // limit turns that into a failure instead of a suite that never finishes.

  @Test(.timeLimit(.minutes(1))) func aConfirmLandingInsideTheExpirysDisengageNeverReportsAKeep() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 1)
    guard case let .success(previewed) = await session.begin(
      size: size(95), onPhysical: physical, identityKey: key
    ) else {
      Issue.record("expected the engage to succeed")
      return
    }

    await driver.startParking()
    let expiry = Task { await session.tick() }
    await driver.waitForParkedCall()

    // The teardown is already running. Reporting a keep here would tell the
    // coordinator to persist a size that is being removed as it answers, and
    // `.stale` would tell it never to ask again.
    #expect(await session.confirm(previewed) == .busy)

    await driver.release()
    #expect(await expiry.value == .reverted)
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.confirm(previewed) == .reverted)
    #expect(await driver.calls == [.engage(physical), .disengage(physical)])
  }

  @Test(.timeLimit(.minutes(1))) func aTickLandingInsideACrossDisplayHandoffCannotOrphanTheNewPreview() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 1)
    _ = await session.begin(size: size(95), onPhysical: physical, identityKey: key)

    await driver.startParking()
    let handoff = Task {
      await session.begin(size: size(90), onPhysical: otherPhysical, identityKey: otherKey)
    }
    await driver.waitForParkedCall()

    // The hand-off's own disengage is in flight. A tick that spent the clock and
    // fired a second one would resume after the hand-off had recorded its new
    // preview, and wipe the record of a synthesis that is standing.
    #expect(await session.tick() == nil)

    await driver.release()
    guard case let .success(second) = await handoff.value else {
      Issue.record("expected the hand-off to succeed")
      return
    }
    #expect(await driver.calls == [
      .engage(physical), .disengage(physical), .engage(otherPhysical),
    ])
    #expect(await session.previewedSynthesis == second)
    #expect(await session.isCountingDown)
    #expect(await session.confirm(second) == .committed(second.pairing))
  }

  @Test(.timeLimit(.minutes(1))) func aSecondBeginDuringAnEngageIsRefusedRatherThanOrphaningTheFirst() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)

    await driver.startParking()
    let first = Task {
      await session.begin(size: size(95), onPhysical: physical, identityKey: key)
    }
    await driver.waitForParkedCall()

    #expect(
      await session.begin(size: size(90), onPhysical: otherPhysical, identityKey: otherKey)
        == .failure(.busy)
    )

    await driver.release()
    guard case let .success(previewed) = await first.value else {
      Issue.record("expected the first engage to succeed")
      return
    }
    // The refused begin engaged nothing, so there is no synthesis standing
    // outside the session's record.
    #expect(await driver.calls == [.engage(physical)])
    #expect(await session.previewedSynthesis == previewed)
    #expect(await session.isCountingDown)
  }

  @Test(.timeLimit(.minutes(1))) func aRevertLandingInsideAnotherResolutionResolvesNothing() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 1)
    guard case let .success(previewed) = await session.begin(
      size: size(95), onPhysical: physical, identityKey: key
    ) else { return }

    await driver.startParking()
    let expiry = Task { await session.tick() }
    await driver.waitForParkedCall()

    #expect(await session.revert(previewed) == .busy)

    await driver.release()
    #expect(await expiry.value == .reverted)
    // One teardown, not two.
    #expect(await driver.calls == [.engage(physical), .disengage(physical)])
  }

  @Test(.timeLimit(.minutes(1)))
  func aDepartureLandingInsideAnotherResolutionIsToldToTryAgain() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await session.begin(
      size: size(95), onPhysical: physical, identityKey: key
    ) else { return }

    await driver.startParking()
    let manual = Task { await session.revert(previewed) }
    await driver.waitForParkedCall()

    // Not `.stale`: the departure has not been dealt with, and a caller that
    // read this as final would drop a display that still needs disengaging if
    // the resolution in flight fails.
    #expect(await session.revertOnDeparture(displayID: physical) == .busy)

    await driver.release()
    #expect(await manual.value == .reverted)
    #expect(await driver.calls == [.engage(physical), .disengage(physical)])
  }

  @Test(.timeLimit(.minutes(1))) func aGatedTickSpendsNoneOfTheClock() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 3)
    guard case let .success(previewed) = await session.begin(
      size: size(95), onPhysical: physical, identityKey: key
    ) else { return }

    await driver.startParking()
    let manual = Task { await session.revert(previewed) }
    await driver.waitForParkedCall()

    #expect(await session.tick() == nil)
    // The gate is checked BEFORE the clock is spent. A tick that decremented and
    // was then refused would hand back seconds nobody was given.
    #expect(await session.secondsRemaining == 3)

    await driver.release()
    #expect(await manual.value == .reverted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aGatedTickOnTheFinalSecondLeavesTheCountdownArmed() async {
    let driver = ParkedSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver, countdownSeconds: 1)
    guard case let .success(previewed) = await session.begin(
      size: size(95), onPhysical: physical, identityKey: key
    ) else { return }

    await driver.startParking()
    // A resolution that will FAIL to complete would be the worst case, but any
    // in-flight sequence is enough: what matters is that the tick is refused on
    // the one second that would otherwise spend the clock for good.
    let manual = Task { await session.revert(previewed) }
    await driver.waitForParkedCall()

    #expect(await session.tick() == nil)
    // The clock fires once. Spending it here and then refusing the expiry would
    // leave a preview outstanding that can never expire again.
    #expect(await session.secondsRemaining == 1)
    #expect(await session.isCountingDown)

    await driver.release()
    #expect(await manual.value == .reverted)
  }
}
