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

  /// `.setCannotBeBroken`. Named, never a bare grey (R8 generalised: no state is
  /// carried by shape alone).
  static var cannotBeUnmirrored: LocalizedStringKey {
    "macOS keeps this display mirrored and will not let it be separated."
  }

  /// `.notInASet`. A fourth refusal rather than an empty `setCannotBeBroken`
  /// payload, so the UI never says "this set cannot be broken" about a display
  /// that has no set.
  static var notInASet: LocalizedStringKey {
    "This display is not mirroring anything."
  }

  /// One sentence for whichever refusal happened, so every surface makes the
  /// same statement about the same refusal.
  static func refusal(_ refusal: MirrorRefusal) -> LocalizedStringKey {
    switch refusal {
    case .onlyOneDisplay: needsASecondDisplay
    case .noEligibleMaster: noEligibleMaster
    case .noSuchDisplay: noSuchDisplay
    case .masterIsAlwaysMirrored: masterIsAlwaysMirrored
    case .nothingToMirror: nothingToMirror
    case .setCannotBeBroken: cannotBeUnmirrored
    case .notInASet: notInASet
    }
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
