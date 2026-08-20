import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

// Layer 2 of AT4: build a covered surface with faked data, run it through
// `ImageRenderer`, and assert only that pixels came out at a plausible size.
// Nothing here compares a pixel and nothing here commits a reference image.
//
// What this layer is for: a crash in `body` and a render that collapses to
// nothing. Both are invisible to the row-model tests next door, which never
// lay a view out, and both are the shapes a macOS update produces first
// (AT9: the render path is measured locally and the CI run is its own
// experiment).
//
// What it is NOT for: appearance. A surface can render at full size and look
// wrong, and only a human looking at the window catches that.
@Suite("Render smoke") @MainActor
struct RenderSmokeTests {
  /// Well under any surface here and well above a collapsed layout, so the
  /// assertion fails on "rendered nothing" without pinning a size that a font
  /// metric or an appearance change can move.
  private static let floor = 20

  /// Renders offscreen and returns the image, or nil when the renderer
  /// produced none. Scale stays at the default 1, so a dimension is a point
  /// count and the floor above means what it reads as.
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

  // MARK: - The panel

  /// The panel with nothing attached: the empty state, the footer, and the
  /// frame that sizes every other panel render. `AppModel` here is the
  /// hardware-free fixture (AT3), so no service, no poller and no wire exists
  /// while this runs.
  ///
  /// Size is the whole assertion, and on this surface it has to be. The panel
  /// draws no background of its own (the hosting `NSMenu` supplies one), so a
  /// correct render is mostly clear pixels with ink only where the text and
  /// the divider are: measured 2026-08-17 at 280x170 with about a tenth of the
  /// pixels carrying any alpha. Anything counting ink would be pinning that
  /// ratio, which is appearance, and appearance is a human's job.
  @Test func theEmptyPanelRenders() {
    let model = TestFixtures.appModel()
    expectPixels(render(PanelView().environment(model)), "empty PanelView")
  }

  /// The three slider rows a display section draws, over a fixture state and
  /// without a model. This used to be the only way to get rows on screen at
  /// all; the populated panel below now covers the real composition, and this
  /// stays because it isolates the rows from everything the panel wraps them
  /// in. The header row and the two disclosure sections are private to their
  /// files and stay uncovered.
  @Test func aDisplaysSliderRowsRender() {
    let state = TestFixtures.displayState(name: "Smoke Panel", persistenceKey: "smoke-panel")
    let rows = VStack(alignment: .leading, spacing: 8) {
      DisplaySliderRow(
        controller: state.controller, displayName: "Smoke Panel",
        snapsToStops: true, showsPercent: true)
      ValueSliderRow(
        controller: state.volume, systemImage: "speaker.wave.2.fill",
        accessibilityLabel: "Smoke Panel volume", snapsToStops: true, showsPercent: true,
        mutedSystemImage: "speaker.slash.fill")
      ValueSliderRow(
        controller: state.contrast, systemImage: "circle.lefthalf.filled",
        accessibilityLabel: "Smoke Panel contrast", snapsToStops: true, showsPercent: true)
    }
    .frame(width: 252)
    expectPixels(render(rows), "panel slider rows")
  }

