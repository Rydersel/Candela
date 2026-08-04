import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence mirroring says, in one place.
///
/// One `…Copy` enum because these words appear on three surfaces — the settings
/// section, the menu-bar panel and the confirmation window — and a rule enforced
/// in three private helpers is a rule that drifts the first time one of them is
/// edited. `DisplayModeCopy` is the same arrangement for the same reason.
///
/// `LocalizedStringKey` is not `Sendable`, so these are computed `static var`s
/// rather than `static let`s (a `static let` of one is a concurrency error under
/// complete checking). Each is a literal with no state behind it.
///
/// The CoreGraphics error code never appears in any of these. It is diagnostic,
/// it belongs in a `.help(…)` tooltip, and it is not something to make someone
/// read while their screen is wrong.
enum MirroringCopy {
  static var sectionTitle: LocalizedStringKey { "Mirroring" }
  static var notMirrored: LocalizedStringKey { "Not mirrored" }
  static var question: LocalizedStringKey { "Keep mirroring?" }
  static var keep: LocalizedStringKey { "Keep" }
  static var stopNow: LocalizedStringKey { "Stop Mirroring Now" }
  static var startMirroring: LocalizedStringKey { "Start Mirroring" }
  static var stopMirroring: LocalizedStringKey { "Stop Mirroring" }
  /// The report window's headline. Says what did NOT happen, because that is the
  /// whole content of the report — nothing on screen changed.
  static var reportTitle: LocalizedStringKey { "Mirroring not changed" }

  // MARK: - Refusals
  //
  // `MirrorRefusal` has SEVEN cases and each gets its own sentence here. They
  // are seven cases precisely because one of them used to carry three meanings,
  // one of which was false — telling someone who has just named a perfectly good
  // master that "no display can be the mirror master" is not a rounding error,
  // it is a wrong statement about their machine. A `default:` arm anywhere that
  // consumes this would quietly undo that.

  /// `.onlyOneDisplay`. Also the empty-sample case: on the rig this actually
  /// happens on — a laptop with nothing plugged in — this is the truth.
  static var needsASecondDisplay: LocalizedStringKey {
    "Mirroring needs a second display."
  }

  /// `.noEligibleMaster`. A statement about the MACHINE, and reachable only from
  /// the hotkey's automatic scan.
  static var noEligibleMaster: LocalizedStringKey {
    "No display here can show the picture for the others."
  }

  /// `.noSuchDisplay`. The display named is not in the sample — unplugged, or
  /// filtered out of the list the topology was built from.
  static var noSuchDisplay: LocalizedStringKey {
    "That display is no longer connected."
  }

  /// `.masterIsAlwaysMirrored`. A fact about the ONE display the user pointed
  /// at, which is why it is not the sentence above.
  static var masterIsAlwaysMirrored: LocalizedStringKey {
    "macOS keeps this display mirrored to another one, so it cannot show the picture for the others."
  }

  /// `.nothingToMirror`. The named master is fine; there is nothing that can
  /// join it.
  static var nothingToMirror: LocalizedStringKey {
    "No other display can be mirrored onto this one — macOS keeps the rest locked to the displays they are already showing."
  }

  /// The caption for a display that is ITSELF `isAlwaysInMirrorSet`, and for
  /// nothing else. Named, never a bare grey (R8 generalised: no state is carried
  /// by shape alone).
  ///
  /// NOT the sentence for `.setCannotBeBroken` — it used to be, and it was false
  /// on two shapes that reach that refusal. See `setCannotBeBroken(members:name:)`.
  /// The word "this" resolves here because both surfaces that use it are showing
  /// one display's own row and have already asked
  /// `MirrorTopology.cannotBeUnmirrored` about that display.
  static var cannotBeUnmirrored: LocalizedStringKey {
    "macOS keeps this display mirrored and will not let it be separated."
  }

  /// `.setCannotBeBroken(members)` — the only refusal with a payload, and the
  /// only sentence here that is BUILT rather than written.
  ///
  /// The payload-free sentence this case used to reuse (`cannotBeUnmirrored`,
  /// "macOS keeps this display mirrored…") is FALSE on two shapes that reach
  /// this refusal, and one of them is a click away. `MirrorTopologyPolicy`
  /// refuses whenever no member is a slave macOS will release, so an UNLOCKED
  /// master whose every slave is locked lands here — a display that is neither
  /// mirrored nor locked, whose pane would have said it was both, two rows under
  /// a status line reading "Mirrored to 1 display". A master whose slaves were
  /// filtered out of the sample is the second shape.
  ///
  /// Naming the members is true in every surface, because it makes no claim
  /// about whichever display's pane it lands in — which is why `MirrorRefusal`
  /// carries them ("so the UI can name them") rather than being a bare case.
  ///
  /// Falls back to a count for `partialBreak`'s reason: a display macOS locks
  /// into a set is exactly the kind nothing can name (Sidecar, an AirPlay
  /// receiver), and half a list reads as a bug rather than as a report.
  ///
  /// "Turned off for" rather than "separated from what it is mirroring", because
  /// the members include the MASTER, which is mirroring nothing.
  static func setCannotBeBroken(
    members: [CGDirectDisplayID], name: (CGDirectDisplayID) -> String
  ) -> String {
    let named = members.map(name).filter { !$0.isEmpty }
    if !named.isEmpty, named.count == members.count {
      return named.count == 1
        ? "macOS will not let mirroring be turned off for \(named[0])."
        : "macOS will not let mirroring be turned off for these displays: \(named.joined(separator: ", "))."
    }
    return members.count == 1
      ? "macOS will not let mirroring be turned off for that display."
      : "macOS will not let mirroring be turned off for those \(members.count) displays."
  }

