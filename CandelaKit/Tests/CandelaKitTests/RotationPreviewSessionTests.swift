import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Rotation preview session (RT8, RT10, RT11)")
struct RotationPreviewSessionTests {
  private func request(
    _ display: CGDirectDisplayID = 2,
    from: DisplayRotation = .standard,
    to: DisplayRotation = .ninety
  ) -> RotationRequest {
    RotationRequest(display: display, from: from, to: to)
  }

  private func session(
    _ fake: FakeConfigurator, timeout: Int = 30
  ) -> RotationPreviewSession {
    RotationPreviewSession(configurator: fake, timeoutSeconds: timeout)
  }

  @Test func beginningAPreviewRotatesTheDisplayAndStartsTheClock() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake)

    let result = await session.begin(request())
    #expect(result.isSuccess)
    #expect(fake.rotation(of: 2) == .ninety)
    #expect(await session.secondsRemaining == 30)
    #expect(await session.isCountingDown)
  }

  /// The structural difference from every other preview session here: a
  /// rotation is already permanent when it is applied (RS7), so confirming it
  /// writes NOTHING. A `confirm` that re-applied would be a second blocking
  /// second-long call for no effect.
  @Test func confirmingWritesNothingBecauseTheRotationIsAlreadyPermanent() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake)
    _ = await session.begin(request())
    let appliedAfterBegin = fake.appliedRotations.count

    #expect(await session.confirm(request()) == .committed)
    #expect(fake.appliedRotations.count == appliedAfterBegin)
    #expect(fake.rotation(of: 2) == .ninety)
    #expect(await session.previewed == nil)
    #expect(await session.isCountingDown == false)
  }

  @Test func revertingPutsTheDisplayBackWhereItStarted() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .twoSeventy]
    let session = session(fake)
    _ = await session.begin(request(from: .twoSeventy, to: .standard))
    #expect(fake.rotation(of: 2) == .standard)

    #expect(await session.revert(request(from: .twoSeventy, to: .standard)) == .reverted)
    #expect(fake.rotation(of: 2) == .twoSeventy)
    #expect(await session.previewed == nil)
  }

  @Test func anUnansweredPreviewRevertsWhenTheClockRunsOut() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake, timeout: 3)
    _ = await session.begin(request())

    #expect(await session.tick() == nil)
    #expect(await session.tick() == nil)
    #expect(fake.rotation(of: 2) == .ninety, "still previewing until the clock is spent")
    #expect(await session.tick() == .reverted)
    #expect(fake.rotation(of: 2) == .standard)
    // Spent: a later tick must not re-run the revert every second.
    #expect(await session.tick() == nil)
  }

  /// An answer is given about something a person was looking at. Applying it to
  /// a different preview would resolve an angle they never saw.
  @Test func anAnswerAboutADifferentPreviewResolvesNothing() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake)
    _ = await session.begin(request(to: .ninety))

    #expect(await session.confirm(request(to: .oneEighty)) == .stale)
    #expect(await session.revert(request(3)) == .stale)
    #expect(await session.previewed == request(to: .ninety))
    #expect(fake.rotation(of: 2) == .ninety)
  }

  /// A second request supersedes rather than nests, and its `from` is where the
  /// display actually is — so one revert returns to the previous preview's
  /// angle, not two steps back.
  @Test func aSecondPreviewSupersedesTheFirstAndRevertsToItsOwnStartingAngle() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake)
    _ = await session.begin(request(from: .standard, to: .ninety))
    _ = await session.begin(request(from: .ninety, to: .oneEighty))

    #expect(await session.previewed == request(from: .ninety, to: .oneEighty))
    #expect(await session.revert(request(from: .ninety, to: .oneEighty)) == .reverted)
    #expect(fake.rotation(of: 2) == .ninety)
  }

  @Test func aFailedBeginLeavesNothingOutstandingToAnswer() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    fake.failRotationWith = DisplayConfigError(cgErrorCode: 1001)
    let session = session(fake)

    let result = await session.begin(request())
    #expect(result.isSuccess == false)
    #expect(await session.previewed == nil)
    #expect(await session.isCountingDown == false)
  }

  /// A revert that fails spends the clock rather than retrying every second —
  /// and reports the failure instead of claiming the display came back.
  @Test func aFailedRevertStopsTheClockAndReportsRatherThanRetrying() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake, timeout: 1)
    _ = await session.begin(request())
    fake.failRotationWith = DisplayConfigError(cgErrorCode: 1004)

    #expect(await session.tick() == .failed(DisplayConfigError(cgErrorCode: 1004)))
    #expect(await session.isCountingDown == false)
    #expect(await session.tick() == nil)
  }

  @Test func aDepartedDisplayLeavesNoOutstandingRequest() async {
    let fake = FakeConfigurator()
    fake.rotations = [2: .standard]
    let session = session(fake)
    _ = await session.begin(request())

    await session.discardOnDeparture()
    #expect(await session.previewed == nil)
    #expect(await session.isCountingDown == false)
    // Nothing was rotated back — an absent display cannot be.
    #expect(fake.appliedRotations.count == 1)
  }
}

private extension Result where Success == Void {
  var isSuccess: Bool { if case .success = self { true } else { false } }
}