  /// The panel WITH display rows, which the discovery seam finally makes
  /// reachable (this suite used to record it as impossible).
  ///
  /// The premise is asserted before the render, and that is the point: with no
  /// displays the panel still renders perfectly well as its empty state, so a
  /// refresh that quietly produced nothing would leave every pixel assertion
  /// below passing for the wrong reason. That is the vacuous pass this layer
  /// exists to avoid, arriving through the back door.
  ///
  /// The comparison against the empty panel is the real assertion. A size floor
  /// alone cannot tell "two displays drew their rows" from "the empty state
  /// drew its one line of text", because both clear the floor comfortably.
  @Test func thePopulatedPanelRendersItsDisplayRows() async {
    let discovery = ScriptedDiscovery([
      (id: 2, key: "smoke-panel-a", name: "Smoke Panel A"),
      (id: 3, key: "smoke-panel-b", name: "Smoke Panel B"),
    ])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    #expect(model.displays.count == 2, "the seam must have produced rows to render")

    let populated = render(PanelView().environment(model))
    expectPixels(populated, "populated PanelView")

    // The baseline is a model refreshed through the SAME seam with nothing
    // attached, never `TestFixtures.appModel()` unrefreshed. `refreshBuiltIn`
    // reads the machine, so a refreshed model on a laptop also gains a built-in
    // row: measured 2026-08-19, comparing refreshed against unrefreshed made
    // this assertion pass on the built-in's height alone, and it went on
    // passing with the external topology emptied. Refreshing both leaves the
    // two display rows as the only difference between them.
    let baseline = TestFixtures.appModel(discovery: ScriptedDiscovery([]))
    await baseline.refresh()
    let empty = render(PanelView().environment(baseline))
    guard let populated, let empty else { return } // already recorded above
    #expect(
      populated.height > empty.height,
      "two display rows must make the panel taller than the same panel without them")
  }

  // MARK: - The settings window

  /// Every static pane row plus the empty-display-list message, which is the
  /// sidebar the fixture model produces. The shared-identity ordinals the
  /// structural tests cover need display rows and so are not on screen here.
  @Test func theSettingsSidebarRenders() {
    let model = TestFixtures.appModel()
    let sidebar = SettingsSidebar(selection: .constant(.pane(SettingsRegistry.panes[0].id)))
      .environment(model)
      // A `ScrollView` proposes nothing of its own, so the render needs a
      // window-shaped frame to fill: roughly the sidebar column of the real
      // settings window.
      .frame(width: 215, height: 520)
    expectPixels(render(sidebar), "SettingsSidebar")
  }

  /// The page's header and its grouped form chrome. The mode list is NOT on
  /// screen: it renders from `DisplayModeCoordinator.catalogs`, which is
  /// `private(set)` on the coordinator the page reads out of the environment
  /// model, so the only honest routes to a populated list are a live display
  /// or an injection seam this suite may not add. A nil catalog is a real
  /// state the page has to survive anyway (it is what a push renders before
  /// enumeration lands), so this covers that state and the row derivation
  /// stays covered structurally instead.
  @Test func theAllModesPageRendersWithoutACatalog() {
    let model = TestFixtures.appModel()
    let state = TestFixtures.displayState(name: "Smoke Panel", persistenceKey: "smoke-panel")
    let page = AllModesPage(
      state: state,
      displays: [(key: "smoke-panel", name: "Smoke Panel")],
      onSwitch: { _ in }
    )
    .environment(model)
    .frame(width: 640, height: 520)
    expectPixels(render(page), "AllModesPage")
  }

  /// The built-in display's page, which grew a Display section of its own.
  ///
  /// The catalog is absent here, and on a hardware-free fixture `model.builtIn`
  /// is too, so what this covers is the state every visit to the page starts
  /// in: the rest of the pane on screen and the resolution section correctly
  /// not yet drawn. A populated catalog is unreachable from this bundle for
  /// `AllModesPage`'s reason (`catalogs` is `private(set)` and the only honest
  /// filler is a live display), so the section's own derivation is covered by
  /// the row-model suite instead.
  @Test func theBuiltInDisplayPaneRenders() {
    let model = TestFixtures.appModel()
    let pane = BuiltInDisplayPane(
      selection: .constant(.display("builtIn")), path: .constant([])
    )
    .environment(model)
    .environment(SettingsActions(model: model))
    .frame(width: 640, height: 520)
    expectPixels(render(pane), "BuiltInDisplayPane")
  }

  // MARK: - The guided setup flow

  /// The window the flow asks for is 760x560 at its minimum, so every render
  /// below gets a frame a little larger than that: `OnboardingFlowView` sizes
  /// itself from its host, and an unframed render of it has nothing to fill.
  private static let flowSize = (width: 820.0, height: 620.0)

  /// A flow model walked to `page`. Advancing is the only route the model
  /// offers (`index` is `private(set)`, and the page list derives from the
  /// environment plus the designation set), and in fixture mode advancing
  /// records commits into the model instead of writing anything, so the walk
  /// touches no prefs and no display.
  ///
  /// `designating` is passed where the page under test depends on the OLED
  /// designation, so the test does not ride on the fixture's product name
  /// still containing "OLED".
  private func flow(
    to page: OnboardingPage,
    environment: OnboardingEnvironment = OnboardingFixtures.rig,
    designating oleds: Set<String>? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) -> OnboardingFlowModel? {
    let model = OnboardingFlowModel(environment: environment)
    if let oleds { model.designatedOleds = oleds }
    while model.currentPage != page {
      guard !model.isLastPage else {
        Issue.record(
          "the flow never reached \(page.id); pages were \(model.pages.map(\.id))",
          sourceLocation: sourceLocation)
        return nil
      }
      model.advance()
    }
    return model
  }

  private func renderFlow(
    _ page: OnboardingPage,
    environment: OnboardingEnvironment = OnboardingFixtures.rig,
    designating oleds: Set<String>? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard
      let model = flow(
        to: page, environment: environment, designating: oleds,
        sourceLocation: sourceLocation)
    else { return }
    let view = OnboardingFlowView(model: model)
      .frame(width: Self.flowSize.width, height: Self.flowSize.height)
    expectPixels(render(view), "OnboardingFlowView at \(page.id)", sourceLocation: sourceLocation)
  }

  /// The opening page over the persistent canvas. The canvas drives its glow
  /// from a `TimelineView`, which renders its first frame like any other view,
  /// so this covers the canvas for every page below as well.
  @Test func theOnboardingWelcomePageRenders() {
    renderFlow(.welcome)
  }

  /// The detection page, which starts a scripted scan on appear. The render is
  /// whatever frame the scan is on when the renderer runs, and either end of
  /// that walk is a real state the page has to draw, so nothing here waits for
  /// or pins a phase.
  @Test func theOnboardingDetectionPageRenders() {
    renderFlow(.detection)
  }

  /// A size page. The fixture's rotated 4K display is the one carrying a
  /// suggestion, so it is the only size page the rig produces.
  @Test func theOnboardingSizePageRenders() {
    renderFlow(.size(displayKey: "fixture-dell"))
  }

  @Test func theOnboardingAccessibilityPageRenders() {
    renderFlow(.accessibility)
  }

  /// The OLED designation page, rendered with both fixture displays selectable
  /// and the ultrawide designated.
  @Test func theOnboardingDesignationPageRenders() {
    renderFlow(.oledSelect, designating: ["fixture-mag"])
  }

  /// The care page, which exists only while something is designated.
  @Test func theOnboardingCarePageRenders() {
    renderFlow(.oledCare, designating: ["fixture-mag"])
  }

  @Test func theOnboardingFinishPageRenders() {
    renderFlow(.finish, designating: ["fixture-mag"])
  }

  /// The slim flow's pivot page. Nothing is attached, so the plan drops
  /// detection, every size page and the OLED pages, and this is what the
  /// second page of that flow draws.
  @Test func theOnboardingNoDisplaysPageRenders() {
    let empty = OnboardingEnvironment(
      accessibilityGranted: false, loginItemEnabled: false, isFirstRun: true, displays: [])
    renderFlow(.noDisplays, environment: empty)
  }
}
