import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Records what was applied so the tests can assert on scope, which is the
/// difference between "previewed" and "committed".
///
/// `@unchecked Sendable` is justified by confinement: every stored property
/// lives behind `lock`, and the accessors below are the only way in. The tests
/// need that because the session is an actor — its calls into this fake run on
/// the actor's executor while the test body reads `applied` from its own task.
final class FakeConfigurator: DisplayConfiguring, @unchecked Sendable {
  struct Applied: Equatable {
    let modeID: Int32
    let scope: DisplayConfigScope
  }

  private let lock = NSLock()
  private var _applied: [Applied] = []
  private var _appliedDisplayIDs: [CGDirectDisplayID] = []
  private var _current: DisplayMode?
  private var _failWith: DisplayConfigError?
  private var _available: [DisplayMode] = []

  var applied: [Applied] { lock.withLock { _applied } }
  /// Kept alongside rather than inside `Applied` so the scope assertions stay
  /// as short as they are — only the multi-display test cares who got what.
  var appliedDisplayIDs: [CGDirectDisplayID] { lock.withLock { _appliedDisplayIDs } }
  var current: DisplayMode? {
    get { lock.withLock { _current } }
    set { lock.withLock { _current = newValue } }
  }

  var failWith: DisplayConfigError? {
    get { lock.withLock { _failWith } }
    set { lock.withLock { _failWith = newValue } }
  }

  var available: [DisplayMode] {
    get { lock.withLock { _available } }
    set { lock.withLock { _available = newValue } }
  }

  func displays() -> [ConfiguredDisplay] { [] }
  func modes(for _: CGDirectDisplayID) -> [DisplayMode] { available }
  func currentMode(for _: CGDirectDisplayID) -> DisplayMode? { current }
  func nativePixels(for _: CGDirectDisplayID) -> (width: Int, height: Int)? { nil }

  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
    try lock.withLock {
      if let _failWith { throw _failWith }
      _applied.append(Applied(modeID: mode.ioModeID, scope: scope))
      _appliedDisplayIDs.append(displayID)
      _current = mode
    }
  }
}

/// `Result<Void, _>` is not `Equatable` — `Void` isn't — so the failures are
/// compared through their error rather than as whole results.
private extension Result where Success == Void, Failure == DisplayConfigError {
  var failureError: DisplayConfigError? {
    if case let .failure(error) = self { return error }
    return nil
  }
}

@Suite("Mode preview session")
struct ModePreviewSessionTests {
  private func mode(_ id: Int32) -> DisplayMode {
    DisplayMode(ioModeID: id, logicalWidth: 2560, logicalHeight: 1440,
                pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60,
                isNative: false)
  }

  @Test func beginningAPreviewAppliesWithPreviewScopeNotSession() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(fake.applied == [.init(modeID: 2, scope: .preview)])
  }

  @Test func confirmingReappliesWithSessionScope() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    let outcome = await session.confirm()
    #expect(outcome == .committed)
    #expect(fake.applied.last == .init(modeID: 2, scope: .session))
  }

  /// The safety property. Timing out must restore the ORIGINAL mode — if this
  /// inverts, a mode that makes the screen unreadable becomes permanent and
  /// the user cannot undo it from inside the app.
  @Test func theCountdownDefaultsToRevertingNotKeeping() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 2)
    _ = await session.begin(mode: mode(2), on: 7)

    #expect(await session.tick() == nil) // 1 left
    let outcome = await session.tick() // expires
    #expect(outcome == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
  }

  @Test func revertingRestoresTheExactPrePreviewMode() async {
    let fake = FakeConfigurator()
    fake.current = mode(42)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    let outcome = await session.revert()
    #expect(outcome == .reverted)
    #expect(fake.applied.last == .init(modeID: 42, scope: .session))
  }

  @Test func aFailedApplyReportsTheErrorAndAppliesNothing() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    let session = ModePreviewSession(configurator: fake)
    let result = await session.begin(mode: mode(2), on: 7)
    #expect(result.failureError == DisplayConfigError(cgErrorCode: 1001))
    #expect(fake.applied.isEmpty)
  }

  @Test func tickingAfterResolutionDoesNothing() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 1)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.confirm() == .committed)
    let countAfterConfirm = fake.applied.count
    #expect(await session.tick() == nil)
    #expect(fake.applied.count == countAfterConfirm)
  }

  /// Commit what the USER approved, not whatever the display happens to be
  /// showing when they answer. A replug or a sleep/wake drops the app-only
  /// preview config, so `currentMode` at confirm time can be the old mode
  /// again — committing that would report success while silently discarding
  /// the user's choice.
  @Test func confirmingCommitsTheApprovedModeNotWhateverIsCurrentNow() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)

    fake.current = mode(1) // display reconfigured out from under the preview
    #expect(await session.confirm() == .committed)
    #expect(fake.applied.last == .init(modeID: 2, scope: .session))
  }

  /// Never start a preview that cannot be undone. With no readable current
  /// mode there is nothing to restore, so the countdown would expire into a
  /// no-op and leave the display in a mode nobody approved.
  @Test func aPreviewIsRefusedWhenThePreviousModeCannotBeRead() async {
    let fake = FakeConfigurator()
    fake.current = nil
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 1)
    let result = await session.begin(mode: mode(2), on: 7)
    #expect(result.failureError == DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    #expect(fake.applied.isEmpty)
    #expect(await session.tick() == nil)
  }

  /// Previewing a second mode without answering the first must not adopt the
  /// first preview as the thing to fall back to.
  @Test func aSecondPreviewStillRevertsToTheOriginalMode() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    _ = await session.begin(mode: mode(3), on: 7)
    #expect(await session.revert() == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
  }

  /// A double-click on "Keep" must not report a reversion that never happened —
  /// the UI would tell the user the opposite of what the display is doing.
  @Test func answeringTwiceRepeatsTheOutcomeItAlreadyProduced() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.confirm() == .committed)
    let countAfterConfirm = fake.applied.count
    #expect(await session.confirm() == .committed)
    #expect(await session.revert() == .committed)
    #expect(fake.applied.count == countAfterConfirm)
  }

  /// Retargeting the session at another display must end the first preview,
  /// not carry display 7's fallback mode over to display 8.
  @Test func previewingAnotherDisplayEndsTheFirstPreviewInsteadOfMixingThemUp() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    _ = await session.begin(mode: mode(3), on: 8)
    #expect(await session.revert() == .reverted)
    #expect(fake.applied == [
      .init(modeID: 2, scope: .preview),
      .init(modeID: 1, scope: .session),
      .init(modeID: 3, scope: .preview),
      .init(modeID: 1, scope: .session),
    ])
    #expect(fake.appliedDisplayIDs == [7, 7, 8, 8])
  }

  @Test func theCountdownStopsBeingReportedOnceResolved() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 15)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.secondsRemaining == 15)
    #expect(await session.tick() == nil)
    #expect(await session.secondsRemaining == 14)
    _ = await session.confirm()
    #expect(await session.secondsRemaining == 0)
  }
}
