import Foundation
import Testing
@testable import CandelaKit

/// The reapply path has nobody watching it, so every rule it follows is pinned
/// here rather than left to the one call site.
@Suite("Mode reapply policy")
struct ModeReapplyPolicyTests {
  private func mode(
    _ id: Int32, logical: (Int, Int), pixels: (Int, Int), hz: Double = 60
  ) -> DisplayMode {
    DisplayMode(ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
                pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
                isNative: false)
  }

  private var native: DisplayMode { mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 60) }
  private var faster: DisplayMode { mode(2, logical: (2560, 1440), pixels: (5120, 2880), hz: 120) }
  private var smaller: DisplayMode { mode(3, logical: (1920, 1080), pixels: (3840, 2160), hz: 60) }

  /// DM5. The stored descriptor is only half the gate; a display whose owner
  /// never opted in must not be moved even when a perfect match is sitting
  /// there.
  @Test func aDisplayNobodyOptedInForIsNeverMoved() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: false, stored: native.descriptor, available: [native, faster], current: faster
    )
    #expect(decision == .doNothing)
  }

  @Test func nothingStoredIsNothingToDo() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: nil, available: [native, faster], current: faster
    )
    #expect(decision == .doNothing)
  }

  @Test func anExactMatchIsAppliedAndSaysNothing() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [native, faster], current: faster
    )
    #expect(decision.modeToApply == native)
    #expect(decision.notice == nil)
  }

  /// Applying the mode a display already runs still costs a full CoreGraphics
  /// reconfiguration — a blank screen, suspended DDC writes, and another
  /// topology event that arrives back at this same decision. At launch, for
  /// every remembered display, for nothing.
  @Test func aDisplayAlreadyOnItsStoredModeIsLeftAlone() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [native, faster], current: native
    )
    #expect(decision == .doNothing)
  }

  /// CoreGraphics reports 59.997 for 60 Hz. Comparing exactly would decide the
  /// display is never already where it is, and reconfigure it on every launch.
  @Test func floatNoiseDoesNotCountAsADifferentMode() {
    let noisy = mode(9, logical: (2560, 1440), pixels: (5120, 2880), hz: 59.997)
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [noisy], current: noisy
    )
    #expect(decision == .doNothing)
  }

  /// A different `ioModeID` for the same geometry is not a different mode: IDs
  /// are positional and get reassigned across replug, which is the whole reason
  /// a DESCRIPTOR is what gets stored.
  @Test func aReassignedModeIDIsNotAReasonToReconfigure() {
    let sameGeometryNewID = mode(77, logical: (2560, 1440), pixels: (5120, 2880), hz: 60)
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor,
      available: [sameGeometryNewID], current: sameGeometryNewID
    )
    #expect(decision == .doNothing)
  }

  /// A display that cannot say what mode it is running is not in a state to be
  /// reconfigured — which in practice means asleep, or mirrored. The old
  /// behaviour applied blind, on the grounds that skipping would silently drop
  /// the reapply; the failure that made it wrong is that a blind apply which
  /// FAILS reports a failure that stands until the display is physically
  /// replugged, because a wake is not a departure and only an absence re-arms an
  /// arrival. Deferring drops nothing: the claim goes back, and the wake is
  /// itself a reconfiguration event that runs this again.
  @Test func anUnreadableCurrentModeIsDeferredRatherThanAppliedBlind() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [native], current: nil
    )
    #expect(decision == .deferred)
    #expect(decision.modeToApply == nil)
    #expect(decision.notice == nil)
    #expect(decision.isDeferred)
  }

  /// Deferral is decided BEFORE resolution, so an unreadable display cannot
  /// produce a failure report either. Its mode list is as untrustworthy as its
  /// current mode, and "no acceptable mode on this display" is a permanent-
  /// sounding statement to make about a display that was merely asleep.
  @Test func anUnreadableDisplayIsNotReportedAsHavingNoCandidate() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [], current: nil
    )
    #expect(decision == .deferred)
  }

  /// `displays()` enumerates ONLINE displays, so a hardware-mirrored secondary
  /// is claimed as an arrival like any other. It must not take an unattended
  /// session-scope mode change: the pixels on it are the master's, so this is a
  /// reconfiguration nobody asked for and nobody can see the result of.
  @Test func aMirrorSlaveIsNeverMovedUnattended() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, isMirroringAnotherDisplay: true, stored: native.descriptor,
      available: [native, faster], current: faster
    )
    #expect(decision == .deferred)
    #expect(decision.modeToApply == nil)
  }

  /// Deferred, not dismissed. Marking a mirror slave handled would mean it is
  /// never reapplied for the rest of the connection — including after the user
  /// breaks the mirror, which is exactly when its own resolution starts to
  /// matter again.
  @Test func aMirrorSlaveIsDeferredRatherThanSilentlyHandled() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, isMirroringAnotherDisplay: true, stored: native.descriptor,
      available: [native], current: smaller
    )
    #expect(decision.isDeferred)
    #expect(decision != .doNothing)
    #expect(decision.notice == nil)
  }

  /// Only the slave. The master owns the framebuffer the whole set is showing,
  /// so its resolution is the set's resolution and the stored choice applies to
  /// it exactly as it would with no mirror at all.
  @Test func theMasterOfAMirrorSetIsAnOrdinaryTarget() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, isMirroringAnotherDisplay: false, stored: native.descriptor,
      available: [native, faster], current: faster
    )
    #expect(decision.modeToApply == native)
    #expect(!decision.isDeferred)
  }

  @Test func aNearestRefreshRateIsAppliedAndReported() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [faster], current: smaller
    )
    #expect(decision.modeToApply == faster)
    #expect(decision.notice == .substituted(faster))
  }

  @Test func aDifferentSizeIsAppliedAndReported() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [smaller], current: smaller
    )
    // Already there, so nothing to apply — and still reported: the stored
    // choice is no more honoured than if we had just moved it here.
    #expect(decision.modeToApply == nil)
    #expect(decision.notice == .substituted(smaller))
  }

  /// The quiet failure this task exists to prevent: a substitute that lands
  /// without a word, on a display the user set deliberately.
  @Test func aSubstituteIsNeverSilent() {
    for available in [[faster], [smaller]] {
      let decision = ModeReapplyPolicy.decide(
        isEnabled: true, stored: native.descriptor, available: available,
        current: available[0]
      )
      #expect(decision.notice != nil)
    }
  }

  @Test func noCandidateChangesNothingAndSaysSo() {
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: native.descriptor, available: [], current: native
    )
    #expect(decision.modeToApply == nil)
    #expect(decision.notice == .unavailable)
  }

  /// Never across aspect ratios (`ModePersistence.resolve` step 4). A 16:9
  /// substitute on a 21:9 panel is worse than doing nothing, and "worse than
  /// nothing" applied unattended is the case with no undo.
  @Test func anIncompatibleAspectRatioIsReportedRatherThanForced() {
    let ultrawide = DisplayModeDescriptor(
      logicalWidth: 3440, logicalHeight: 1440, pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175
    )
    let decision = ModeReapplyPolicy.decide(
      isEnabled: true, stored: ultrawide, available: [native, smaller], current: native
    )
    #expect(decision.modeToApply == nil)
    #expect(decision.notice == .unavailable)
  }
}
