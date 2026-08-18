import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Records the engage/disengage sequence the session drives, in order.
///
/// Order is the assertion that matters here: every safety property of this
/// session is a statement about which of the two calls happened, on which
/// display, and in what order.
///
/// `@unchecked Sendable` is justified by confinement: every stored property
/// lives behind `lock` and the accessors below are the only way in. The tests
/// need that because the session is an actor, so its calls into this fake run
/// on the actor's executor while the test body reads `calls` from its own task.
final class FakeSynthesisDriver: SynthesisDriving, @unchecked Sendable {
  enum Call: Equatable {
    case engage(SyntheticSize, CGDirectDisplayID, String)
    case disengage(CGDirectDisplayID)
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var _engageFailure: SynthesisFailure?
  private var _disengageFailure: SynthesisFailure?
  private var _nextSlot = VirtualDisplayIdentity.synthesisSlotRange.lowerBound

  var calls: [Call] { lock.withLock { _calls } }

  var engageFailure: SynthesisFailure? {
    get { lock.withLock { _engageFailure } }
    set { lock.withLock { _engageFailure = newValue } }
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
    if let failure = engageFailure { return .failure(failure) }
    let slot = lock.withLock { () -> Int in
      let taken = _nextSlot
      _nextSlot += 1
      return taken
    }
    return .success(
      SynthesisPairing(
        physicalDisplayID: displayID,
        physicalIdentityKey: identityKey,
        virtualDisplayID: CGDirectDisplayID(900 + slot),
        slot: slot,
        size: size
      )
    )
  }

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure> {
    lock.withLock { _calls.append(.disengage(displayID)) }
    if let failure = disengageFailure { return .failure(failure) }
    return .success(())
  }
}

@Suite("Synthesis preview session")
struct SynthesisPreviewSessionTests {
  private let physical: CGDirectDisplayID = 7
  private let otherPhysical: CGDirectDisplayID = 9
  private let key = "MSI-MAG-341C"
  private let otherKey = "DELL-U2725QE"

  private func size(_ percent: Int) -> SyntheticSize {
    SyntheticSize(logicalWidth: 3440 * percent / 100, logicalHeight: 1440 * percent / 100, percentOfNative: percent)
  }

  private func begin(
    _ session: SynthesisPreviewSession, _ percent: Int = 95,
    on displayID: CGDirectDisplayID? = nil, identityKey: String? = nil
  ) async -> Result<PreviewedSynthesis, SynthesisFailure> {
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

    #expect(await begin(session) == .failure(.noFreeSlot))
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

    #expect(result == .failure(.unwindIncomplete))
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

    #expect(await begin(session, 90) == .failure(.unwindIncomplete))
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
    #expect(await begin(session, 90) == .failure(.mirrorRefused))
    #expect(await session.confirm(previewed) == .committed(previewed.pairing))
  }

  @Test func theDefaultCountdownIsThirtySeconds() async {
    let driver = FakeSynthesisDriver()
    let session = SynthesisPreviewSession(driver: driver)
    _ = await begin(session)

    #expect(await session.secondsRemaining == 30)
  }
}
