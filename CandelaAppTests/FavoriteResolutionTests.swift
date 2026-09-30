import CandelaKit
import Foundation
import Testing

@Suite("Favorite resolution controls") @MainActor
struct FavoriteResolutionControlTests {
  @Test func savingAndRemovingNeverStartsAPreview() throws {
    let defaults = InMemoryDefaults()
    let fixture = SynthesisFixture(modePersistence: ModePersistence(defaults: defaults))
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let mode = try #require(fixture.modes.catalogs[id]?.current)
    var writes: [String] = []
    fixture.modes.didWriteFavorites = { writes.append($0) }
    fixture.modes.toggleFavorite(mode, on: id)
    #expect(fixture.modes.isFavorite(mode, on: id))
    #expect(fixture.modes.favorites(for: id).count == 1)
    #expect(!fixture.modes.isApplying)
    #expect(fixture.modes.preview == nil)
    #expect(writes == [fixture.modes.catalogs[id]!.display.identity.key])
    fixture.modes.toggleFavorite(mode, on: id)
    #expect(fixture.modes.favorites(for: id).isEmpty)
    #expect(!fixture.modes.isApplying)
    #expect(writes.count == 2)
  }

  @Test func selectionUsesTheExistingPreviewAndRejectsRepeatClicks() async throws {
    let defaults = InMemoryDefaults()
    let fixture = SynthesisFixture(modePersistence: ModePersistence(defaults: defaults))
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let current = try #require(catalog.current)
    let wanted = try #require(catalog.all.first { $0.ioModeID == 2 })
    #expect(!fixture.modes.selectFavorite(FavoriteResolution(mode: current), on: id,
                                        from: .settings, surface: .settingsBanner))
    fixture.modes.toggleFavorite(wanted, on: id)
    let favorite = try #require(fixture.modes.favorites(for: id).first)
    #expect(fixture.modes.selectFavorite(favorite, on: id, from: .settings, surface: .settingsBanner))
    #expect(!fixture.modes.selectFavorite(favorite, on: id, from: .settings, surface: .settingsBanner))
    await fixture.settle()
    #expect(fixture.modes.preview?.mode == wanted)
    await fixture.revertAnyPreview()
    #expect(fixture.configurator.currentMode(for: id)?.ioModeID == current.ioModeID)
    #expect(fixture.modes.favorites(for: id) == [favorite])
  }

  @Test func unavailableFavoritesRemainRemovable() throws {
    let defaults = InMemoryDefaults()
    let store = ModePersistence(defaults: defaults)
    let fixture = SynthesisFixture(modePersistence: store)
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let absent = DisplayMode(ioModeID: 999, logicalWidth: 1920, logicalHeight: 1080,
                            pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60, isNative: false)
    let favorite = FavoriteResolution(mode: absent)
    store.setFavorites([favorite], for: catalog.display.identity)
    #expect(fixture.modes.resolvedFavorite(favorite, on: id) == nil)
    #expect(!fixture.modes.selectFavorite(favorite, on: id, from: .settings, surface: .settingsBanner))
    #expect(!fixture.modes.isApplying)
    fixture.modes.removeFavorite(favorite, on: id)
    #expect(fixture.modes.favorites(for: id).isEmpty)
  }

  @Test func renderedFavoritesUseSynthesisAndCannotBeAppliedTwice() async throws {
    let defaults = InMemoryDefaults()
    let fixture = SynthesisFixture(modePersistence: ModePersistence(defaults: defaults))
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let stop = try #require(fixture.modes.catalogs[id]?.syntheticStops.first)
    let mode = SyntheticSizeCatalog.row(for: stop)
    fixture.modes.toggleFavorite(mode, on: id)
    let favorite = try #require(fixture.modes.favorites(for: id).first)
    #expect(fixture.modes.selectFavorite(favorite, on: id, from: .settings, surface: .settingsBanner))
    await fixture.settle()
    #expect(fixture.modes.preview?.synthesized?.size == stop)
    if let preview = fixture.modes.preview { _ = await fixture.modes.confirm(preview) }
    #expect(!fixture.modes.selectFavorite(favorite, on: id, from: .settings, surface: .settingsBanner))
    #expect(fixture.modes.isFavorite(try #require(fixture.modes.catalogs[id]?.onScreen), on: id))
    _ = await fixture.synthesis.setOptIn(false, on: try fixture.configured(id))
    fixture.modes.refreshCatalog(for: id)
    #expect(fixture.modes.resolvedFavorite(favorite, on: id) == nil)
    #expect(fixture.modes.favorites(for: id) == [favorite])
    #expect(!fixture.modes.selectFavorite(favorite, on: id, from: .settings, surface: .settingsBanner))
    fixture.modes.removeFavorite(favorite, on: id)
    #expect(fixture.modes.favorites(for: id).isEmpty)
  }

  @Test func reconnectResolvesTheSameFavoriteWithNewDisplayAndModeIDs() throws {
    let defaults = InMemoryDefaults()
    let fixture = SynthesisFixture(optedIn: false, modePersistence: ModePersistence(defaults: defaults))
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let mode = try #require(catalog.current)
    fixture.modes.toggleFavorite(mode, on: id)
    let favorite = try #require(fixture.modes.favorites(for: id).first)
    let reconnected = ConfiguredDisplay(id: 42, identity: catalog.display.identity,
                                       name: catalog.display.name, isBuiltIn: false)
    let newMode = DisplayMode(ioModeID: 91, logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight,
                             pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                             refreshHz: mode.refreshHz, isNative: mode.isNative)
    fixture.world.detach(id)
    fixture.world.attach(reconnected, modes: [newMode], current: newMode,
                         nativePixels: (width: mode.pixelWidth, height: mode.pixelHeight))
    fixture.modes.refreshCatalog(for: 42)
    #expect(fixture.modes.favorites(for: 42) == [favorite])
    #expect(fixture.modes.resolvedFavorite(favorite, on: 42)?.ioModeID == 91)
    #expect(fixture.modes.isFavorite(newMode, on: 42))
    #expect(!fixture.modes.selectFavorite(favorite, on: 42, from: .settings, surface: .settingsBanner))
  }

  @Test func resolvedKeySetMatchesThePerFavoriteAnswers() throws {
    let defaults = InMemoryDefaults()
    let store = ModePersistence(defaults: defaults)
    let fixture = SynthesisFixture(modePersistence: store)
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let catalog = try #require(fixture.modes.catalogs[id])
    let current = try #require(catalog.current)
    let stop = try #require(catalog.syntheticStops.first)
    let rendered = SyntheticSizeCatalog.row(for: stop)
    let absent = DisplayMode(ioModeID: 999, logicalWidth: 1920, logicalHeight: 1080,
                            pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60, isNative: false)
    let saved = [current, rendered, absent].map { FavoriteResolution(mode: $0) }
    store.setFavorites(saved, for: catalog.display.identity)

    let keys = fixture.modes.resolvedFavoriteKeys(on: id)
    let perFavorite = Set(saved.compactMap { favorite in
      fixture.modes.resolvedFavorite(favorite, on: id).map { FavoriteResolution(mode: $0) }
    })
    #expect(keys == perFavorite)
    #expect(keys.count == 2)
    // Reference: the per-favourite scan, independent of the key set.
    for mode in catalog.all + [rendered, absent] {
      let scanned = saved.contains { favorite in
        fixture.modes.resolvedFavorite(favorite, on: id).map { FavoriteResolution(mode: $0) }
          == FavoriteResolution(mode: mode)
      }
      #expect(fixture.modes.isFavorite(mode, on: id) == scanned)
    }
  }
}
