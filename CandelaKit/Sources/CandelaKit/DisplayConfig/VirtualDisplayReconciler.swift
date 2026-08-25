import CoreGraphics
import Foundation

/// One slot's persisted definition (VD9). `configured` means "should be live
/// NOW"; a definition whose display died with the last session reads
/// unconfigured after `launchNormalized` runs, so the stored fields survive
/// as the slot's remembered setup without implying a display exists.
public struct VirtualSlotDefinition: Sendable, Equatable {
  /// The slot EXISTS as far as the user is concerned: it has a tile in the
  /// pane whether or not a display is currently running. Added and removed
  /// by the pane's Add/Remove; distinct from `configured` because a slot
  /// whose create failed keeps its tile (to say why) while `configured`
  /// flips off (so nothing silently retries a doomed create).
  public var defined: Bool
  public var configured: Bool
  public var name: String
  public var width: Int
  public var height: Int
  public var hiDPI: Bool
  public var refreshHz: Double
  public var recreateAtLaunch: Bool
  /// Minted when the slot is first configured; survives destroy, recreate
  /// and relaunch, so logs and the pane can speak about "the same display"
  /// across recreations (VD9).
  public var uuid: UUID?

  public init(
    defined: Bool = true, configured: Bool, name: String, width: Int, height: Int,
    hiDPI: Bool, refreshHz: Double, recreateAtLaunch: Bool, uuid: UUID?
  ) {
    self.defined = defined
    self.configured = configured
    self.name = name
    self.width = width
    self.height = height
    self.hiDPI = hiDPI
    self.refreshHz = refreshHz
    self.recreateAtLaunch = recreateAtLaunch
    self.uuid = uuid
  }

  public var spec: VirtualDisplaySpec {
    VirtualDisplaySpec(
      name: name, logicalWidth: width, logicalHeight: height, hiDPI: hiDPI, refreshHz: refreshHz
    )
  }
}

/// Pure convergence of live virtual displays to the slot prefs. All lifecycle
/// decisions live here so they are testable with no hardware and no private
/// API; `AppModel.syncVirtualDisplays()` only executes what this returns.
public enum VirtualDisplayReconciler {
  public enum Action: Sendable, Equatable {
    case create(slot: Int)
    case destroy(slot: Int)
    /// Destroy then create under the same slot identity and uuid (VD1): the
    /// stored spec drifted from the live one, which is the pane's
    /// explicit-apply path (VD17).
    case recreate(slot: Int)

    public var slot: Int {
      switch self {
      case let .create(slot), let .destroy(slot), let .recreate(slot): slot
      }
    }
  }

  /// - Parameter limitedTo: when set, only this slot's convergence is
  ///   considered. This is the pane's per-slot Create/Apply/Remove semantics
  ///   made structural (VD17): a Create on slot 3 must never recreate a
  ///   drifted-but-not-applied slot 1, and in a Safe Mode session an explicit
  ///   Create must bring up exactly the clicked slot. nil is the launch
  ///   sweep, where nothing is live yet so only creates can fire.
  public static func actions(
    definitions: [Int: VirtualSlotDefinition],
    live: [VirtualDisplayHandle],
    isAvailable: Bool,
    limitedTo: Int? = nil
  ) -> [Action] {
    guard isAvailable else { return [] }
    // Duplicate slots cannot come from the host (it keys by slot), but this
    // is a public function: keep the first rather than trapping.
    let liveBySlot = Dictionary(live.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
    var actions: [Action] = []
    // USER slots only (SS6). Synthesis slots are stood and torn down by the
    // engine and have no stored definition, so a full-family sweep would read
    // them as unconfigured-but-live and destroy them on the next sync.
    for slot in VirtualDisplayIdentity.userSlotRange {
      if let limitedTo, slot != limitedTo { continue }
      let configured = definitions[slot]?.configured == true
      switch (configured, liveBySlot[slot]) {
      case (true, nil):
        actions.append(.create(slot: slot))
      case (false, .some):
        actions.append(.destroy(slot: slot))
      case let (true, .some(handle)):
        // NORMALIZED comparison, or a stored odd width that normalizes to
        // the live value would flap a recreate on every sync.
        if let definition = definitions[slot], definition.spec.normalized != handle.spec {
          actions.append(.recreate(slot: slot))
        }
      case (false, nil):
        break
      }
    }
    return actions
  }

  /// Launch prelude (the counterpart of VD13): a configured slot without
  /// recreate-at-launch died with the last session, and its pref must say so
  /// before the first sync, or that sync would silently create a display
  /// nobody asked this session for. Every other field survives as the slot's
  /// remembered setup.
  public static func launchNormalized(
    definitions: [Int: VirtualSlotDefinition]
  ) -> ([Int: VirtualSlotDefinition], changedSlots: [Int]) {
    var normalized = definitions
    var changed: [Int] = []
    for (slot, definition) in definitions where definition.configured && !definition.recreateAtLaunch {
      var copy = definition
      copy.configured = false
      normalized[slot] = copy
      changed.append(slot)
    }
    return (normalized, changed.sorted())
  }
}
