import Foundation

/// Why an unattended engage did not happen. One case per refusal rather than a
/// single "not now": `hdrEngaged` is a condition the person can clear
/// themselves, `staleDescriptor` means the size they picked is no longer on
/// offer, and `optedOut` means nothing is wrong.
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
  /// The display is in a mirror set the USER built (SS7's predicate). Engaging
  /// would point a virtual display at a panel already showing another display's
  /// framebuffer, over a set the person asked for.
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
/// Pure and separate from the engine, like `ModeReapplyPolicy`, because nobody
/// is watching. It is also far heavier than a mode change: engaging creates a
/// virtual display and mirrors the panel onto it.
///
/// The order of the refusals is part of the contract. Whichever one fires is
/// what the user is told, so a reordering changes the explanation they get.
public enum SynthesisReapplyPolicy {
  /// - Parameters:
  ///   - optedIn: the per-display opt-in (SS4). Part of THIS decision rather
  ///     than a call-site guard, so "a display nobody opted in for is never
  ///     engaged" is a property under test here.
  ///   - stored: the persisted stop, straight from prefs.
  ///   - resolved: `stored` re-found in the ladder the panel generates today
  ///     (`SyntheticSizeCatalog.size(matching:)`), resolved by the caller
  ///     because it needs rows this type has no business reading. Non-nil
  ///     `stored` with nil `resolved` is the stale case; the reverse cannot
  ///     arise from that lookup and reads as nothing stored.
  ///   - isBuiltIn: checked first, before the opt-in and before anything reads
  ///     what was stored. SS14 is a property of the hardware, so a built-in that
  ///     somehow carries a stored size says so rather than reporting a stale or
  ///     missing descriptor.
  ///   - alreadyEngaged: this display already carries a synthesis set for the
  ///     stored size. Checked before the HDR and slot gates, or a working set
  ///     reads as a refusal: HDR cannot be on under an engaged set, and the slot
  ///     it occupies is by definition not free.
  ///   - alreadyMirrored: in a mirror set the USER built, which is the caller's
  ///     `isInMirrorSet`-and-not-`isSynthesisSet` answer rather than a raw
  ///     mirror flag, since a display carrying a synthesis set is mirrored too.
  ///     Checked after `alreadyEngaged`, and before the HDR and slot gates
  ///     because it makes the engage structurally impossible rather than merely
  ///     risky, and nothing this feature does may take apart a set the person
  ///     asked for.
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
