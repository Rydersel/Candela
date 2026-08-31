import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence mirroring says, in one place, because these words appear on
/// several surfaces and copy split across private helpers drifts.
///
/// `LocalizedStringKey` is not `Sendable`, so these are computed `static var`s:
/// a `static let` of one is a concurrency error under complete checking.
///
/// The CoreGraphics error code never appears here. It is diagnostic, it belongs
/// in a `.help(…)` tooltip, and nobody should read it while their screen is
/// wrong.
enum MirroringCopy {
  static var sectionTitle: LocalizedStringKey { "Mirroring" }
  static var notMirrored: LocalizedStringKey { LocalizedStringKey(Self.notMirroredText) }
  /// One spelling, shared with the `String`-returning `state(_:)`.
  static let notMirroredText = "Not mirrored"
  static var question: LocalizedStringKey { "Keep mirroring?" }
  static var keep: LocalizedStringKey { "Keep" }
  static var stopNow: LocalizedStringKey { "Stop Mirroring Now" }
  static var startMirroring: LocalizedStringKey { "Start Mirroring" }
  static var stopMirroring: LocalizedStringKey { "Stop Mirroring" }
  /// The report window's headline. Says what did NOT happen, because that is the
  /// whole content of the report: nothing on screen changed.
  static var reportTitle: LocalizedStringKey { "Mirroring not changed" }

  // MARK: - Refusals
  //
  // Every `MirrorRefusal` case gets its own sentence. Several exist because one
  // case used to carry three meanings, one of them false: telling someone who
  // just named a perfectly good master that "no display can be the mirror
  // master" is a wrong statement about their machine. A `default:` arm anywhere
  // that consumes this would quietly undo that.

  /// `.onlyOneDisplay`, and the empty-sample case too: on a laptop with nothing
  /// plugged in, this is the truth.
  static var needsASecondDisplay: LocalizedStringKey {
    "Mirroring needs a second display."
  }

  /// `.noEligibleMaster`. A statement about the MACHINE, and reachable only from
  /// the hotkey's automatic scan.
  static var noEligibleMaster: LocalizedStringKey {
    "No display here can show the picture for the others."
  }

