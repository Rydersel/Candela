import CandelaKit
import CoreGraphics
import Testing

/// SO6's one-answerable-surface property across all THREE owners (DM11).
///
/// The guided setup flow used to borrow `.settingsBanner`, which made a
/// background settings window on the same display's page draw a second
/// answerable banner for one preview. These two suites pin the two halves of
/// the fix: the banner renders nothing for a setup-owned preview, and the
/// floating window is not presented for one either.
@Suite("Preview surface ownership") @MainActor
struct PreviewSurfaceOwnershipTests {
  private static let displayID: CGDirectDisplayID = 4
  private static let otherDisplayID: CGDirectDisplayID = 9

  private static let mode = DisplayMode(
    ioModeID: 11, logicalWidth: 2560, logicalHeight: 1440,
    pixelWidth: 2560, pixelHeight: 1440, refreshHz: 120, isNative: false
  )

  private static func preview(
    surface: DisplayModeCoordinator.PreviewSurface,
    on displayID: CGDirectDisplayID = PreviewSurfaceOwnershipTests.displayID,
    isCountingDown: Bool = true
  ) -> DisplayModeCoordinator.Preview {
    DisplayModeCoordinator.Preview(
      displayID: displayID, mode: mode, surface: surface,
      secondsRemaining: isCountingDown ? 21 : 0, failure: nil,
      isCountingDown: isCountingDown, synthesized: nil, synthesisFailure: nil
    )
  }

  private static func form(
    _ preview: DisplayModeCoordinator.Preview?, ownsAnswerable: Bool = true
  ) -> BannerRegion.CountdownForm? {
    BannerRegion.countdownForm(
      preview: preview, displayID: displayID, ownsAnswerableCountdown: ownsAnswerable
    )
  }

  // MARK: - The settings banner (BannerRegion.countdownForm)

  /// The change. Both stack states, because the answerable placement is the one
  /// that follows the navigation stack and a setup-owned preview must draw
  /// nothing in either.
  @Test func aSetupOwnedPreviewDrawsNoBannerAtAll() {
    #expect(Self.form(Self.preview(surface: .guidedSetup)) == nil)
    #expect(Self.form(Self.preview(surface: .guidedSetup), ownsAnswerable: false) == nil)
  }

  /// Not even a passive line, and the countdown being spent is not what does
  /// it: an armed setup-owned countdown renders nothing either. Separate from
  /// the case above because a `.floatingPanel` preview in these two states
  /// renders differently.
  @Test func aSpentSetupCountdownStillDrawsNothing() {
    #expect(Self.form(Self.preview(surface: .guidedSetup, isCountingDown: false)) == nil)
  }

  /// The lift's proof, part one: the settings banner still answers when it owns
  /// the answer, and gives it up to the pushed placement when it does not.
  @Test func theSettingsBannerStillAnswersWhenItOwnsTheAnswer() {
    #expect(Self.form(Self.preview(surface: .settingsBanner)) == .answerable)
    #expect(Self.form(Self.preview(surface: .settingsBanner), ownsAnswerable: false) == nil)
  }

  /// Part two: the floating window's preview still leaves a passive line here
  /// while its countdown is armed, and none once it is spent.
  @Test func aFloatingPanelPreviewIsStillPassiveWhileArmed() {
    #expect(Self.form(Self.preview(surface: .floatingPanel)) == .passive)
    #expect(Self.form(Self.preview(surface: .floatingPanel, isCountingDown: false)) == nil)
  }

  /// Part three: the display test and the no-preview case, both of which the
  /// lift had to carry across unchanged.
  @Test func aPreviewOnAnotherDisplayRendersNothingHere() {
    #expect(Self.form(nil) == nil)
    #expect(Self.form(Self.preview(surface: .settingsBanner, on: Self.otherDisplayID)) == nil)
  }

  // MARK: - The floating confirmation window (syncConfirmation)

  /// The other half, through the real coordinator and the real preview session:
  /// a setup-owned preview presents no floating confirmation window.
  @Test func aSetupOwnedPreviewPresentsNoFloatingConfirmation() async throws {
    let fixture = SynthesisFixture(optedIn: false)
    defer { fixture.forgetPrefs() }
    let presenter = FakeModeConfirmation()
    fixture.modes.confirmation = presenter
    let smaller = try #require(
      fixture.modes.catalogs[SynthesisFixture.panelID]?.all.first { $0.logicalWidth == 2560 })

    fixture.modes.select(
      smaller, on: SynthesisFixture.panelID, from: .settings, surface: .guidedSetup)
    await fixture.settle()

    #expect(fixture.modes.preview != nil, "the select really did open a countdown")
    #expect(presenter.presented.isEmpty, "the setup window owns the answer")
    // Weaker than the line above and kept for what it rules out: the presenter
    // was wired and reachable, so the empty presentation list is a decision
    // rather than a coordinator that never spoke to it.
    #expect(presenter.dismissals > 0)
    await fixture.revertAnyPreview()
  }

  /// The positive control the case above is worthless without: the same select
  /// with the default surface DOES present the window, so an empty
  /// `presented` there is ownership rather than an unwired presenter.
  @Test func theSameSelectStillPresentsItForTheDefaultSurface() async throws {
    let fixture = SynthesisFixture(optedIn: false)
    defer { fixture.forgetPrefs() }
    let presenter = FakeModeConfirmation()
    fixture.modes.confirmation = presenter
    let smaller = try #require(
      fixture.modes.catalogs[SynthesisFixture.panelID]?.all.first { $0.logicalWidth == 2560 })

    fixture.modes.select(
      smaller, on: SynthesisFixture.panelID, from: .settings, surface: .floatingPanel)
    await fixture.settle()

    #expect(presenter.presented.contains(.preview(SynthesisFixture.panelID)))
    await fixture.revertAnyPreview()
  }
}

/// Records what the coordinator asked the floating confirmation window to do.
/// The coordinator holds its presenter weakly, so a test has to keep this
/// alive itself for as long as it expects presentations.
@MainActor
private final class FakeModeConfirmation: ModeConfirmationPresenting {
  private(set) var presented: [ModeConfirmationContent] = []
  private(set) var dismissals = 0

  func presentConfirmation(_ content: ModeConfirmationContent) { presented.append(content) }
  func dismissConfirmation() { dismissals += 1 }
}
