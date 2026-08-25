import Foundation

/// Why an unattended engage did not happen.
///
/// One case per refusal, rather than a single "not now", because these are not
/// interchangeable to the person who asked for the size: `hdrEngaged` is a
/// condition they can clear themselves, `staleDescriptor` means the size they
/// picked is no longer on offer at all, and `optedOut` means nothing is wrong.
/// The coordinator owns the copy; this type owns the distinction.
public enum SynthesisSkipReason: Sendable, Equatable {
  /// The per-display opt-in (SS4) is off.
  case optedOut
  /// No synthesized size was ever stored for this display.
  case nothingStored
  /// A size was stored, and the catalog no longer produces it: the panel
  /// changed, or an existing HiDPI row has taken the stop over under SS2.
  case staleDescriptor
  /// SS9. Engaging while HDR is on risks the silent HDR drop the revealed-mode
  /// work measured on mode changes.
  case hdrEngaged
  /// SS14. The built-in panel is not a synthesis target in v1.
  case builtIn
  /// The stored size is already engaged on this display.
  case alreadyEngaged
  /// The display is in a mirror set the USER built (SS7's predicate, in the
  /// direction nothing consulted before). Engaging would point a virtual
  /// display at a panel that is already showing another display's framebuffer,
  /// over a set the person asked for.
  case alreadyMirrored
  /// SS6 reserves two slots for synthesis, and both are in use.
  case noFreeSlot
}

/// One display's unattended synthesis decision.
public enum SynthesisReapplyDecision: Sendable, Equatable {
  /// Create a synthesis set for this size on this display, through
  /// `ModeSynthesisEngine`.
  case engage(SyntheticSize)
  /// Change nothing, for the stated reason.
  case skip(SynthesisSkipReason)
}

/// The unattended half of synthesized sizes: given a display's opt-in, its
/// stored stop and the state of the machine around it, decide whether to engage
/// a synthesis set at launch or on arrival.
///
/// Pure, and separate from the engine, for the same reason `ModeReapplyPolicy`
/// is: the path has no user in front of it. It is also a far heavier action
/// than a mode change, since engaging creates a virtual display and mirrors the
/// panel onto it, so the conditions under which it happens unattended are
/// stated once, here, and tested.
///
/// The order of the refusals is part of the contract, not an implementation
/// detail: whichever one fires is the one the user is told about, and a
/// reordering silently changes the explanation they get.
public enum SynthesisReapplyPolicy {
  /// - Parameters:
  ///   - optedIn: the per-display opt-in (SS4). Part of THIS decision rather
  ///     than a call-site guard, so "a display nobody opted in for is never
  ///     engaged" is a property under test instead of a property of the caller.
  ///   - stored: the persisted stop, straight from prefs.
  ///   - resolved: `stored` re-found in the ladder the panel generates today
  ///     (`SyntheticSizeCatalog.size(matching:)`). Passed in already resolved
  ///     because resolution needs the panel's rows, which this type has no
  ///     business reading. Non-nil `stored` with nil `resolved` is the stale
  ///     case; nil `stored` with non-nil `resolved` cannot arise from that
  ///     lookup and is treated as nothing stored.
  ///   - isBuiltIn: checked first, before the opt-in and before anything looks
  ///     at what was stored. SS14 is a property of the hardware rather than of
  ///     the user's choices, so a built-in panel that somehow carries a stored
  ///     size should say what it is, not report a stale or missing descriptor.
  ///   - alreadyEngaged: this display already carries a synthesis set for the
  ///     stored size. Checked before the HDR and slot gates so a set that is
  ///     working is never reported as a refusal: HDR cannot be on under an
  ///     engaged set, and the slot it occupies is by definition not free, so
  ///     either gate would otherwise turn a no-op into a false alarm.
  ///   - alreadyMirrored: this display is in a mirror set the USER built, which
  ///     is the caller's `isInMirrorSet`-and-not-`isSynthesisSet` answer rather
  ///     than a raw mirror flag: a display carrying a synthesis set is mirrored
  ///     too, and reporting that as a refusal would be this feature refusing its
  ///     own work. Checked AFTER `alreadyEngaged` for the same reason, and
  ///     BEFORE the HDR and slot gates because it is the condition that makes
  ///     the engage structurally impossible rather than merely risky: the panel
  ///     cannot mirror onto a virtual display while it is already showing
  ///     another display's framebuffer, and nothing this feature does may take
  ///     apart a set the person asked for.
  ///   - freeSlots: how many of SS6's synthesis slots are unused.
  public static func decide(
    optedIn: Bool,
    stored: SyntheticSizeDescriptor?,
    resolved: SyntheticSize?,
    isBuiltIn: Bool,
    hdrEngaged: Bool,
    alreadyEngaged: Bool,
    alreadyMirrored: Bool,
    freeSlots: Int
  ) -> SynthesisReapplyDecision {
    guard !isBuiltIn else { return .skip(.builtIn) }
    guard optedIn else { return .skip(.optedOut) }
    guard stored != nil else { return .skip(.nothingStored) }
    guard let resolved else { return .skip(.staleDescriptor) }
    guard !alreadyEngaged else { return .skip(.alreadyEngaged) }
    guard !alreadyMirrored else { return .skip(.alreadyMirrored) }
    guard !hdrEngaged else { return .skip(.hdrEngaged) }
    guard freeSlots > 0 else { return .skip(.noFreeSlot) }
    return .engage(resolved)
  }
}
