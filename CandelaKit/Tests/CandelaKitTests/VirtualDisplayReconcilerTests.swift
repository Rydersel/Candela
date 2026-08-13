import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Convergence of live virtual displays to per-slot prefs. Pure, so every
/// lifecycle decision is testable with no hardware and no private API.
@Suite("Virtual display reconciler (VD14, VD17)")
struct VirtualDisplayReconcilerTests {
  private func definition(
    configured: Bool = true, name: String = "Test", width: Int = 1920, height: Int = 1080,
    hiDPI: Bool = false, refreshHz: Double = 60, recreateAtLaunch: Bool = false
  ) -> VirtualSlotDefinition {
    VirtualSlotDefinition(
      configured: configured, name: name, width: width, height: height,
      hiDPI: hiDPI, refreshHz: refreshHz, recreateAtLaunch: recreateAtLaunch, uuid: UUID()
    )
  }

  private func handle(slot: Int, of definition: VirtualSlotDefinition) -> VirtualDisplayHandle {
    VirtualDisplayHandle(
      uuid: definition.uuid ?? UUID(), slot: slot, displayID: 100 + UInt32(slot),
      identity: VirtualDisplayIdentity.configIdentity(slot: slot),
      spec: definition.spec.normalized
    )
  }

  @Test func aConfiguredSlotWithNoLiveDisplayIsCreated() {
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: definition()], live: [], isAvailable: true
    )
    #expect(actions == [.create(slot: 1)])
  }

  @Test func aLiveDisplayWhoseSlotIsNotConfiguredIsDestroyed() {
    let def = definition(configured: false)
    let actions = VirtualDisplayReconciler.actions(
      definitions: [2: def], live: [handle(slot: 2, of: def)], isAvailable: true
    )
    #expect(actions == [.destroy(slot: 2)])
  }

  @Test func aLiveDisplayMatchingItsDefinitionIsLeftAlone() {
    let def = definition()
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: def], live: [handle(slot: 1, of: def)], isAvailable: true
    )
    #expect(actions.isEmpty)
  }

  /// The explicit-apply path (VD17): the pane edits fields, then rewrites
  /// `configured`; only that write carries `.syncVirtualDisplays`, and the
  /// drift between the live spec and the stored one is what converts it into
  /// a recreate.
  @Test func aLiveDisplayWhoseStoredSpecDriftedIsRecreated() {
    let def = definition()
    let edited = VirtualSlotDefinition(
      configured: true, name: def.name, width: 2560, height: 1440,
      hiDPI: def.hiDPI, refreshHz: def.refreshHz,
      recreateAtLaunch: def.recreateAtLaunch, uuid: def.uuid
    )
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: edited], live: [handle(slot: 1, of: def)], isAvailable: true
    )
    #expect(actions == [.recreate(slot: 1)])
  }

  /// Comparison happens over NORMALIZED specs: a stored odd width that
  /// normalizes to the live width is not drift, or every sync would flap.
  @Test func normalizationEquivalentSpecsAreNotDrift() {
    let def = definition(width: 1920)
    let stored = VirtualSlotDefinition(
      configured: true, name: def.name, width: 1921, height: def.height,
      hiDPI: def.hiDPI, refreshHz: def.refreshHz,
      recreateAtLaunch: def.recreateAtLaunch, uuid: def.uuid
    )
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: stored], live: [handle(slot: 1, of: def)], isAvailable: true
    )
    #expect(actions.isEmpty)
  }

  @Test func nothingHappensWhenTheClassFamilyIsUnavailable() {
    let def = definition()
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: def, 2: definition(configured: false)],
      live: [handle(slot: 2, of: def)], isAvailable: false
    )
    #expect(actions.isEmpty)
  }

  @Test func slotsOutsideTheRangeAreIgnored() {
    let actions = VirtualDisplayReconciler.actions(
      definitions: [0: definition(), 7: definition()], live: [], isAvailable: true
    )
    #expect(actions.isEmpty)
  }

  // MARK: - Launch normalization (VD13's counterpart)

  /// A configured slot without recreate-at-launch died with the last
  /// session; its pref must say so, or the next sync would silently create a
  /// display nobody asked this session for.
  @Test func launchFlipsConfiguredOffForSlotsThatDoNotRecreate() {
    let keep = definition(recreateAtLaunch: true)
    let drop = definition(recreateAtLaunch: false)
    let unconfigured = definition(configured: false)
    let (normalized, changed) = VirtualDisplayReconciler.launchNormalized(
      definitions: [1: keep, 2: drop, 3: unconfigured]
    )
    #expect(normalized[1]?.configured == true)
    #expect(normalized[2]?.configured == false)
    #expect(normalized[3]?.configured == false)
    #expect(changed == [2])
  }

  @Test func launchNormalizationPreservesEveryOtherField() {
    let drop = definition(name: "Keep My Name", width: 2560, height: 1440, recreateAtLaunch: false)
    let (normalized, _) = VirtualDisplayReconciler.launchNormalized(definitions: [2: drop])
    #expect(normalized[2]?.name == "Keep My Name")
    #expect(normalized[2]?.width == 2560)
    #expect(normalized[2]?.uuid == drop.uuid)
  }
}

/// The slot definition's prefs round-trip, against an isolated defaults
/// domain the way every prefs suite here does it.
@Suite("Virtual slot prefs (VD9)")
struct VirtualSlotPrefsTests {
  private func freshPrefs() -> DisplayPrefs {
    let defaults = UserDefaults(suiteName: "vd-slot-tests-\(UUID().uuidString)")!
    return DisplayPrefs(defaults: defaults, persistenceKey: "app")
  }

  @Test func anUnsetSlotReadsUnconfiguredWithTheSlotDefaults() {
    let prefs = freshPrefs()
    let def = prefs.virtualSlot(2)
    #expect(!def.configured)
    #expect(def.name == VirtualDisplayIdentity.defaultName(slot: 2))
    #expect(def.width == 1920)
    #expect(def.height == 1080)
    #expect(def.hiDPI)
    #expect(def.refreshHz == 60)
    #expect(!def.recreateAtLaunch)
    #expect(def.uuid == nil)
  }

  @Test func aDefinitionRoundTrips() {
    let prefs = freshPrefs()
    let uuid = UUID()
    let written = VirtualSlotDefinition(
      configured: true, name: "Desk", width: 3840, height: 2160,
      hiDPI: true, refreshHz: 59.9, recreateAtLaunch: true, uuid: uuid
    )
    prefs.setVirtualSlot(written, slot: 3)
    #expect(prefs.virtualSlot(3) == written)
    // Slots are independent.
    #expect(!prefs.virtualSlot(1).configured)
  }
}
