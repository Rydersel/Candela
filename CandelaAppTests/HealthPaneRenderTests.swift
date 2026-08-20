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

  /// The pane-level Safe Mode note, which is the one thing on this pane telling
  /// a safe-mode reader that the figures are stored history and the hours
  /// switch is not counting. Compared against the same pane out of Safe Mode,
  /// content-sized, so the assertion fails if the note stops rendering rather
  /// than merely if the pane crashes.
  @Test func theHealthPaneLeadsWithTheSafeModeNote() {
    func pane(safeMode: Bool) -> some View {
      let model = TestFixtures.appModel(safeMode: safeMode)
      return HealthPane()
        .environment(model)
        .environment(SettingsActions(model: model))
        .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .health).accent)
        .frame(width: SettingsTheme.pageWidth + 64)
    }
    let safe = render(pane(safeMode: true))
    let normal = render(pane(safeMode: false))
    expectPixels(safe, "HealthPane in Safe Mode")
    guard let safe, let normal else { return }
    #expect(safe.height > normal.height, "the Safe Mode note must lead the pane")
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
    // A DELTA floor, not a bare `populated > empty`: two summary cards alone
    // clear the bare comparison, so it passes even when `scoped` resolves to
    // nil and the whole moved control stack, the collected section and the
    // comparison section render nothing. That branch is the one thing the
    // scope resolution can get wrong, and it is the one thing the bare
    // assertion cannot see.
    //
    // Chosen over rendering one display against two, which the review also
    // offered: that pair differs by a card and a switcher whether or not the
    // stack renders, so it does not reach this branch either.
    //
    // The margin is four captioned rows deep (three `SettingRow`s with
    // multi-line captions, the grid mark, and the hours toggle) plus the
    // section title and the scope caption. Measured 2026-08-20: 720 pt against
    // the empty state's 189, so the real difference is 531. 400 leaves room for
    // a font-metric shift while staying far above what two summary cards can
    // reach on their own.
    #expect(
      populated.height > empty.height + 400,
      "the two cards AND the measurement control stack must be on the pane, not the cards alone")
  }

  /// The enrolled OLED Care display page: the two exposure cards, the Dimming
  /// section and the rebuilt More section, which is the composition the care
  /// restructure actually rearranged. All of it is behind `oledCareEnrolled`,
  /// so the un-enrolled render above reaches none of it.
  ///
  /// Enrollment is written into the process defaults under a key unique to this
  /// run and taken back out in a `defer`: the page builds its own
  /// `DisplayPrefs(persistenceKey:)`, which reads `UserDefaults.standard`, so
  /// there is no suite to inject and a fixed key would leak into another run.
  ///
  /// Height-compared against the un-enrolled page rather than rendered into a
  /// fixed frame, because a fixed frame returns the frame's height whatever the
  /// branch did: the comparison is what proves the enrolled composition is the
  /// one that drew.
  @Test func theEnrolledOledCareDisplayPageRenders() {
    let key = "care-smoke-enrolled-\(UUID().uuidString)"
    DisplayPrefs(persistenceKey: key).oledCareEnrolled = true
    defer { UserDefaults.standard.removeObject(forKey: "oledCareEnrolled.\(key)") }

    let enrolled = render(carePage(key: key, name: "Care Smoke Enrolled"))
    let unenrolled = render(
      carePage(key: "care-smoke-unenrolled-\(UUID().uuidString)", name: "Care Smoke Plain"))

    expectPixels(enrolled, "enrolled OledCareDisplayPage")
    guard let enrolled, let unenrolled else { return }
    #expect(
      enrolled.height > unenrolled.height,
      "the exposure cards, the Dimming section and More must be on the enrolled page")
  }

  /// One display's OLED Care page over a fixture display, sized by its content.
  private func carePage(key: String, name: String) -> some View {
    let model = TestFixtures.appModel()
    let state = TestFixtures.displayState(name: name, persistenceKey: key)
    return OledCareDisplayPage(
      state: state,
      displays: [(key: key, name: name)],
      onSwitch: { _ in }
    )
    .environment(model)
    .environment(SettingsActions(model: model))
    .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
    .frame(width: SettingsTheme.pageWidth + 64)
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
