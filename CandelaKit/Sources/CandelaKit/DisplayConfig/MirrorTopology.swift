import CoreGraphics
import Foundation

/// ONE INSTANT's mirror topology, reconstructed from a single `displays()`
/// sample.
///
/// It never re-queries CoreGraphics: every answer it gives describes the same
/// moment as every other answer it gives. That is the whole point — the three
/// call sites this replaces each took a fresh `CGGetOnlineDisplayList` plus N
/// `CGDisplayMirrorsDisplay` calls, which is the sampling hazard
/// `CoreGraphicsDisplayConfigurator`'s own doc comment argues against by name.
///
/// It is also the ONE definition of "mirrored" for the whole app. Before it
/// there were three, and they disagreed: `ConfiguredDisplay.isMirrorSlave`
/// (`CGDisplayMirrorsDisplay` alone), `KeyActionExecutor.expandToMirrorSet`
/// (the two set predicates AND a null `mirrorsDisplay`), and
/// `Mirroring.engageMirror` (the two set predicates alone). Where they
/// disagreed, mode reapply deferred a display the key path was treating as a
/// master. Later tasks unify those call sites onto this; the definition itself
/// lives here so it can be judged once.
///
/// The shape of a set is fixed by the SDK and assumed throughout: ONE master
/// with N slaves, no nesting. A slave names its master with a single ID, so
/// chains collapse and one hop is always the whole answer.
///
/// Every list it hands out is `id`-ascending, never in enumeration order.
public struct MirrorTopology: Sendable, Equatable {
  public let displays: [ConfiguredDisplay]

  public init(_ displays: [ConfiguredDisplay]) {
    self.displays = displays
  }

  /// Every display that owns a framebuffer some other display is showing.
  public var masters: [CGDirectDisplayID] {
    displays.filter(\.isMirrorMaster).map(\.id).sorted()
  }

  /// The slaves of `master`. Empty for a non-master — and empty for
  /// `kCGNullDirectDisplay`, which every standalone display names and which is
  /// therefore never a set.
  public func slaves(of master: CGDirectDisplayID) -> [CGDirectDisplayID] {
    guard master != kCGNullDirectDisplay else { return [] }
    return displays.filter { $0.mirrorsDisplay == master }.map(\.id).sorted()
  }

  /// The master whose picture `displayID` is showing, or nil when it is showing
  /// its own.
  public func master(of displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isMirrorSlave
    else { return nil }
    return entry.mirrorsDisplay
  }

  /// Every display in the set `displayID` belongs to, itself included. Empty
  /// when it belongs to none. Nesting is not expressible — a slave's master is
  /// a single ID and chains collapse — so one hop is the whole answer.
  public func setMembers(containing displayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isInMirrorSet
    else { return [] }
    let master = entry.isMirrorSlave ? entry.mirrorsDisplay : entry.id
    return ([master] + slaves(of: master)).sorted()
  }

  /// `displayID` plus, when it is a master, every display mirroring it.
  ///
  /// The exact replacement for `KeyActionExecutor.expandToMirrorSet`: the
  /// master's ID is what the pointer resolves to, and the members need the same
  /// step. A non-mirrored display expands to itself. Master first, then the
  /// members `id`-ascending — the caller shows the master's HUD.
  public func expand(_ displayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isMirrorMaster
    else { return [displayID] }
    return [displayID] + slaves(of: displayID)
  }

