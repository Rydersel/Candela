import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// `CGCompleteDisplayConfiguration` can return `.success` over a mode it did not
/// apply; the mirroring path had already measured the platform doing that.
@Suite("Mode apply verification")
struct ModeApplyVerificationTests {
  private func mode(
    id: Int32 = 1,
    logical: (Int, Int) = (2560, 1080),
    pixels: (Int, Int) = (5120, 2160),
    hz: Double = 120,
    native: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz, isNative: native)
  }

  /// The Dell publishes 42 pairs alike in everything but the mode number, and the
  /// live read can answer with either, so an id compare would fail every apply.
  @Test func equalGeometryUnderDifferentIdsIsHonoured() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(id: 7), achieved: mode(id: 291)) == .honoured)
  }

  @Test func aSizeMissIsUnhonoured() {
    #expect(
      ModeApplyVerification.verdict(
        requested: mode(), achieved: mode(logical: (1920, 1080))) == .unhonoured)
    // The 1x twin of the same logical size: the display is scanning out half the
    // pixels the user asked for.
    #expect(
      ModeApplyVerification.verdict(
        requested: mode(), achieved: mode(pixels: (2560, 1080))) == .unhonoured)
  }

  /// A rate-only change looks identical on screen, so nobody answering the keep
  /// card would notice a display left at the rate it started on.
  @Test func aRefreshOnlyMissIsUnhonoured() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(hz: 120), achieved: mode(hz: 60))
        == .unhonoured)
  }

  /// CoreGraphics reports 59.997 for a 60 Hz mode, and an exact compare would
  /// call every honoured apply a failure.
  @Test func refreshNoiseIsStillHonoured() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(hz: 60), achieved: mode(hz: 59.997))
        == .honoured)
  }

  /// No readable mode is not evidence the mode landed, so it takes the same
  /// answer as a miss.
  @Test func anUnreadableModeIsUnhonoured() {
    #expect(ModeApplyVerification.verdict(requested: mode(), achieved: nil) == .unhonoured)
  }

  /// `isNative` is a fact about the panel, not part of a mode's identity; the
  /// live read carries whatever flag the panel reports.
  @Test func theNativeFlagDoesNotDecideTheVerdict() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(native: true), achieved: mode(native: false))
        == .honoured)
  }

  /// Callers branch on this: only a refusal may be reported as "nothing changed",
  /// so sharing `CGError.failure` with a never-opened transaction would hide it.
  @Test func anUnhonouredCommitIsDistinguishableFromARefusal() {
    let committed = DisplayConfigError(
      unhonouredCommit: .init(requested: mode(), achieved: mode(logical: (1920, 1080))))
    #expect(committed.didCommit)
    #expect(committed.cgErrorCode == DisplayConfigError.unhonouredCommitCode)
    #expect(committed.cgErrorCode != CGError.failure.rawValue)
    #expect(committed.unhonouredCommit?.achieved?.logicalWidth == 1920)

    #expect(!DisplayConfigError(cgErrorCode: CGError.failure.rawValue).didCommit)
    #expect(!DisplayConfigError(cgErrorCode: -1).didCommit)
  }
}
