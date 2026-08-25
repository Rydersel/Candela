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

  /// SS6: synthesis slots are stood by the engine and have no stored
  /// definition, so a full-family sweep would read one as
  /// unconfigured-but-live and destroy the engine's display on the next sync.
  /// This pins the `userSlotRange` bound; on `slotRange` it draws a
  /// `.destroy`.
  @Test func aLiveSynthesisSlotDrawsNoActionAtAll() {
    let slot = VirtualDisplayIdentity.synthesisSlotRange.lowerBound
    let actions = VirtualDisplayReconciler.actions(
      definitions: [:], live: [handle(slot: slot, of: definition())], isAvailable: true
    )
    #expect(actions.isEmpty)
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

  /// VD17 made structural: a Create on one slot must never apply another
  /// slot's drifted-but-unapplied edits. Two reviewers independently found
  /// the unscoped version recreating slot 1 when slot 2 was created.
  @Test func aScopedSyncTouchesOnlyTheNamedSlot() {
    let running = definition()
    let drifted = VirtualSlotDefinition(
      configured: true, name: running.name, width: 2560, height: 1440,
      hiDPI: running.hiDPI, refreshHz: running.refreshHz,
      recreateAtLaunch: running.recreateAtLaunch, uuid: running.uuid
    )
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: drifted, 2: definition()],
      live: [handle(slot: 1, of: running)],
      isAvailable: true,
      limitedTo: 2
    )
    #expect(actions == [.create(slot: 2)])
  }

  @Test func anUnscopedSyncStillConvergesEverySlot() {
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: definition(), 3: definition()], live: [], isAvailable: true
    )
    #expect(actions == [.create(slot: 1), .create(slot: 3)])
  }

  /// Public function, caller-supplied array: duplicates keep the first
  /// rather than trapping the process.
  @Test func duplicateLiveSlotsDoNotTrap() {
    let def = definition()
    let actions = VirtualDisplayReconciler.actions(
      definitions: [1: def],
      live: [handle(slot: 1, of: def), handle(slot: 1, of: def)],
      isAvailable: true
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
    #expect(!def.defined)
    #expect(!def.configured)
    #expect(def.name == VirtualDisplayIdentity.defaultName(slot: 2))
    #expect(def.width == 1920)
    #expect(def.height == 1080)
    #expect(def.hiDPI)
    #expect(def.refreshHz == 60)
    #expect(!def.recreateAtLaunch)
    #expect(def.uuid == nil)
  }

  /// A slot staged before the defined marker existed (or by a shell write
  /// that only set configured) still shows its tile; removal clears every
  /// key including the marker.
  @Test func definedFallsBackToConfiguredAndClearsWithTheSlot() {
    let defaults = UserDefaults(suiteName: "vd-slot-tests-\(UUID().uuidString)")!
    defaults.set(true, forKey: "virtualSlotConfigured.1")
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "app")
    #expect(prefs.virtualSlot(1).defined)
    prefs.clearVirtualSlot(1)
    #expect(!prefs.virtualSlot(1).defined)
    #expect(!prefs.virtualSlot(1).configured)
  }

  /// Prefs are an escape-hatch surface: `defaults write` with no type flag
  /// stores STRINGS, which `object(forKey:) as? Int` silently rejects while
  /// `defaults.bool` accepts "YES" for `configured`. The accessor must read
  /// both halves the same way or a staged slot half-applies (a 1920-wide
  /// display from a 3440-wide pref, no error anywhere).
  @Test func shellWrittenStringValuesAreCoercedNotDropped() {
    let defaults = UserDefaults(suiteName: "vd-slot-tests-\(UUID().uuidString)")!
    defaults.set("YES", forKey: "virtualSlotConfigured.1")
    defaults.set("3440", forKey: "virtualSlotWidth.1")
    defaults.set("1440", forKey: "virtualSlotHeight.1")
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "app")
    let definition = prefs.virtualSlot(1)
    #expect(definition.configured)
    #expect(definition.width == 3440)
    #expect(definition.height == 1440)
  }

  /// A wild stored value must never reach the engine: unclamped, a huge
  /// width traps the UInt32 conversion in the host on every launch.
  @Test func storedSizesAreClampedToTheEntryRange() {
    let defaults = UserDefaults(suiteName: "vd-slot-tests-\(UUID().uuidString)")!
    defaults.set(9_999_999_999, forKey: "virtualSlotWidth.2")
    defaults.set(4, forKey: "virtualSlotHeight.2")
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "app")
    let definition = prefs.virtualSlot(2)
    #expect(definition.width == 8192)
    #expect(definition.height == 320)
  }

  /// A nil uuid in a write is a NO-OP, never a removal: the accessor reads
  /// nil for an unparseable stored string too, and a read-modify-write from
  /// any pane control must not delete the identity as a side effect.
  @Test func writingANilUUIDPreservesTheStoredOne() {
    let defaults = UserDefaults(suiteName: "vd-slot-tests-\(UUID().uuidString)")!
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "app")
    let uuid = UUID()
    var definition = prefs.virtualSlot(1)
    definition.configured = true
    definition.uuid = uuid
    prefs.setVirtualSlot(definition, slot: 1)
    var reread = prefs.virtualSlot(1)
    reread.uuid = nil
    reread.hiDPI = false
    prefs.setVirtualSlot(reread, slot: 1)
    #expect(prefs.virtualSlot(1).uuid == uuid)
    #expect(!prefs.virtualSlot(1).hiDPI)
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
