import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

// Layer 2: build a covered surface with faked data, run it through
// `ImageRenderer`, and assert only that pixels came out at a plausible size.
// Nothing here compares a pixel and nothing here commits a reference image.
//
// What this layer is for: a crash in `body` and a render that collapses to
// nothing. Both are invisible to the row-model tests next door, which never
// lay a view out, and both are the shapes a macOS update produces first
// (the render path is measured locally and the CI run is its own
// experiment).
//
// What it is NOT for: appearance. A surface can render at full size and look
// wrong, and only a human looking at the window catches that.
@Suite("Render smoke") @MainActor
struct RenderSmokeTests {
  /// Well under any surface here and well above a collapsed layout, so nothing
  /// pins a size a font metric or an appearance change can move.
  private static let floor = 20

  /// Scale stays at the default 1, so a dimension is a point count and the
  /// floor above means what it reads as.
  private func render(_ view: some View) -> CGImage? {
    ImageRenderer(content: view).cgImage
  }

  /// The rendered bytes, for the one comparison in this suite that is between
  /// two renders rather than against a floor. Never used to assert a COLOR,
  /// which is a human's job: only whether two renders of the same view differ.
  private func pixels(_ image: CGImage?) -> Data? {
    guard let data = image?.dataProvider?.data else { return nil }
    return data as Data
  }

  /// Largest per-channel difference between two same-size renders; nil when
  /// either is missing or the sizes differ. The scheme comparisons use this
  /// instead of byte equality because `ImageRenderer` is not bitwise
  /// deterministic [MEASURED 2026-08-27]: one unchanged view re-renders a unit
  /// or two off per channel, in a single glyph pixel once the process is warm or
  /// across the whole wallpaper gradient in light appearance, and byte equality
  /// read both as a scheme leak. A real scheme flip moves tens of units, which
  /// the positive control pins.
  private func maxChannelDelta(_ lhs: CGImage?, _ rhs: CGImage?) -> Int? {
    guard let a = pixels(lhs), let b = pixels(rhs), a.count == b.count, !a.isEmpty else { return nil }
    return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
  }

  /// What rasterization noise stays under, and what any real scheme flip clears.
  private static let noiseTolerance = 4
  private static let schemeFlipFloor = 64

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
  /// hardware-free fixture, so no service, no poller and no wire exists
  /// while this runs.
  ///
  /// Size is the whole assertion, and on this surface it has to be. The panel
  /// draws no background of its own (the hosting `NSMenu` supplies one), so a
  /// correct render is mostly clear pixels: measured 2026-08-17 at 280x170 with
  /// about a tenth of the pixels carrying any alpha. Counting ink would pin that
  /// ratio, which is appearance, and appearance is a human's job.
  @Test func theEmptyPanelRenders() {
    let model = TestFixtures.appModel()
    expectPixels(render(PanelView().environment(model)), "empty PanelView")
  }

  /// The three slider rows a display section draws, over a fixture state and
  /// without a model, which isolates them from everything the panel wraps them
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

