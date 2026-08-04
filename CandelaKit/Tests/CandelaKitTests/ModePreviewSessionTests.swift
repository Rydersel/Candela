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

  /// One `applyMirroring` call. A struct, not a tuple, so a test can `#expect`
  /// a whole batch against an expected list.
  struct AppliedMirroring: Equatable {
    let changes: [MirrorChange]
    let scope: DisplayConfigScope
  }

  private let lock = NSLock()
  private var _applied: [Applied] = []
  private var _appliedDisplayIDs: [CGDirectDisplayID] = []
  private var _current: DisplayMode?
  private var _failWith: DisplayConfigError?
  private var _failOnlyDisplay: CGDirectDisplayID?
  private var _available: [DisplayMode] = []
  private var _appliedMirroring: [AppliedMirroring] = []
  private var _configuredDisplays: [ConfiguredDisplay] = []
  private var _failMirroringWith: DisplayConfigError?

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

  /// Scopes `failWith` to one display. Without it a fake that fails at all
  /// masks the case where reverting display A fails while previewing display B
  /// would have succeeded.
  var failOnlyDisplay: CGDirectDisplayID? {
    get { lock.withLock { _failOnlyDisplay } }
    set { lock.withLock { _failOnlyDisplay = newValue } }
  }

  var available: [DisplayMode] {
    get { lock.withLock { _available } }
    set { lock.withLock { _available = newValue } }
  }

  var appliedMirroring: [AppliedMirroring] { lock.withLock { _appliedMirroring } }

  /// What `displays()` reports. Settable because the mirror session captures a
  /// topology from it before every preview.
  var configuredDisplays: [ConfiguredDisplay] {
    get { lock.withLock { _configuredDisplays } }
    set { lock.withLock { _configuredDisplays = newValue } }
  }

  /// Scoped separately from `failWith` on purpose: a fake that fails BOTH
  /// applies masks the case where a mode revert succeeds and a mirror commit
  /// does not, which is the ordering rule between the two sessions.
  var failMirroringWith: DisplayConfigError? {
    get { lock.withLock { _failMirroringWith } }
    set { lock.withLock { _failMirroringWith = newValue } }
  }

  func displays() -> [ConfiguredDisplay] { configuredDisplays }
  func modes(for _: CGDirectDisplayID) -> [DisplayMode] { available }
  func currentMode(for _: CGDirectDisplayID) -> DisplayMode? { current }
  func nativePixels(for _: CGDirectDisplayID) -> (width: Int, height: Int)? { nil }

  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
    try lock.withLock {
      if let _failWith, _failOnlyDisplay == nil || _failOnlyDisplay == displayID {
        throw _failWith
      }
      _applied.append(Applied(modeID: mode.ioModeID, scope: scope))
      _appliedDisplayIDs.append(displayID)
      _current = mode
    }
  }

  func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    try lock.withLock {
      // ORDER IS LOAD-BEARING: the empty-batch guard runs BEFORE the injection
      // point, because `CoreGraphicsDisplayConfigurator.applyMirroring` returns
      // on its own empty guard before it can reach anything that fails. A fake
      // that checked `failMirroringWith` first would throw for an empty batch —
      // a failure production cannot produce.
      //
      // Not hypothetical. `MirrorTopologyPolicy.changes(from:to:)` returns `[]`
      // whenever the live topology already matches the capture, which is the
      // COMMON case on a revert. A session test that set `failMirroringWith`
      // and drove a revert would otherwise exercise, and then enshrine, a
      // "revert failed" branch that is unreachable in shipped code.
      guard !changes.isEmpty else { return }
      if let _failMirroringWith { throw _failMirroringWith }
      _appliedMirroring.append(AppliedMirroring(changes: changes, scope: scope))
      // The fake's topology follows the change, so a session that re-reads
      // `displays()` after applying sees what it asked for — which is what
      // makes the revert-path tests real rather than tautological.
      //
      // MASTER membership is RECOMPUTED over the whole post-state rather than
      // read off the batch, and that distinction is load-bearing. A master is
      // usually not named in `changes` at all (engaging names only the slaves),
      // so deriving its membership from the batch leaves it
      // `isInMirrorSet == false` — and `isMirrorMaster` requires the flag, so
      // `MirrorTopology.masters` would come back EMPTY from a topology that
      // plainly has a master. The mirror that a test then "breaks" would be one
      // no policy could see. CoreGraphics reports the master as a set member;
      // so does this.
      //
      // SLAVE membership is NOT computed here. The expression below asks only
      // "does anyone mirror me", which is true of masters and false of slaves;
      // a slave arrives at `isInMirrorSet == true` solely because
      // `ConfiguredDisplay.init` ORs in `mirrorsDisplay != kCGNullDirectDisplay`
      // (`DisplayConfiguring.swift:96`). That is a real dependency on another
      // type's derivation, not an accident, and
      // `theFakeReportsSlaveMembershipAndSetMembersLikeCoreGraphicsDoes` asserts
      // it — otherwise deleting that OR would leave the fake lying about every
      // slave with this suite still green.
      let post = _configuredDisplays.map { display in
        (display, changes.first { $0.display == display.id }?.master ?? display.mirrorsDisplay)
      }
      _configuredDisplays = post.map { display, mirrors in
        ConfiguredDisplay(
          id: display.id,
          identity: display.identity,
          name: display.name,
          isBuiltIn: display.isBuiltIn,
          mirrorsDisplay: mirrors,
          // A master's membership ends with its last slave: recomputing from the
          // post-state is what makes a break leave NOBODY in a set, rather than
          // a masterless set with one stale member.
          isInMirrorSet: post.contains { $0.1 == display.id && $0.1 != kCGNullDirectDisplay },
          isAlwaysInMirrorSet: display.isAlwaysInMirrorSet
        )
      }
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

  /// The answer a UI gives about a preview it rendered. `confirm`/`revert` take
  /// one so an answer can only ever resolve the preview it was given for.
  private func answer(_ id: Int32, on displayID: CGDirectDisplayID = 7) -> PreviewedMode {
    PreviewedMode(displayID: displayID, mode: mode(id))
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
    let outcome = await session.confirm(answer(2))
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
    let outcome = await session.revert(answer(2))
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
    #expect(await session.confirm(answer(2)) == .committed)
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
    #expect(await session.confirm(answer(2)) == .committed)
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
    #expect(await session.revert(answer(3)) == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
  }

  /// A double-click on "Keep" must not report a reversion that never happened —
  /// the UI would tell the user the opposite of what the display is doing.
  @Test func answeringTwiceRepeatsTheOutcomeItAlreadyProduced() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.confirm(answer(2)) == .committed)
    let countAfterConfirm = fake.applied.count
    #expect(await session.confirm(answer(2)) == .committed)
    #expect(await session.revert(answer(2)) == .committed)
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
    #expect(await session.revert(answer(3, on: 8)) == .reverted)
    #expect(fake.applied == [
      .init(modeID: 2, scope: .preview),
      .init(modeID: 1, scope: .session),
      .init(modeID: 3, scope: .preview),
      .init(modeID: 1, scope: .session),
    ])
    #expect(fake.appliedDisplayIDs == [7, 7, 8, 8])
  }

  // MARK: - Failed resolutions
  //
  // An apply that throws moves nothing, so the preview is still on screen and
  // the pre-preview mode is still the truth about where to go back to. These
  // pin that a failed resolution is recoverable rather than terminal.

  @Test func aFailedExpiryRevertStaysRevertibleAndRecovers() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 1)
    _ = await session.begin(mode: mode(2), on: 7)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)

    #expect(await session.tick() == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await session.hasOutstandingPreview)
    #expect(await session.tick() == nil) // the countdown fires once, not forever

    fake.failWith = nil // CoreGraphics recovers
    #expect(await session.revert(answer(2)) == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
    #expect(await session.hasOutstandingPreview == false)
  }

  /// The state that used to be unescapable: after the expiry revert throws, a
  /// fresh preview must still fall back to the mode the user started on — not
  /// to the unapproved preview that is currently on screen.
  @Test func aFailedResolutionDoesNotLoseTheOriginalMode() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 1)
    _ = await session.begin(mode: mode(2), on: 7)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await session.tick() == .failed(DisplayConfigError(cgErrorCode: 1001)))

    fake.failWith = nil
    _ = await session.begin(mode: mode(3), on: 7) // user tries a different mode
    #expect(await session.revert(answer(3)) == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
  }

  @Test func aFailedCommitLeavesThePreviewRevertible() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)

    #expect(await session.confirm(answer(2)) == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await session.hasOutstandingPreview)

    fake.failWith = nil
    #expect(await session.revert(answer(2)) == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
  }

  /// A commit that could not be made permanent leaves the display on a mode
  /// held only by process scope, so the countdown stays armed and still falls
  /// back to something the user can definitely see.
  @Test func aFailedCommitLeavesTheCountdownRunningSoItStillFallsBack() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 2)
    _ = await session.begin(mode: mode(2), on: 7)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await session.confirm(answer(2)) == .failed(DisplayConfigError(cgErrorCode: 1001)))

    fake.failWith = nil
    #expect(await session.tick() == nil)
    #expect(await session.tick() == .reverted)
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
  }

  /// Refuse rather than report success: previewing display 8 while display 7
  /// cannot be restored would strand 7 on an unapproved mode silently.
  @Test func previewingAnotherDisplayIsRefusedWhenTheFirstCannotBeReverted() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    fake.failOnlyDisplay = 7

    let result = await session.begin(mode: mode(3), on: 8)
    #expect(result.failureError == DisplayConfigError(cgErrorCode: 1001))
    #expect(fake.applied == [.init(modeID: 2, scope: .preview)]) // 8 never previewed

    fake.failWith = nil
    #expect(await session.revert(answer(2)) == .reverted) // 7 is still the outstanding one
    #expect(fake.applied.last == .init(modeID: 1, scope: .session))
    #expect(fake.appliedDisplayIDs.last == 7)
  }

  /// A `begin()` that fails establishes nothing, so it must not erase what the
  /// session already reported. Otherwise a commit followed by a failed begin
  /// leaves the session claiming a reversion — telling the UI the opposite of
  /// what happened to the screen. Both of `begin()`'s failure exits are
  /// exercised: the unreadable fallback and the throwing apply.
  @Test func aFailedBeginDoesNotEraseTheOutcomeAlreadyReported() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.confirm(answer(2)) == .committed)

    fake.current = nil // no readable fallback: begin refuses before applying
    var result = await session.begin(mode: mode(3), on: 7)
    #expect(result.failureError == DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    #expect(await session.confirm(answer(3)) == .committed)
    #expect(await session.revert(answer(3)) == .committed)

    fake.current = mode(2)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001) // the apply itself throws
    result = await session.begin(mode: mode(3), on: 7)
    #expect(result.failureError == DisplayConfigError(cgErrorCode: 1001))
    #expect(await session.confirm(answer(3)) == .committed)
  }

  @Test func theCountdownStopsBeingReportedOnceResolved() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 15)
    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.secondsRemaining == 15)
    #expect(await session.tick() == nil)
    #expect(await session.secondsRemaining == 14)
    _ = await session.confirm(answer(2))
    #expect(await session.secondsRemaining == 0)
  }

  // MARK: - State a UI rebuilds itself from (Task 8)

  @Test func theSessionReportsWhatIsPreviewedSoAUINeverHasToRemember() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 15)
    #expect(await session.previewedMode == nil)
    #expect(await session.isCountingDown == false)

    _ = await session.begin(mode: mode(2), on: 7)
    #expect(await session.previewedMode == PreviewedMode(displayID: 7, mode: mode(2)))
    #expect(await session.isCountingDown)

    _ = await session.confirm(answer(2))
    #expect(await session.previewedMode == nil)
    #expect(await session.isCountingDown == false)
  }

  /// A failed expiry disarms the countdown; a failed commit does not. A UI that
  /// inferred either one would show a countdown that never fires, or hide one
  /// that will.
  @Test func aFailedExpiryStopsCountingDownWhileAFailedCommitKeepsCounting() async {
    let expiry = FakeConfigurator()
    expiry.current = mode(1)
    let expirySession = ModePreviewSession(configurator: expiry, countdownSeconds: 1)
    _ = await expirySession.begin(mode: mode(2), on: 7)
    expiry.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await expirySession.tick() == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await expirySession.hasOutstandingPreview)
    #expect(await expirySession.isCountingDown == false)

    let commit = FakeConfigurator()
    commit.current = mode(1)
    let commitSession = ModePreviewSession(configurator: commit, countdownSeconds: 15)
    _ = await commitSession.begin(mode: mode(2), on: 7)
    commit.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await commitSession.confirm(answer(2)) == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await commitSession.isCountingDown)
  }

  /// A departed display cannot be reverted onto. Without `discard`, `begin()`
  /// on any OTHER display reverts the outstanding preview first, fails, and
  /// refuses — so one unplug would wedge mode switching for the whole session.
  @Test func discardingADepartedDisplayAppliesNothingAndUnblocksOtherDisplays() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 15)
    _ = await session.begin(mode: mode(2), on: 7)
    let appliedBefore = fake.applied

    #expect(await session.discard(displayID: 9) == false) // not that display
    #expect(await session.discard(displayID: 7))
    #expect(fake.applied == appliedBefore) // nothing was applied to a dead display
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
    #expect(await session.tick() == nil)

    fake.current = mode(5)
    #expect(await session.begin(mode: mode(6), on: 8).failureError == nil)
    #expect(await session.previewedMode == PreviewedMode(displayID: 8, mode: mode(6)))
  }

  // MARK: - An answer only resolves the preview it was given for

  /// The worst failure this type can produce: the user clicks Keep on a banner
  /// naming one mode, a second selection lands in between, and the mode they
  /// never saw becomes permanent at session scope while the UI reports success.
  /// Ordering alone cannot prevent it — the click runs one turn before the call
  /// — so the answer carries what it was about and the session refuses it.
  @Test func anAnswerForASupersededPreviewCommitsNothing() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    _ = await session.begin(mode: mode(3), on: 7) // a second selection lands

    #expect(await session.confirm(answer(2)) == .stale)
    #expect(fake.applied.allSatisfy { $0.scope == .preview }) // nothing committed
    // Untouched and still resolvable: the preview that IS outstanding keeps its
    // countdown and its fallback.
    #expect(await session.previewedMode == PreviewedMode(displayID: 7, mode: mode(3)))
    #expect(await session.isCountingDown)
    #expect(await session.confirm(answer(3)) == .committed)
    #expect(fake.applied.last == .init(modeID: 3, scope: .session))
  }

  /// Same rule for the other answer, across displays — a revert aimed at the
  /// display the banner named must not restore a different display.
  @Test func aRevertForAnotherDisplaysPreviewRestoresNothing() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake, countdownSeconds: 15)
    _ = await session.begin(mode: mode(2), on: 7)
    _ = await session.begin(mode: mode(3), on: 8) // 7 is reverted and released
    let appliedBefore = fake.applied

    #expect(await session.revert(answer(2, on: 7)) == .stale)
    #expect(fake.applied == appliedBefore)
    #expect(await session.previewedMode == PreviewedMode(displayID: 8, mode: mode(3)))
    #expect(await session.isCountingDown)
    #expect(await session.revert(answer(3, on: 8)) == .reverted)
    #expect(fake.appliedDisplayIDs.last == 8)
  }

  /// A stale answer must not be mistaken for the retry path either: after a
  /// failed commit the banner is still showing the SAME preview, so its answer
  /// still matches and recovery keeps working.
  @Test func theRetryPathStillMatchesAfterAFailedResolution() async {
    let fake = FakeConfigurator()
    fake.current = mode(1)
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: mode(2), on: 7)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await session.confirm(answer(2)) == .failed(DisplayConfigError(cgErrorCode: 1001)))

    fake.failWith = nil
    #expect(await session.confirm(answer(2)) == .committed)
  }
}
