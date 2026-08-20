import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

/// Layer 2 of AT4 for the two surfaces SC4 and SC5 rearranged: build them with
/// faked data, run them through `ImageRenderer`, and assert only that pixels
/// came out at a plausible size.
///
/// What this covers: a crash in `body` and a render that collapses to nothing.
/// The Health pane is a new composition of several nested views, and the OLED
/// Care display page grew two cards and lost a hero stat, so both are exactly
/// the shape a `body` mistake hides in until someone opens the window.
///
/// What it is NOT for: appearance. A surface can render at full size and look
/// wrong, and only a human looking at the window catches that.
///
/// A file of its own rather than rows in `RenderSmokeTests`, so a concurrent
/// task adding its own surface there cannot collide with this one; the two
/// helpers below are that file's, deliberately kept identical.
@Suite("Health render smoke") @MainActor
struct HealthPaneRenderTests {
  /// Well under any surface here and well above a collapsed layout, so the
  /// assertion fails on "rendered nothing" without pinning a size that a font
  /// metric or an appearance change can move.
  private static let floor = 20

  private func render(_ view: some View) -> CGImage? {
    ImageRenderer(content: view).cgImage
  }

  private func expectPixels(
    _ image: CGImage?, _ label: Comment, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard let image else {
      Issue.record("\(label) produced no image", sourceLocation: sourceLocation)
      return
    }
    #expect(image.width > Self.floor, label, sourceLocation: sourceLocation)
    #expect(image.height > Self.floor, label, sourceLocation: sourceLocation)
  }

  /// The pane with no external attached: the header, the Displays kicker and
  /// the empty-state card. The measurement section is deliberately absent in
  /// this state, because there is no display for its per-display writes to
  /// name, and a section of controls acting on nothing is the failure the
  /// scope resolution exists to prevent.
  @Test func theHealthPaneRendersWithNoDisplays() {
    let model = TestFixtures.appModel()
    let pane = HealthPane()
      .environment(model)
      .environment(SettingsActions(model: model))
      .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .health).accent)
      .frame(width: SettingsTheme.pageWidth + 64, height: 560)
    expectPixels(render(pane), "HealthPane with no displays")
  }

  /// The pane with two externals: two summary cards, the switcher (which only
  /// exists past one display), and the whole moved control stack under it.
  /// Taller than the empty state is the real assertion; a size floor alone
  /// cannot tell "two cards and the controls drew" from "the empty card did".
  @Test func theHealthPaneRendersItsCardsAndControls() async {
    let discovery = ScriptedDiscovery([
      (id: 2, key: "health-smoke-a", name: "Health Smoke A"),
      (id: 3, key: "health-smoke-b", name: "Health Smoke B"),
    ])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    #expect(model.displays.count == 2, "the seam must have produced displays to render")

    let populated = render(
      HealthPane()
        .environment(model)
        .environment(SettingsActions(model: model))
        .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .health).accent)
        .frame(width: SettingsTheme.pageWidth + 64))

    // Refreshed through the SAME seam with nothing attached, never an
    // unrefreshed fixture: `refreshBuiltIn` reads the machine, so only a
    // matched pair leaves the two cards as the difference between them.
    let baseline = TestFixtures.appModel(discovery: ScriptedDiscovery([]))
    await baseline.refresh()
    let empty = render(
      HealthPane()
        .environment(baseline)
        .environment(SettingsActions(model: baseline))
        .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .health).accent)
        .frame(width: SettingsTheme.pageWidth + 64))

    expectPixels(populated, "HealthPane with two displays")
    guard let populated, let empty else { return }
    #expect(
      populated.height > empty.height,
      "two cards and the measurement controls must make the pane taller than the empty state")
  }

  /// An un-enrolled display's OLED Care page: the enrollment toggle, the blank
  /// hero and the pitch. The exposure cards and the dimming controls are all
  /// behind enrollment, so this covers the branch a fixture display always
  /// lands in and proves the page still composes after the Measurement row
  /// became a reveal.
  @Test func theOledCareDisplayPageRenders() {
    let model = TestFixtures.appModel()
    let state = TestFixtures.displayState(
      name: "Care Smoke", persistenceKey: "care-smoke-page")
    let page = OledCareDisplayPage(
      state: state,
      displays: [(key: "care-smoke-page", name: "Care Smoke")],
      onSwitch: { _ in }
    )
    .environment(model)
    .environment(SettingsActions(model: model))
    .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
    .frame(width: SettingsTheme.pageWidth + 64, height: 560)
    expectPixels(render(page), "OledCareDisplayPage")
  }

  /// The two moved cards over a summary with nothing measured: the hottest
  /// area draws nothing at all (its gate), and display time draws its empty
  /// case. Rendered together, because the pair is what the display page places
  /// and a card that collapsed the stack would only show up in composition.
  @Test func theExposureCardsRenderWithNothingMeasured() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty,
      telemetryEnabled: false, observationEnabled: false)
    let cards = SettingsPageScaffold {
      PanelHottestAreaCard(summary: summary)
      PanelDisplayTimeCard(summary: summary)
    }
    .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
    .frame(width: SettingsTheme.pageWidth + 64, height: 320)
    expectPixels(render(cards), "exposure cards with nothing measured")
  }
}
