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

  /// `PanelView` cannot be rendered WITH display rows: rows come from
  /// `AppModel.displays`, which is `private(set)` and filled by discovery, and
  /// the app-code change this suite is allowed to make is the derivation seam
  /// (AT6), not an injection point on the model. What the rows are made of is
  /// nameable, though, so the row body renders here directly over a fixture
  /// display state: brightness, volume and contrast, the three slider rows a
  /// display section draws. The header row and the two disclosure sections are
  /// private to their files and stay uncovered.
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
}
