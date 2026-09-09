import CandelaKit
import CoreGraphics
import Testing

/// The one-answerable-surface property across all THREE owners.
///
/// The guided setup flow borrowing `.settingsBanner` made a background settings
/// window on the same display's page draw a second answerable banner for one
/// preview. These suites pin both halves: the banner renders nothing for a
/// setup-owned preview, and the floating window is not presented for one.
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
      isCountingDown: isCountingDown, unhonouredCommit: nil,
      synthesized: nil, synthesisFailure: nil
    )
  }

  private static func form(
    _ preview: DisplayModeCoordinator.Preview?, ownsAnswerable: Bool = true
  ) -> BannerRegion.CountdownForm? {
    BannerRegion.countdownForm(
      preview: preview, displayID: displayID, ownsAnswerableCountdown: ownsAnswerable
    )
  }

  @Test func everySurfaceOffersKeepOnlyForAVerifiedPreview() {
    for surface in [DisplayModeCoordinator.PreviewSurface.settingsBanner, .floatingPanel, .guidedSetup] {
      var preview = Self.preview(surface: surface)
      #expect(preview.canKeep)
      preview.unhonouredCommit = .init(requested: Self.mode, achieved: nil)
      #expect(!preview.canKeep)
      preview.failure = DisplayConfigError(cgErrorCode: 1001)
      #expect(!preview.canKeep)
      #expect(!DisplayModeCopy.previewTitle(canKeep: preview.canKeep).contains("Keep"))
    }
  }

  // MARK: - The settings banner (BannerRegion.countdownForm)

  /// Both stack states, because the answerable placement follows the navigation
  /// stack and a setup-owned preview must draw nothing in either.
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

  /// The settings banner answers when it owns the answer, and gives it up to
  /// the pushed placement when it does not.
  @Test func theSettingsBannerStillAnswersWhenItOwnsTheAnswer() {
    #expect(Self.form(Self.preview(surface: .settingsBanner)) == .answerable)
    #expect(Self.form(Self.preview(surface: .settingsBanner), ownsAnswerable: false) == nil)
  }

  /// A floating window's preview leaves a passive line here while its countdown
  /// is armed, and none once it is spent.
  @Test func aFloatingPanelPreviewIsStillPassiveWhileArmed() {
    #expect(Self.form(Self.preview(surface: .floatingPanel)) == .passive)
    #expect(Self.form(Self.preview(surface: .floatingPanel, isCountingDown: false)) == nil)
  }

  /// The display test and the no-preview case.
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

extension PreviewSurfaceOwnershipTests {
  @Test func coordinatorKeepsLatestRecoveryEvidenceAcrossFailures() async throws {
    let fixture = SynthesisFixture(optedIn: false)
    defer { fixture.forgetPrefs() }
    let displayID = SynthesisFixture.panelID
    let original = try #require(fixture.configurator.currentMode(for: displayID))
    let requested = try #require(fixture.modes.catalogs[displayID]?.all.first { !$0.isNative })
    let first = DisplayMode(
      ioModeID: 80, logicalWidth: 1920, logicalHeight: 804,
      pixelWidth: 3840, pixelHeight: 1608, refreshHz: 60, isNative: false)
    let second = DisplayMode(
      ioModeID: 81, logicalWidth: 1280, logicalHeight: 536,
      pixelWidth: 2560, pixelHeight: 1072, refreshHz: 60, isNative: false)
    fixture.configurator.nextModeApplyFailure = DisplayConfigError(
      unhonouredCommit: .init(requested: requested, achieved: first))
    fixture.modes.select(requested, on: displayID, from: .settings, surface: .settingsBanner)
    await fixture.settle()
    let recovery = try #require(fixture.modes.preview)
    #expect(!recovery.canKeep)
    #expect(recovery.unhonouredCommit?.achieved == first)

    fixture.configurator.nextModeApplyFailure = DisplayConfigError(
      unhonouredCommit: .init(requested: original, achieved: second))
    _ = await fixture.modes.revert(recovery)
    #expect(fixture.modes.preview?.unhonouredCommit?.achieved == second)
    fixture.configurator.refusesModeApplies = true
    _ = await fixture.modes.revert(recovery)
    #expect(fixture.modes.preview?.unhonouredCommit?.achieved == second)
    let beforeKeep = fixture.configurator.applies.count
    #expect(await fixture.modes.confirm(recovery) != .committed)
    #expect(fixture.configurator.applies.count == beforeKeep)
    #expect(fixture.modes.preview?.isCountingDown == true)
    fixture.configurator.refusesModeApplies = false
    #expect(await fixture.modes.revert(recovery) == .reverted)
    #expect(fixture.configurator.applies.last?.mode == original)
  }

  @Test func coordinatorDoesNotStripTheRecoveryAnswerBeforeAFreshSameModePreview() async throws {
    let fixture = SynthesisFixture(optedIn: false)
    defer { fixture.forgetPrefs() }
    let displayID = SynthesisFixture.panelID
    let requested = try #require(fixture.modes.catalogs[displayID]?.all.first { !$0.isNative })
    let original = try #require(fixture.configurator.currentMode(for: displayID))
    fixture.configurator.nextModeApplyFailure = DisplayConfigError(
      unhonouredCommit: .init(requested: requested, achieved: original))
    fixture.modes.select(requested, on: displayID, from: .settings, surface: .settingsBanner)
    await fixture.settle()
    let oldAnswer = try #require(fixture.modes.preview)
    fixture.modes.select(requested, on: displayID, from: .settings, surface: .settingsBanner)
    await fixture.settle()
    let fresh = try #require(fixture.modes.preview)
    #expect(fresh.canKeep)
    let before = fixture.configurator.applies.count
    #expect(await fixture.modes.confirm(oldAnswer) == .stale)
    #expect(fixture.configurator.applies.count == before)
    #expect(fixture.modes.preview != nil)
    #expect(await fixture.modes.confirm(fresh) == .committed)
  }
}
