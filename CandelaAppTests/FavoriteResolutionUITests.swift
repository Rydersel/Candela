import AppKit
import CandelaKit
import SwiftUI
import Testing

@Suite("Favorite resolution presentation") @MainActor
struct FavoriteResolutionUITests {
  @Test func labelsDistinguishRatesRenderingAndUnavailableChoices() throws {
    let fixture = SynthesisFixture()
    defer { fixture.forgetPrefs() }
    let catalog = try #require(fixture.modes.catalogs[SynthesisFixture.panelID])
    let current = try #require(catalog.current)
    let saved = FavoriteResolution(mode: current)
    let available = FavoriteResolutionLabel(saved, mode: current, catalog: catalog)
    #expect(available.title == "3440 × 1440")
    #expect(available.detail == "175 Hz · Native")
    let absent = FavoriteResolutionLabel(saved, mode: nil, catalog: catalog)
    #expect(absent.detail.contains("Unavailable"))
    #expect(absent.detail.contains("175 Hz"))
    let stop = try #require(catalog.syntheticStops.first)
    let rendered = SyntheticSizeCatalog.row(for: stop)
    let label = FavoriteResolutionLabel(FavoriteResolution(mode: rendered), mode: rendered, catalog: catalog)
    #expect(label.detail.contains(SynthesisCopy.badge))
    #expect(label.detail.contains("Keeps refresh rate"))
    #expect(!label.detail.contains("0 Hz"))
  }

  @Test func settingsStarsAreSeparateAccessibleActionsThatDoNotApplyAMode() throws {
    let suite = "favorite-ui-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = SynthesisFixture(modePersistence: ModePersistence(defaults: defaults))
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let current = try #require(catalog.current)
    let view = ModeFavoriteButton(mode: current, catalog: catalog, coordinator: fixture.modes)
    let buttons = buttons(in: view)
    let star = try #require(buttons.first { ($0.accessibilityLabel?() ?? nil)?.hasPrefix("Add ") == true })
    #expect(star.accessibilityIdentifier?() == "favoriteDisplayModes.3669-1-1")
    #expect(star.accessibilityPerformPress?() == true)
    #expect(fixture.modes.favorites(for: id).count == 1)
    #expect(!fixture.modes.isApplying)
    #expect(fixture.modes.preview == nil)
  }

  @Test(arguments: [false, true])
  func panelOffersFavoritesOnceWithoutManagementButtons(hasSharperTwin: Bool) throws {
    let suite = "favorite-ui-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = SynthesisFixture(optedIn: false, modePersistence: ModePersistence(defaults: defaults))
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let current = try #require(hasSharperTwin ? catalog.all.first { $0.ioModeID == 2 } : catalog.current)
    if hasSharperTwin {
      let sharper = DisplayMode(ioModeID: 90, logicalWidth: current.logicalWidth,
        logicalHeight: current.logicalHeight, pixelWidth: current.pixelWidth * 2,
        pixelHeight: current.pixelHeight * 2, refreshHz: current.refreshHz, isNative: false)
      fixture.world.attach(catalog.display, modes: catalog.all + [sharper], current: current,
        nativePixels: (width: SynthesisFixture.nativeWidth, height: SynthesisFixture.nativeHeight))
      fixture.modes.refreshCatalog(for: id)
    }
    fixture.modes.toggleFavorite(current, on: id)
    let view = PanelResolutionSection(displayID: id, displayName: "Test display", coordinator: fixture.modes,
                                     expanded: .constant(PanelDisclosureID(id, .resolution)))
    let elements = buttons(in: view.frame(width: 260))
    let labels = elements.compactMap { $0.accessibilityLabel?() ?? nil }
    let size = DisplayModeCopy.size(current)
    #expect(labels.filter { $0.contains("Test display, \(size)") }.count == (hasSharperTwin ? 2 : 1))
    #expect(!labels.contains { $0.hasPrefix("Add ") || $0.hasPrefix("Remove ") })
    #expect(elements.filter { $0.isAccessibilitySelected?() == true }.count == 1)
  }

  @Test func unavailableFavoriteDisablesSelectionButKeepsRemoveAccessible() throws {
    let suite = "favorite-ui-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ModePersistence(defaults: defaults)
    let fixture = SynthesisFixture(modePersistence: store)
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let missing = DisplayMode(ioModeID: 99, logicalWidth: 1920, logicalHeight: 1080,
                             pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60, isNative: false)
    store.setFavorites([FavoriteResolution(mode: missing)], for: catalog.display.identity)
    let elements = buttons(in: FavoriteResolutionRows(catalog: catalog, coordinator: fixture.modes).frame(width: 560))
    let select = try #require(elements.first { ($0.accessibilityLabel?() ?? nil)?.hasPrefix("Remove ") == false })
    let remove = try #require(elements.first { ($0.accessibilityLabel?() ?? nil)?.hasPrefix("Remove ") == true })
    #expect(select.isAccessibilityEnabled?() == false)
    #expect(remove.isAccessibilityEnabled?() == true)
    #expect(remove.accessibilityPerformPress?() == true)
    #expect(fixture.modes.favorites(for: id).isEmpty)
    #expect(!fixture.modes.isApplying)
  }

  private func buttons(in view: some View) -> [AnyObject] {
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(true,
      forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = NSHostingView(rootView: view)
    host.setFrameSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    var result: [AnyObject] = []
    func collect(_ element: Any, depth: Int) {
      guard depth < 24 else { return }
      let object = element as AnyObject
      if (object.accessibilityRole?() ?? nil) == .button { result.append(object) }
      for child in (object.accessibilityChildren?() ?? nil) ?? [] { collect(child, depth: depth + 1) }
    }
    collect(host, depth: 0)
    return result
  }
}