  /// `.notInASet`. A fourth refusal rather than an empty `setCannotBeBroken`
  /// payload, so the UI never says "this set cannot be broken" about a display
  /// that has no set.
  static var notInASet: LocalizedStringKey {
    "This display is not mirroring anything."
  }

  /// One sentence for whichever refusal happened, so every surface makes the
  /// same statement about the same refusal.
  ///
  /// Returns `Text` rather than `LocalizedStringKey` because one of the seven
  /// carries a payload and its sentence is built from it; a second function for
  /// that one case would be the two-spellings problem this file exists to
  /// prevent. `Text` is the type both spellings have in common.
  ///
  /// Takes the naming closure for the same reason `partialBreak` and `state` do:
  /// friendly-name resolution belongs to the surface, not here.
  static func refusal(
    _ refusal: MirrorRefusal, name: (CGDirectDisplayID) -> String
  ) -> Text {
    switch refusal {
    case .onlyOneDisplay: Text(needsASecondDisplay)
    case .noEligibleMaster: Text(noEligibleMaster)
    case .noSuchDisplay: Text(noSuchDisplay)
    case .masterIsAlwaysMirrored: Text(masterIsAlwaysMirrored)
    case .nothingToMirror: Text(nothingToMirror)
    case let .setCannotBeBroken(members):
      Text(verbatim: setCannotBeBroken(members: members, name: name))
    case .notInASet: Text(notInASet)
    }
  }

  // MARK: - The settings section's own sentences
  //
  // Here rather than in the view for the reason this file exists: mirroring
  // speaks on three surfaces and a sentence written in one of them is a sentence
  // the other two cannot reuse and cannot be checked against.

  static var statusLabel: LocalizedStringKey { "Status" }
  static var pickMaster: LocalizedStringKey { "Show the picture from" }

  /// What Start does when nothing on the machine is locked into a set.
  static var startExplanation: LocalizedStringKey {
    "The display you pick shows its picture on every other display. You get fifteen seconds to keep it."
  }

  /// What Start does when something IS locked. `MirrorTopologyPolicy.engage`
  /// stages no change for an `isAlwaysInMirrorSet` display — the change cannot
  /// succeed and one failed stage cancels the whole transaction — so "every
  /// other display" is a promise the apply does not keep on such a rig.
  static var startExplanationSomeLocked: LocalizedStringKey {
    """
    The display you pick shows its picture on the other displays, apart from \
    any that macOS keeps mirrored elsewhere. You get fifteen seconds to keep it.
    """
  }

  /// What Stop does when every member of the set can be released.
  static var stopExplanation: LocalizedStringKey {
    "Returns every display in the set to its own desktop. Nothing else changes."
  }

  /// What Stop does when a member of the set is one macOS will not release.
  /// "Nothing else changes" is true of the rest either way; what is NOT true on
  /// this rig is "every display", and reporting the shortfall afterwards does
  /// not repair a promise made beforehand.
  static var stopExplanationSomeLocked: LocalizedStringKey {
    "Returns the displays macOS will release to their own desktops. The ones it keeps mirrored stay mirrored."
  }

  /// Why a control is dead WHILE a change is being applied — the reason, not a
  /// description of what the button does. A grey control with nothing attached
  /// is the defect R8 forbids, and that includes the transient greying
  /// `isApplying` causes.
  static var applyInProgress: LocalizedStringKey {
    "Waiting for the last mirroring change to finish."
  }

  // MARK: - Failures

  /// Never overclaims: it says what was asked for and what did not happen.
  static var applyFailure: LocalizedStringKey {
    "The mirroring change did not take effect, and nothing was altered."
  }

  static var resolveFailure: LocalizedStringKey {
    "Mirroring could not be undone. Nothing retries this on its own — try again."
  }

  /// A break that LEFT SOMETHING BEHIND.
  ///
  /// `MirrorToggleDecision.disengage` carries `residualMembers` for exactly this
  /// sentence: a locked slave keeps mirroring, which keeps its master a master,
  /// so the set is only partly broken. Binding that residue and ignoring it
  /// would report "mirroring off" over a set the user is still looking at —
  /// the silent-success defect this whole sub-project exists to close,
  /// re-created one layer up.
  ///
  /// Names the survivors when every one of them can be named, and falls back to
  /// a count when it cannot: an unnameable display is exactly the kind that gets
  /// locked into a set (Sidecar, an AirPlay receiver), and half a list reads as
  /// a bug rather than as a report.
  static func partialBreak(
    residual: [CGDirectDisplayID], name: (CGDirectDisplayID) -> String
  ) -> String {
    let named = residual.map(name).filter { !$0.isEmpty }
    if !named.isEmpty, named.count == residual.count {
      return "Still mirrored, because macOS will not let them be separated: \(named.joined(separator: ", "))."
    }
    return residual.count == 1
      ? "One display is still mirrored, because macOS will not let it be separated."
      : "\(residual.count) displays are still mirrored, because macOS will not let them be separated."
  }

  // MARK: - Live state

  static func countdown(_ seconds: Int) -> String {
    seconds == 1 ? "Reverting in 1 second" : "Reverting in \(seconds) seconds"
  }

  /// "Showing Built-in Display" / "Mirrored to 2 displays". Words rather than a
  /// badge, so the state survives a screenshot in a bug report.
  static func state(
    topology: MirrorTopology, displayID: CGDirectDisplayID, name: (CGDirectDisplayID) -> String
  ) -> String {
    if let master = topology.master(of: displayID) {
      return "Showing \(name(master))"
    }
    let slaves = topology.slaves(of: displayID)
    guard !slaves.isEmpty else { return "Not mirrored" }
    return slaves.count == 1
      ? "Mirrored to 1 display"
      : "Mirrored to \(slaves.count) displays"
  }
}
