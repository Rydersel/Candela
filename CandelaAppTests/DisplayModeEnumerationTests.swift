import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// What one catalog refresh and one arrival cost in enumerations, and that the
/// values they produce are unchanged by the counting.
///
/// Enumeration is the expensive call on real hardware: `CGDisplayCopyAllDisplayModes`
/// plus the CGS revelation pass, per display. Measured 2026-09-09, one Dell mode
/// apply and its revert produced 16 catalog refreshes and 64 full enumerations.
@MainActor
@Suite("Display mode enumeration cost")
struct DisplayModeEnumerationTests {
  private static let panelID: CGDirectDisplayID = 12
  private static let native = DisplayMode(
    ioModeID: 1, logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true
  )
  private static let smaller = DisplayMode(
    ioModeID: 2, logicalWidth: 2560, logicalHeight: 1080,
    pixelWidth: 2560, pixelHeight: 1080, refreshHz: 175, isNative: false
  )

  /// A coordinator with no `SynthesisCoordinator` and its own defaults suite, so
  /// the stored-mode half of a reapply can be counted alone. Not the shape the
  /// app runs: `AppModel` attaches synthesis to every coordinator, and that
  /// shape is counted over `SynthesisFixture` below.
  private struct Rig {
    let world: FakeDisplayWorld
    let configurator: FakeSynthesisDisplayConfigurator
    let modes: DisplayModeCoordinator
    let persistence: ModePersistence
    let identity: DisplayConfigIdentity
    let suiteName: String

    func forgetPrefs() {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
  }

  private static func rig() -> Rig {
    let world = FakeDisplayWorld()
    let identity = DisplayConfigIdentity(vendor: 0x3669, model: 9, serial: 9, isBuiltIn: false)
    world.attach(
      ConfiguredDisplay(id: panelID, identity: identity, name: "MAG341C", isBuiltIn: false),
      modes: [native, smaller], current: native,
      nativePixels: (width: 3440, height: 1440)
    )
    let configurator = FakeSynthesisDisplayConfigurator(world)
    let suiteName = "app-tests-enumeration-\(UUID().uuidString)"
    let persistence = ModePersistence(defaults: UserDefaults(suiteName: suiteName)!)
    let modes = DisplayModeCoordinator(
      gate: DisplayReconfigurationGate(),
      configurator: configurator,
      persistence: persistence
    )
    return Rig(
      world: world, configurator: configurator, modes: modes,
      persistence: persistence, identity: identity, suiteName: suiteName
    )
  }

  @Test("One catalog refresh enumerates the display once")
  func refreshEnumeratesOnce() throws {
    let rig = Self.rig()
    defer { rig.forgetPrefs() }

    rig.world.forgetEnumerations()
    rig.modes.refreshCatalog(for: Self.panelID)

    #expect(rig.world.enumerations == [.snapshot])

    // The saving is only worth anything if the catalog is the same catalog.
    let catalog = try #require(rig.modes.catalogs[Self.panelID])
    #expect(catalog.current == Self.native)
    #expect(catalog.nativePixels?.width == 3440)
    #expect(catalog.nativePixels?.height == 1440)
    #expect(catalog.all == DisplayModeCatalog.full([Self.native, Self.smaller]))
    #expect(catalog.withheldForWireTiming == 0)
  }

  /// The stored-mode half alone, with no synthesis attached: nothing stored
  /// means nothing to ask the display about, so it is asked nothing.
  @Test("The stored-mode reapply enumerates not at all when nothing is stored")
  func storedModeReapplyWithNothingStoredDoesNotEnumerate() async {
    let rig = Self.rig()
    defer { rig.forgetPrefs() }

    rig.world.forgetEnumerations()
    await rig.modes.reapplyStoredModes()

    #expect(rig.world.enumerations.isEmpty)
    #expect(rig.world.applies.isEmpty)
  }

  /// The stored descriptor is the mode the display already runs, so no apply and
  /// no refresh follow: what is left is the one enumeration the decision needs.
  @Test("The stored-mode reapply enumerates once when a mode is stored")
  func storedModeReapplyEnumeratesOnce() async {
    let rig = Self.rig()
    defer { rig.forgetPrefs() }
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.native.descriptor, for: rig.identity)

    rig.world.forgetEnumerations()
    await rig.modes.reapplyStoredModes()

    #expect(rig.world.enumerations == [.snapshot])
    #expect(rig.world.applies.isEmpty)
  }

  /// The shape the app runs: synthesis attached, so an arrival pays the
  /// synthesis half's enumeration even with nothing stored. Still one pass.
  @Test("An arrival with synthesis attached and nothing stored enumerates once")
  func arrivalWithSynthesisAttachedEnumeratesOnce() async {
    let fixture = SynthesisFixture()
    defer { fixture.forgetPrefs() }

    fixture.world.forgetEnumerations()
    await fixture.modes.reapplyStoredModes()

    #expect(fixture.world.enumerations == [.snapshot])
    #expect(fixture.world.applies.isEmpty)
  }
}