  /// The panel WITH display rows, which the discovery seam makes reachable.
  ///
  /// The premise is asserted before the render, and that is the point: with no
  /// displays the panel still renders fine as its empty state, so a refresh that
  /// quietly produced nothing would leave every pixel assertion below passing
  /// for the wrong reason.
  ///
  /// The comparison against the empty panel is the real assertion. A size floor
  /// alone cannot tell "two displays drew their rows" from "the empty state drew
  /// its one line of text"; both clear the floor comfortably.
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
    // row: measured 2026-08-19, comparing refreshed against unrefreshed passed
    // on the built-in's height alone and went on passing with the external
    // topology emptied. Refreshing both leaves the two rows as the difference.
    let baseline = TestFixtures.appModel(discovery: ScriptedDiscovery([]))
    await baseline.refresh()
    let empty = render(PanelView().environment(baseline))
    guard let populated, let empty else { return } // already recorded above
    #expect(
      populated.height > empty.height,
      "two display rows must make the panel taller than the same panel without them")
  }

  // MARK: - The settings window

  /// The wordmark, every static pane row and the empty-display-list message,
  /// which is the sidebar the fixture model produces. The shared-identity
  /// ordinals the structural tests cover need display rows and so are not on
  /// screen here.
  ///
  /// No accent is injected, deliberately: `settingsAccent` defaults to
  /// neutral, so this also covers the sidebar drawn outside the shell that
  /// normally publishes one.
  @Test func theSettingsSidebarRenders() {
    let model = TestFixtures.appModel()
    let sidebar = SettingsSidebar(selection: .constant(.pane(SettingsRegistry.panes[0].id)))
      .environment(model)
      // A `ScrollView` proposes nothing of its own, so the render needs a
      // frame to fill: the sidebar column's real fixed width, and a height
      // that clears the wordmark above every pane row.
      .frame(width: 224, height: 560)
    expectPixels(render(sidebar), "SettingsSidebar")
  }

  /// The whole shell: the canvas, the sidebar, the hairline, and the detail
  /// column's `NavigationStack` on its opening destination. Nothing else
  /// reaches the composition itself, which is where the hand-built shell can
  /// fail: the canvas is a `TimelineView` and the detail column resolves its
  /// content through `presentation`, so a shell that resolved to nothing would
  /// render an empty window rather than crash.
  @Test func theSettingsShellRenders() {
    let model = TestFixtures.appModel()
    let shell = SettingsRootView()
      .environment(model)
      .environment(SettingsActions(model: model))
      .frame(width: SettingsWindowMetrics.idealWidth, height: SettingsWindowMetrics.idealHeight)
    expectPixels(render(shell), "SettingsRootView")
  }

  /// The page's header and the scaffold's card chrome. The mode list is NOT on
  /// screen: it renders from `DisplayModeCoordinator.catalogs`, which is
  /// `private(set)`, so the only honest routes to a populated list are a live
  /// display or an injection seam this suite may not add. A nil catalog is a
  /// real state anyway, the one a push renders before enumeration lands.
  ///
  /// The frame is the page's own extent: the scaffold lays a
  /// `SettingsTheme.pageWidth` column out inside 32 pt of horizontal padding, so
  /// anything narrower renders the cards compressed. The accent is injected
  /// because the list's selection ring and its checkmark both read from it.
  @Test func theAllModesPageRendersWithoutACatalog() {
    let model = TestFixtures.appModel()
    let state = TestFixtures.displayState(name: "Smoke Panel", persistenceKey: "smoke-panel")
    let page = AllModesPage(
      state: state,
      displays: [(key: "smoke-panel", name: "Smoke Panel")],
      onSwitch: { _ in }
    )
    .environment(model)
    .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
    .frame(width: SettingsTheme.pageWidth + 64, height: 520)
    expectPixels(render(page), "AllModesPage")
  }

  /// The opening both display pages share: the lit glyph, the identity block
  /// and the levels card. It gets its own render because neither page can put it
  /// on screen from this bundle (the built-in slot is empty on a hardware-free
  /// model, and the external hub needs a connected display).
  ///
  /// Width only: the hero sizes its own height, and pinning one would assert a
  /// layout rather than the fact that it produced pixels.
  ///
  /// Both variants, because they are different drawings and not a parameter of
  /// one: the built-in draws `LaptopGlyph` and drops the volume row, so a break
  /// in the laptop path is invisible to the external render.
  @Test(arguments: [DisplayHeroView.Variant.external, .builtIn])
  func theDisplayHeroRenders(variant: DisplayHeroView.Variant) {
    let model = TestFixtures.appModel()
    let state = TestFixtures.displayState(name: "Smoke Panel", persistenceKey: "smoke-panel")
    let isBuiltIn = variant == .builtIn
    let hero = DisplayHeroView(state: state, variant: variant)
      .environment(model)
      .environment(\.settingsAccent, .display(isBuiltIn: isBuiltIn, ordinal: 0))
      .frame(width: SettingsTheme.pageWidth)
    expectPixels(render(hero), "DisplayHeroView, \(isBuiltIn ? "built-in" : "external")")
  }

  /// The built-in display's page.
  ///
  /// The catalog is absent here, and on a hardware-free fixture `model.builtIn`
  /// is too, so this covers the state every visit to the page starts in: the
  /// rest of the pane on screen and the resolution section correctly not yet
  /// drawn. A populated catalog is unreachable from this bundle for
  /// `AllModesPage`'s reason, so the section's own derivation is covered by the
  /// row-model suite instead.
  ///
  /// The frame is the page's own extent, not a round number: the scaffold lays a
  /// `SettingsTheme.pageWidth` column out inside 32 pt of horizontal padding, so
  /// anything narrower renders a layout the window never shows.
  @Test func theBuiltInDisplayPaneRenders() {
    let model = TestFixtures.appModel()
    let pane = BuiltInDisplayPane(
      selection: .constant(.display("builtIn")), path: .constant([])
    )
    .environment(model)
    .environment(SettingsActions(model: model))
    .environment(\.settingsAccent, .display(isBuiltIn: true, ordinal: 0))
    .frame(width: SettingsTheme.pageWidth + 64, height: 560)
    expectPixels(render(pane), "BuiltInDisplayPane")
  }

  /// The theme layer composed the way a page composes it: the scaffold's scroll
  /// and content column, a card section, and the two shared rows inside it.
  /// Nothing here is a real pane, which is the point: a collapsed card or a
  /// crashing row surfaces here rather than in whichever page adopted it.
  @Test func theThemeComponentsRender() {
    let page = SettingsPageScaffold {
      SettingsPageHeader(title: "Levels", subtitle: "The shared components on one card.")
      SettingsCardSection(title: "Levels") {
        SettingRow("What this switch changes.") {
          Toggle("A themed switch", isOn: .constant(true)).themedSwitch()
        }
        SettingsCardDivider()
        NavigationRow(title: "All Sizes", value: "3440 x 1440", action: {})
      }
    }
    .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 1))
    .frame(width: 640, height: 420)
    expectPixels(render(page), "settings theme components")
  }

  // MARK: - The menu-bar preview

  /// The Menu Bar pane's preview, and the design's faithfulness contract with
  /// it: the depicted widgets follow the SYSTEM appearance, so the settings
  /// window's own pinned-dark scheme must not reach them.
  ///
  /// The regression this catches shipped once. The grounds tracked the system
  /// through the appearance observer, but the labels resolved `.primary` and
  /// `.secondary` against the WINDOW, so a light-mode system got white text on
  /// the light panel and pills the preview had drawn correctly.
  ///
  /// Not a color assertion: nothing here says which scheme the widgets drew in,
  /// only that the window's did not decide it. Whether the depiction MATCHES the
  /// real widgets stays a human's look at the window.
  @Test func theMenuBarPreviewIgnoresTheWindowsColorScheme() {
    let model = TestFixtures.appModel()
    func shot(_ scheme: ColorScheme) -> CGImage? {
      render(
        MenuBarPreviewView { _ in }
          .environment(model)
          .environment(\.colorScheme, scheme)
          .frame(width: SettingsTheme.pageWidth))
    }
    let inDarkWindow = shot(.dark)
    let inLightWindow = shot(.light)
    expectPixels(inDarkWindow, "MenuBarPreviewView in a dark window")
    expectPixels(inLightWindow, "MenuBarPreviewView in a light window")
    let delta = maxChannelDelta(inDarkWindow, inLightWindow)
    #expect(
      delta.map { $0 <= Self.noiseTolerance } == true,
      "the window's scheme must not reach the depicted widgets; max channel delta \(String(describing: delta))")
  }

  /// The positive control the case above is worth nothing without: two renders
  /// of a view that DOES follow the ambient scheme must differ by far more than
  /// the noise tolerance. Without it, a renderer that ignores the scheme
  /// override or a tolerance wide enough to swallow a flip both read as a pass.
  @Test func theSchemeComparisonCanSeeAScheme() {
    func shot(_ scheme: ColorScheme) -> CGImage? {
      render(
        Text("Aa")
          .font(.system(size: 40))
          .foregroundStyle(.primary)
          .padding(20)
          .background(Color.gray)
          .environment(\.colorScheme, scheme))
    }
    let dark = shot(.dark)
    let light = shot(.light)
    expectPixels(dark, "scheme control, dark")
    expectPixels(light, "scheme control, light")
    let delta = maxChannelDelta(dark, light)
    #expect(
      delta.map { $0 >= Self.schemeFlipFloor } == true,
      "an ambient scheme flip must be visible to this comparison; max channel delta \(String(describing: delta))")
  }

  // MARK: - The guided setup flow

  /// The window the flow asks for is 760x560 at its minimum, so every render
  /// below gets a frame a little larger than that: `OnboardingFlowView` sizes
  /// itself from its host, and an unframed render of it has nothing to fill.
  private static let flowSize = (width: 820.0, height: 620.0)

  /// A flow model walked to `page`. Advancing is the only route the model offers
  /// (`index` is `private(set)`), and in fixture mode it records commits into the
  /// model instead of writing, so the walk touches no prefs and no display.
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