  /// THE ENGINE BOUNDARY. The display that actually owns the pixels for
  /// `displayID`: itself when it is drawable, its MASTER when it is a mirror
  /// slave, and — deliberately — itself again when this sample does not contain
  /// it.
  ///
  /// A mirrored panel is ABSENT from `NSScreen.screens` (measured: the S2
  /// probe's `backingScale 0.0` is its "no screen matched" sentinel, not a zero
  /// scale on a present screen), so a Swift lookup returns nil. Anything that
  /// needs a screen asks this first.
  ///
  /// The unknown case returns the input UNCHANGED because a stale or empty
  /// topology must never invent a target: that fallback is exactly today's
  /// behaviour, which then fails its `NSScreen` lookup and is REPORTED (DT17)
  /// rather than guessed at.
  public func drawableDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isMirrorSlave
    else { return displayID }
    return entry.mirrorsDisplay
  }

  /// True when `displayID` is in a set it cannot be removed from. Both a
  /// candidate filter and a UI fact — such a display is named, never silently
  /// no-op'd.
  public func cannotBeUnmirrored(_ displayID: CGDirectDisplayID) -> Bool {
    displays.first { $0.id == displayID }?.isAlwaysInMirrorSet ?? false
  }
}

/// What to do about a mirror request. Never a bare `Bool`: the transplanted
/// `engageMirror` returned one, and its two `false`s meant different things.
public enum MirrorToggleDecision: Sendable, Equatable {
  /// Stage these changes to build a set around `master`.
  case engage(master: CGDirectDisplayID, changes: [MirrorChange])
  /// Stage these changes to dissolve the set. One null-master change per
  /// breakable member.
  case disengage(changes: [MirrorChange])
  /// Nothing to do, and a REASON.
  case refused(MirrorRefusal)
}

/// Why a mirror request produced no changes. Every case is something the UI can
/// state out loud; none of them is "it did not work".
public enum MirrorRefusal: Sendable, Equatable {
  /// Fewer than two online displays. The key executor falls through to a plain
  /// brightness-down step on this refusal and on NO OTHER (fork parity).
  case onlyOneDisplay
  /// Nothing eligible to be the master: no candidate that is not already locked
  /// into a set it cannot leave.
  case noEligibleMaster
  /// The set cannot be broken by anyone, because every member reports
  /// `isAlwaysInMirrorSet`. Carries the members so the UI can name them.
  case setCannotBeBroken([CGDirectDisplayID])
  /// The display named for `disengage(_:containing:)` is in no mirror set — or
  /// is not in this sample at all. Defensive in practice, since the UI offers
  /// the break button only for a set member.
  ///
  /// A FOURTH case rather than `.setCannotBeBroken([])`, which is the shape the
  /// three-case enum forced. An empty payload would have the UI say "this set
  /// cannot be broken" about a display that has no set — a false statement, in
  /// a sub-project whose sibling feature exists to stop the app making them.
  case notInASet
}

/// The pure decision, shaped like `ModeReapplyPolicy`: static funcs over plain
/// values, returning what to do and what to say, with the caller doing the
/// CoreGraphics. Foundation and CoreGraphics only — no AppKit, no SwiftUI —
/// which is what lets all of its coverage live in the Kit's test target (D21).
///
/// **Two break paths, deliberately different in SCOPE.** `toggle` is the
/// hotkey's panic button and clears EVERY mirror set on the machine;
/// `disengage(_:containing:)` is the UI's button and breaks EXACTLY ONE — the
/// set the user pointed at. Both behaviours are intended and each is named on
/// its own declaration; they are not two spellings of one operation.
public enum MirrorTopologyPolicy {
  /// The hotkey's decision: break existing mirroring, else build a set.
  ///
  /// **Breaks EVERY set on the machine**, not just one. That is fork parity —
  /// the shipped `Mirroring` path iterated the whole online list — and it is
  /// the right reading of a panic button: someone pressing it wants their
  /// desktops back, not a negotiation about which set they meant. The UI's
  /// `disengage(_:containing:)` is the one-set operation.
  ///
  /// Evaluated top to bottom, first match wins (spec §6.2.3, rows T1–T5).
  public static func toggle(_ topology: MirrorTopology) -> MirrorToggleDecision {
    guard topology.displays.count >= 2 else { return .refused(.onlyOneDisplay) }

    let members = topology.displays.filter(\.isInMirrorSet)
    if !members.isEmpty {
      // Every set on the machine is dissolved, which is what the fork did: it
      // iterated the whole online list rather than one set.
      let breakable = members.filter { !$0.isAlwaysInMirrorSet }.map(\.id).sorted()
      guard !breakable.isEmpty else {
        return .refused(.setCannotBeBroken(members.map(\.id).sorted()))
      }
      return .disengage(changes: breakable.map {
        MirrorChange(display: $0, master: kCGNullDirectDisplay)
      })
    }

    // Fork parity: the master is a NON-built-in display and the built-in
    // becomes a slave, deliberately. Lowest id rather than list order is ours.
    let candidates = topology.displays
      .filter { !$0.isBuiltIn && !$0.isAlwaysInMirrorSet }
      .map(\.id)
      .sorted()
    guard let master = candidates.first else { return .refused(.noEligibleMaster) }
    return engage(topology, master: master)
  }

