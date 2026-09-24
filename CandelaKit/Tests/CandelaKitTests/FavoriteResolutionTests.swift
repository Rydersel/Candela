import Foundation
import Testing
@testable import CandelaKit

@Suite("Favorite resolutions")
struct FavoriteResolutionTests {
  private let display = DisplayConfigIdentity(vendor: 1, model: 2, serial: 3, isBuiltIn: false)
  private let other = DisplayConfigIdentity(vendor: 1, model: 2, serial: 4, isBuiltIn: false)

  private func mode(_ id: Int32 = 1, hz: Double = 60,
                    pixels: (Int, Int) = (5120, 2880),
                    provenance: ModeProvenance = .coreGraphics) -> DisplayMode {
    DisplayMode(ioModeID: id, logicalWidth: 2560, logicalHeight: 1440,
                pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
                isNative: false, provenance: provenance)
  }

  @Test func favoritesPersistInOrderWithoutEnablingRestore() {
    let defaults = InMemoryDefaults()
    let store = ModePersistence(defaults: defaults)
    let first = FavoriteResolution(mode: mode(hz: 120))
    let second = FavoriteResolution(mode: mode(hz: 60))
    #expect(store.favorites(for: display).isEmpty)
    store.setFavorites([first, second, first], for: display)
    #expect(ModePersistence(defaults: defaults).favorites(for: display) == [first, second])
    #expect(store.favorites(for: other).isEmpty)
    #expect(!store.isEnabled(for: display))
    #expect(store.storedMode(for: display) == nil)
    #expect(defaults.data(forKey: "favoriteDisplayModes.1-2-3") != nil)
  }

  @Test func clearingFavoritesLeavesOtherDisplayAndRememberedModeAlone() {
    let store = ModePersistence(defaults: InMemoryDefaults())
    let favorite = FavoriteResolution(mode: mode())
    store.setFavorites([favorite], for: display)
    store.setFavorites([favorite], for: other)
    store.store(mode().descriptor, for: display)
    store.setEnabled(true, for: display)
    store.setFavorites([], for: display)
    #expect(store.favorites(for: display).isEmpty)
    #expect(store.favorites(for: other) == [favorite])
    #expect(store.storedMode(for: display) == mode().descriptor)
    #expect(store.isEnabled(for: display))
  }

  @Test func ignoresRuntimeIDsAndEnumerationProvenance() throws {
    let saved = FavoriteResolution(mode: mode(1, hz: 59.9998))
    let available = mode(83, hz: 60, provenance: .coreGraphicsServices)
    #expect(saved.resolve(in: [available]) == available)
    #expect(saved == FavoriteResolution(mode: available))
    let encoded = try JSONEncoder().encode(saved)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("ioModeID"))
    #expect(try JSONDecoder().decode(FavoriteResolution.self, from: encoded) == saved)
  }

  @Test func neverSubstitutesRateOrFramebuffer() {
    let saved = FavoriteResolution(mode: mode(hz: 60))
    #expect(saved.resolve(in: [mode(hz: 59.94)]) == nil)
    #expect(saved.resolve(in: [mode(hz: 120)]) == nil)
    #expect(saved.resolve(in: [mode(pixels: (2560, 1440))]) == nil)
    #expect(saved.resolve(in: []) == nil)
  }

  @Test func resolvesAfterQuarterTurnButDoesNotPreferTransposeOverPresentGeometry() {
    let saved = FavoriteResolution(mode: mode())
    let rotated = DisplayMode(ioModeID: 9, logicalWidth: 1440, logicalHeight: 2560,
                              pixelWidth: 2880, pixelHeight: 5120, refreshHz: 60, isNative: false)
    #expect(saved.resolve(in: [rotated]) == rotated)
    #expect(saved.resolve(in: [mode(hz: 120), rotated]) == nil)
    #expect(saved.resolve(in: [mode(pixels: (2560, 1440)), rotated]) == nil)
  }

  @Test func duplicateModesResolveDeterministically() {
    let saved = FavoriteResolution(mode: mode())
    #expect(saved.resolve(in: [mode(8), mode(4)])?.ioModeID == 4)
    #expect(saved.resolve(in: [mode(4), mode(8)])?.ioModeID == 4)
  }

  @Test func renderedSizesKeepTheirOwnRouteAndDoNotPinARefreshRate() {
    let rendered = mode(-1001, hz: 0, provenance: .synthesized)
    let saved = FavoriteResolution(mode: rendered)
    #expect(saved != FavoriteResolution(mode: mode(hz: 0)))
    #expect(saved.resolve(in: [mode()]) == nil)
    #expect(saved.resolve(in: [rendered]) == rendered)
    #expect(saved == FavoriteResolution(mode: mode(-1002, hz: 120, provenance: .synthesized)))
  }

  @Test func invalidStoredEntriesAreNotOffered() {
    let defaults = InMemoryDefaults()
    let key = "favoriteDisplayModes.1-2-3"
    defaults.set(Data("broken".utf8), forKey: key)
    let store = ModePersistence(defaults: defaults)
    #expect(store.favorites(for: display).isEmpty)
    let invalid = FavoriteResolution(mode: mode(hz: -.infinity))
    let valid = FavoriteResolution(mode: mode())
    store.setFavorites([invalid, valid], for: display)
    #expect(store.favorites(for: display) == [valid])
  }

  @Test func favoritingOnlyChangesPresentation() {
    #expect(PrefPropagation.effects(forChange: .favoriteDisplayModes) == [.refreshUI, .rebuildPanel])
  }
}