  /// `.noSuchDisplay`. The display named is not in the sample: unplugged, or
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
    "No other display can be mirrored onto this one: macOS keeps the rest locked to the displays they are already showing."
  }

  /// `.alreadyMirrored`. The named master's set already holds everything that
  /// could join it. Stated outright rather than staged as an all-no-op
  /// transaction, which macOS fails at commit.
  static var alreadyMirrored: LocalizedStringKey {
    "Every display that can mirror this one already is."
  }

  /// The caption for a display that is ITSELF `isAlwaysInMirrorSet`, and nothing
  /// else. Named, never a bare grey (R8 generalised: no state carried by shape
  /// alone).
  ///
  /// NOT the sentence for `.setCannotBeBroken`, where it is false on two shapes.
  /// "This" resolves because both surfaces using it show one display's own row
  /// and have already asked `MirrorTopology.cannotBeUnmirrored` about it.
  static var cannotBeUnmirrored: LocalizedStringKey {
    "macOS keeps this display mirrored and will not let it be separated."
  }

  /// `.setCannotBeBroken(members)`: the only refusal with a payload, and the
  /// only sentence here that is BUILT rather than written.
  ///
  /// `cannotBeUnmirrored` is FALSE on two shapes that reach this refusal.
  /// `MirrorTopologyPolicy` refuses whenever no member is a slave macOS will
  /// release, so an UNLOCKED master whose every slave is locked lands here,
  /// neither mirrored nor locked, two rows under "Mirrored to 1 display". A
  /// master whose slaves were filtered out of the sample is the second shape.
  ///
  /// Naming the members makes no claim about whichever display's pane it lands
  /// in, which is why `MirrorRefusal` carries them at all.
  ///
  /// Falls back to a count for `partialBreak`'s reason: a display macOS locks
  /// into a set is exactly the kind nothing can name (Sidecar, an AirPlay
  /// receiver), and half a list reads as a bug rather than a report.
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

  /// `.notInASet`. Its own case rather than an empty `setCannotBeBroken`
  /// payload, so nothing ever says "this set cannot be broken" about a display
  /// with no set.
  static var notInASet: LocalizedStringKey {
    "This display is not mirroring anything."
  }

  /// One sentence for whichever refusal happened, so every surface makes the
  /// same statement about the same refusal.
  ///
  /// Returns `Text`, not `LocalizedStringKey`, because one case carries a
  /// payload and its sentence is built from it; a second function for that case
  /// would be the two-spellings problem this file prevents.
  ///
  /// Takes the naming closure because friendly-name resolution belongs to the
  /// surface, not here.
  static func refusal(
    _ refusal: MirrorRefusal, name: (CGDirectDisplayID) -> String
  ) -> Text {
    switch refusal {
    case .onlyOneDisplay: Text(needsASecondDisplay)
    case .noEligibleMaster: Text(noEligibleMaster)
    case .noSuchDisplay: Text(noSuchDisplay)
    case .masterIsAlwaysMirrored: Text(masterIsAlwaysMirrored)
    case .nothingToMirror: Text(nothingToMirror)
    case .alreadyMirrored: Text(alreadyMirrored)
    case let .setCannotBeBroken(members):
      Text(verbatim: setCannotBeBroken(members: members, name: name))
    case .notInASet: Text(notInASet)
    }
  }

  // MARK: - The settings section's own sentences

  /// The row carries the topic word: the control sits inline in the hub's
  /// Display section, where a bare "Status" would not say of what.
  static var statusLabel: LocalizedStringKey { "Mirroring" }
  static var pickMaster: LocalizedStringKey { "Show the picture from" }

  /// What Start does when nothing on the machine is locked into a set.
  static var startExplanation: LocalizedStringKey {
    "The display you pick shows its picture on every other display. You get thirty seconds to keep it."
  }

  /// What Start does when something IS locked. `MirrorTopologyPolicy.engage`
  /// stages no change for an `isAlwaysInMirrorSet` display (it cannot succeed,
  /// and one failed stage cancels the transaction), so "every other display"
  /// is a promise the apply does not keep on such a rig.
  static var startExplanationSomeLocked: LocalizedStringKey {
    """
    The display you pick shows its picture on the other displays, apart from \
    any that macOS keeps mirrored elsewhere. You get thirty seconds to keep it.
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

  /// Why a control is dead WHILE a change applies: the reason, not what the
  /// button does. A grey control with nothing attached is the defect R8 forbids,
  /// transient greying included.
  static var applyInProgress: LocalizedStringKey {
    "Waiting for the last mirroring change to finish."
  }

  // MARK: - Failures

  /// Never overclaims: it says what was asked for and what did not happen.
  static var applyFailure: LocalizedStringKey {
    "The mirroring change did not take effect, and nothing was altered."
  }

  static var resolveFailure: LocalizedStringKey {
    "Mirroring could not be undone. Nothing retries this on its own. Try again."
  }

  /// A break that LEFT SOMETHING BEHIND.
  ///
  /// `MirrorToggleDecision.disengage` carries `residualMembers` for this
  /// sentence: a locked slave keeps mirroring, which keeps its master a master,
  /// so the set is only partly broken. Ignoring the residue would report
  /// "mirroring off" over a set the user is still looking at.
  ///
  /// Names the survivors only when every one can be named: an unnameable display
  /// is exactly the kind that gets locked into a set (Sidecar, an AirPlay
  /// receiver), and half a list reads as a bug rather than a report.
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
    guard !slaves.isEmpty else { return Self.notMirroredText }
    return slaves.count == 1
      ? "Mirrored to 1 display"
      : "Mirrored to \(slaves.count) displays"
  }
}
