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
/// Every list it hands out is `id`-ascending, never in enumeration order —
/// `displays` INCLUDED, which is why the initialiser sorts rather than the
/// accessors. A promise the stored property quietly broke would be worse than
/// no promise: `CGGetOnlineDisplayList` order is also what `Equatable` would
/// otherwise compare on, so two samples of one unchanged machine could differ.
public struct MirrorTopology: Sendable, Equatable {
  public let displays: [ConfiguredDisplay]

  public init(_ displays: [ConfiguredDisplay]) {
    self.displays = displays.sorted { $0.id < $1.id }
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
  ///
  /// MAY NAME AN ID THAT IS NOT IN `displays`, and that is deliberate. A slave
  /// names its master by ID; that master need not be in the sample, because the
  /// sample can be stale or can have been built from a filtered list (externals
  /// only, say, dropping a built-in master). This is the honest report of what
  /// the slave says, so it is not intersected the way `setMembers(containing:)`
  /// is — the difference is that `setMembers` feeds `disengage`, which STAGES a
  /// change per member into an all-or-nothing transaction, where one phantom
  /// would stop a perfectly breakable set from breaking at all. Nothing stages
  /// from this.
  ///
  /// So: fine to display, fine to compare; look the result up in `displays`
  /// before treating it as a display you can act on.
  public func master(of displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isMirrorSlave
    else { return nil }
    return entry.mirrorsDisplay
  }

  /// Every display in the set `displayID` belongs to, itself included. Empty
  /// when it belongs to none. Nesting is not expressible — a slave's master is
  /// a single ID and chains collapse — so one hop is the whole answer.
  ///
  /// INTERSECTED WITH THE SAMPLE, always. A slave names its master by ID, and
  /// that ID need not be in `displays`: the sample can be stale, and a consumer
  /// is free to build a topology from a filtered list (externals only, say,
  /// dropping the built-in master). Naming the absent master here would hand
  /// `disengage` a member it stages a change for, and Task 3's transaction is
  /// all-or-nothing — so one phantom would stop a perfectly breakable set from
  /// breaking at all. This is the same doctrine `drawableDisplayID` follows
  /// when it returns its input unchanged: a topology never invents a target.
  public func setMembers(containing displayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isInMirrorSet
    else { return [] }
    let master = entry.isMirrorSlave ? entry.mirrorsDisplay : entry.id
    let sampled = Set(displays.map(\.id))
    return ([master] + slaves(of: master)).filter { sampled.contains($0) }.sorted()
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
  ///
  /// INTERSECTED WITH THE SAMPLE, for the same reason `setMembers(containing:)`
  /// is and `master(of:)` deliberately is not. A slave names its master by ID
  /// and that ID need not be in `displays` — a stale sample, or a topology built
  /// from a filtered list. `master(of:)` reports it anyway because it is a fact
  /// ABOUT THE SLAVE; this is a TARGET, and its whole contract is that the
  /// caller may act on it without looking it up first. Every consumer here does
  /// exactly that: `GammaController` parks its activity enforcer on the result,
  /// `ShadeOverlay` frames a window on it, `BrightnessHUD` and
  /// `ModeConfirmationWindow` place themselves on it.
  ///
  /// Handing back a phantom master would be strictly worse than handing back the
  /// raw ID, and not merely equivalent. Both fail the `NSScreen` lookup, but the
  /// phantom can NEVER succeed, while the raw ID succeeds the moment the sample
  /// was merely stale about mirroring and the display has a screen of its own.
  /// Since Task 5 the gamma leg clears its dedupe memo on failure, so a target
  /// that can never resolve is re-attempted and re-logged on every drag event —
  /// a live-lock on the hottest path in the app rather than a one-off refusal.
  public func drawableDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    guard let entry = displays.first(where: { $0.id == displayID }), entry.isMirrorSlave,
          displays.contains(where: { $0.id == entry.mirrorsDisplay })
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
  /// Stage these changes to break mirroring: one null-master change per
  /// breakable member.
  ///
  /// `residualMembers` is what will STILL be in a mirror set once they commit,
  /// and it is the reason this case is not just a change list. A locked member
  /// is never staged (the change cannot succeed and would cancel the whole
  /// transaction), so a set containing one is only PARTLY broken — the locked
  /// slave keeps mirroring, and its master keeps being a master. Empty means
  /// the break is total.
  ///
  /// Without this field the outcome is indistinguishable from a total break,
  /// and a caller reports "mirroring off" over a set the user is still looking
  /// at. That is the T3 defect — success reported while nothing changed —
  /// re-created one layer up, so the type refuses to express it.
  case disengage(changes: [MirrorChange], residualMembers: [CGDirectDisplayID])
  /// Nothing to do, and a REASON.
  case refused(MirrorRefusal)
}

/// Why a mirror request produced no changes. Every case is something the UI can
/// state out loud; none of them is "it did not work".
public enum MirrorRefusal: Sendable, Equatable {
  /// Fewer than two displays in the sample. The key executor falls through to a
  /// plain brightness-down step on this refusal and on NO OTHER (fork parity).
  ///
  /// An EMPTY sample lands here too. The name is the user-facing truth on the
  /// rig this actually happens on — a laptop with nothing plugged in — and an
  /// empty online list is not a machine state, it is a topology read between a
  /// teardown and its callback. Nothing useful can be said about it that is not
  /// also true of "you only have one display".
  case onlyOneDisplay
  /// `toggle`'s automatic scan found nothing that could own a set: every
  /// display is either the built-in (which the hotkey never promotes, fork
  /// parity) or locked into a set it cannot leave.
  ///
  /// Reachable from `toggle` ONLY. The named-master path has its own three
  /// answers below, because "nothing can be the master" is a false statement
  /// when the caller has just named a display that can.
  case noEligibleMaster
  /// The display named is not in this sample — unplugged, or filtered out of
  /// the list the topology was built from. Never guessed at: see
  /// `MirrorTopology.setMembers(containing:)`.
  case noSuchDisplay
  /// The display named as master is locked into a mirror set it cannot leave
  /// (`isAlwaysInMirrorSet`), so it cannot own a different one.
  ///
  /// Distinct from `noEligibleMaster` because it is a fact about the ONE
  /// display the caller pointed at, and the sentence the UI needs is about that
  /// display rather than about the machine.
  case masterIsAlwaysMirrored
  /// The named master is perfectly eligible and there is nothing to mirror onto
  /// it: every other display in the sample is locked into a set it cannot
  /// leave, and a locked display is never staged.
  ///
  /// Split out of `noEligibleMaster` for the same reason `notInASet` was split
  /// out of `setCannotBeBroken`. Saying "no display can be the mirror master"
  /// to someone who has just picked one that can is simply untrue.
  case nothingToMirror
  /// Mirroring here cannot be broken: no member of the set can be REMOVED from
  /// it. Every slave reports `isAlwaysInMirrorSet`, and unmirroring the master
  /// alone changes nothing — it is not mirroring anyone. Carries the members so
  /// the UI can name them.
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

    // Every set on the machine is dissolved, which is what the fork did: it
    // iterated the whole online list rather than one set.
    let members = topology.displays.filter(\.isInMirrorSet).map(\.id)
    if !members.isEmpty { return dissolve(topology, members: members) }

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
  ///
  /// Its three refusals are three different sentences, never `noEligibleMaster`:
  /// the display is not here (`noSuchDisplay`), the display cannot own a set
  /// (`masterIsAlwaysMirrored`), or nothing else can join the one it would own
  /// (`nothingToMirror`). Only the last of those is about the machine.
  public static func engage(
    _ topology: MirrorTopology, master: CGDirectDisplayID
  ) -> MirrorToggleDecision {
    guard topology.displays.count >= 2 else { return .refused(.onlyOneDisplay) }
    guard let chosen = topology.displays.first(where: { $0.id == master })
    else { return .refused(.noSuchDisplay) }
    guard !chosen.isAlwaysInMirrorSet else { return .refused(.masterIsAlwaysMirrored) }

    // A locked display is never STAGED either: the change cannot succeed, and
    // one failed stage cancels the whole transaction (Task 3), so including it
    // would mirror nothing at all.
    let changes = topology.displays
      .filter { $0.id != chosen.id && !$0.isAlwaysInMirrorSet }
      .map(\.id)
      .sorted()
      .map { MirrorChange(display: $0, master: chosen.id) }
    guard !changes.isEmpty else { return .refused(.nothingToMirror) }
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
    return dissolve(topology, members: members)
  }

  /// The single break rule, shared by both paths so they cannot drift: the ONLY
  /// difference between the hotkey's break and the UI's is which members are
  /// handed in.
  ///
  /// Two things it gets right that a bare "one change per breakable member"
  /// does not.
  ///
  /// **A set is broken by removing its SLAVES.** The master is not mirroring
  /// anyone, so a null-master change on it is idempotent — real, staged for
  /// parity with the shipped path and because it makes the intent explicit, but
  /// it changes nothing on its own. So eligibility is decided on the slaves: if
  /// every slave is locked, the set survives untouched no matter what is
  /// staged, and that is a REFUSAL, not a disengage. Without this rule, the
  /// second press on a partly-locked rig stages a lone master change, commits
  /// `.success`, reports mirroring off, and leaves the set exactly as it was —
  /// forever, since every later press takes the same branch. That is the T3
  /// defect wearing a new coat.
  ///
  /// **What survives is reported.** A locked slave keeps mirroring, which keeps
  /// its master a master, so both are named in `residualMembers` rather than
  /// left for the caller to infer from a change list that does not mention
  /// them.
  private static func dissolve(
    _ topology: MirrorTopology, members: [CGDirectDisplayID]
  ) -> MirrorToggleDecision {
    let sampled = Set(members)
    let entries = topology.displays.filter { sampled.contains($0.id) }

    guard entries.contains(where: { $0.isMirrorSlave && !$0.isAlwaysInMirrorSet }) else {
      return .refused(.setCannotBeBroken(entries.map(\.id).sorted()))
    }

    let breakable = entries.filter { !$0.isAlwaysInMirrorSet }.map(\.id).sorted()
    let staged = Set(breakable)
    let surviving = entries.filter { $0.isMirrorSlave && !staged.contains($0.id) }
    let present = Set(topology.displays.map(\.id))
    let residual = Set(surviving.map(\.id) + surviving.map(\.mirrorsDisplay))
      .filter { present.contains($0) }
      .sorted()

    return .disengage(
      changes: breakable.map { MirrorChange(display: $0, master: kCGNullDirectDisplay) },
      residualMembers: residual
    )
  }

  /// The changes needed to get from `current` back to `captured` — the
  /// preview's revert path. The fallback for a mirror preview is a TOPOLOGY,
  /// never a mode: on a slave `currentMode(for:)` reports the MASTER's geometry
  /// and may return nil outright.
  ///
  /// A display absent from `captured` is restored to unmirrored: the capture
  /// never described it, and leaving it in a set the user is undoing is the
  /// worse of the two readings.
  ///
  /// **BEST EFFORT, not total: a locked display is skipped.** A display
  /// reporting `isAlwaysInMirrorSet` cannot be moved, so no change is emitted
  /// for it even when `captured` says it was somewhere else — the same staging
  /// rule the rest of this type follows, since one impossible change cancels
  /// the whole transaction and would revert nothing at all. The consequence is
  /// real and belongs at the call site rather than in a report nobody reads: a
  /// revert can complete with a locked display still mirroring, so a caller
  /// that says "restored" says slightly more than it knows. Compare
  /// `MirrorToggleDecision.disengage`, which names its residue for exactly this
  /// reason.
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
