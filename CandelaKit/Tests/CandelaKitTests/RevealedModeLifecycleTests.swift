import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

/// A revealed mode must survive the lifecycle a published mode does: preview
/// with a revert-by-default countdown, commit on confirm, and match back after
/// a replug. The engine routes on provenance, so coverage of published modes is
/// not evidence these paths work.
@Suite("Revealed mode lifecycle")
struct RevealedModeLifecycleTests {
  /// The MAG's 1920x804 at 2x, the mode the hardware pass actually applies.
  private func revealed(_ id: Int32 = 101) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: 1920, logicalHeight: 804,
      pixelWidth: 3840, pixelHeight: 1608, refreshHz: 175,
      isNative: false, provenance: .coreGraphicsServices)
  }

  private func published(_ id: Int32 = 69) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: 3440, logicalHeight: 1440,
      pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175,
      isNative: true, provenance: .coreGraphics)
  }

  // MARK: - Preview

  @Test func previewingARevealedModeUsesPreviewScope() async {
    let fake = FakeConfigurator()
    fake.current = published()
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: revealed(), on: 3)
    #expect(fake.applied == [.init(modeID: 101, scope: .preview)])
  }

  @Test func confirmingARevealedModeCommitsAtSessionScope() async {
    let fake = FakeConfigurator()
    fake.current = published()
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: revealed(), on: 3)
    let outcome = await session.confirm(PreviewedMode(displayID: 3, mode: revealed()))
    #expect(outcome == .committed)
    #expect(fake.applied.last == .init(modeID: 101, scope: .session))
  }

  /// The safety property, on the path that has no pre-commit geometry guard:
  /// reverting must put back the mode that was on screen BEFORE the preview.
  @Test func revertingARevealedModeRestoresThePublishedMode() async {
    let fake = FakeConfigurator()
    fake.current = published()
    let session = ModePreviewSession(configurator: fake)
    _ = await session.begin(mode: revealed(), on: 3)
    let outcome = await session.revert(PreviewedMode(displayID: 3, mode: revealed()))
    #expect(outcome == .reverted)
    #expect(fake.applied.last?.modeID == 69)
  }

  /// A revealed mode the display refuses must not be recorded as applied: the
  /// caller reverts on a throw, and there is no other signal.
  @Test func aFailedRevealedPreviewSurfacesTheError() async {
    let fake = FakeConfigurator()
    fake.current = published()
    fake.failWith = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    let session = ModePreviewSession(configurator: fake)
    let result = await session.begin(mode: revealed(), on: 3)
    #expect(throws: DisplayConfigError.self) { try result.get() }
  }

  // MARK: - Persistence

  /// Descriptors carry geometry, never provenance. A revealed mode must
  /// therefore resolve out of a merged list after a replug.
  @Test func aRevealedModeRoundTripsThroughItsDescriptor() {
    let stored = revealed().descriptor
    let match = ModePersistence.resolve(stored, in: [published(), revealed()])
    guard case let .exact(found) = match else {
      Issue.record("expected an exact match, got \(match)")
      return
    }
    #expect(found.ioModeID == 101)
    #expect(found.provenance == .coreGraphicsServices)
  }

  /// Mode IDs are positional and get reassigned. The descriptor must re-find
  /// the mode by geometry even when its id has moved.
  @Test func aRevealedModeResolvesAfterItsIDIsReassigned() {
    let stored = revealed(101).descriptor
    let afterReplug = [published(), revealed(140)]
    let match = ModePersistence.resolve(stored, in: afterReplug)
    guard case let .exact(found) = match else {
      Issue.record("expected an exact match, got \(match)")
      return
    }
    #expect(found.ioModeID == 140)
  }

  /// If revelation goes away (a macOS update moves the struct, the symbol
  /// vanishes), a stored revealed mode must degrade honestly rather than
  /// resolve to the blurry 1x mode at the same logical size.
  @Test func aStoredRevealedModeDoesNotSilentlyBecomeItsOneXTwin() {
    let stored = revealed().descriptor
    let oneXTwin = DisplayMode(
      ioModeID: 57, logicalWidth: 1920, logicalHeight: 804,
      pixelWidth: 1920, pixelHeight: 804, refreshHz: 175,
      isNative: false, provenance: .coreGraphics)
    let match = ModePersistence.resolve(stored, in: [published(), oneXTwin])
    if case .exact = match {
      Issue.record("a 1x mode must not satisfy a stored HiDPI descriptor exactly")
    }
  }
}