  /// The UI's decision: build a set around a NAMED master. Unlike `toggle`, the
  /// built-in is an acceptable master here — that is a person asking for it by
  /// name, not a heuristic choosing for them.
  public static func engage(
    _ topology: MirrorTopology, master: CGDirectDisplayID
  ) -> MirrorToggleDecision {
    guard topology.displays.count >= 2 else { return .refused(.onlyOneDisplay) }
    guard let chosen = topology.displays.first(where: { $0.id == master }),
          !chosen.isAlwaysInMirrorSet
    else { return .refused(.noEligibleMaster) }

    // A locked display is never STAGED either: the change cannot succeed, and
    // one failed stage cancels the whole transaction (Task 3), so including it
    // would mirror nothing at all.
    let changes = topology.displays
      .filter { $0.id != chosen.id && !$0.isAlwaysInMirrorSet }
      .map(\.id)
      .sorted()
      .map { MirrorChange(display: $0, master: chosen.id) }
    guard !changes.isEmpty else { return .refused(.noEligibleMaster) }
    return .engage(master: chosen.id, changes: changes)
  }

  /// The UI's decision: dissolve the ONE set that `member` belongs to, leaving
  /// every other set on the machine alone. The counterpart to `toggle`'s
  /// machine-wide break, and the difference is the whole reason both exist: the
  /// user clicked a button attached to a particular set.
  ///
  /// A display in no set is refused as `.notInASet` rather than as a set that
  /// cannot be broken — see `MirrorRefusal.notInASet`.
  public static func disengage(
    _ topology: MirrorTopology, containing member: CGDirectDisplayID
  ) -> MirrorToggleDecision {
    let members = topology.setMembers(containing: member)
    guard !members.isEmpty else { return .refused(.notInASet) }
    let breakable = members.filter { !topology.cannotBeUnmirrored($0) }
    guard !breakable.isEmpty else { return .refused(.setCannotBeBroken(members)) }
    return .disengage(changes: breakable.map {
      MirrorChange(display: $0, master: kCGNullDirectDisplay)
    })
  }

  /// The changes needed to get from `current` back to `captured` — the
  /// preview's revert path. The fallback for a mirror preview is a TOPOLOGY,
  /// never a mode: on a slave `currentMode(for:)` reports the MASTER's geometry
  /// and may return nil outright.
  ///
  /// A display absent from `captured` is restored to unmirrored: the capture
  /// never described it, and leaving it in a set the user is undoing is the
  /// worse of the two readings.
  public static func changes(
    from current: MirrorTopology, to captured: MirrorTopology
  ) -> [MirrorChange] {
    current.displays
      .filter { !$0.isAlwaysInMirrorSet }
      .sorted { $0.id < $1.id }
      .compactMap { display in
        let wanted = captured.displays
          .first { $0.id == display.id }?.mirrorsDisplay ?? kCGNullDirectDisplay
        guard display.mirrorsDisplay != wanted else { return nil }
        return MirrorChange(display: display.id, master: wanted)
      }
  }
}
