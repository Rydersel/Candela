import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence the arrangement feature says, in one place, so the canvas and
/// the confirmation window cannot end up spelling one statement two ways.
enum ArrangementCopy {
  static var question: LocalizedStringKey { "Keep this arrangement?" }
  static var keep: LocalizedStringKey { "Keep" }
  static var revert: LocalizedStringKey { "Revert Now" }
  /// Derived, not a fixed string: a card reporting a change that was not
  /// achieved must not name a state the machine is not in.
  static func reportTitle(_ subject: ArrangementReportSubject) -> LocalizedStringKey {
    switch subject {
    case .nothingChanged:
      "Arrangement not changed"
    case .restoreFailed:
      // Says only what is known: whether the displays moved is exactly what
      // this case cannot tell.
      "Saved arrangement not restored"
    case .diverged:
      "Arrangement changed unexpectedly"
    }
  }

  static func countdown(_ seconds: Int) -> String {
    seconds == 1 ? "Reverting in 1 second" : "Reverting in \(seconds) seconds"
  }

  /// Names the display the menu bar is on, the most consequential thing an
  /// arrangement change does: the menu bar and the Dock follow whichever display
  /// sits at the origin.
  ///
  /// Falls back to a count when `displayName` returns "", since "The menu bar is
  /// now on ." is worse than not saying it.
  static func previewSubtitle(displayCount: Int, mainDisplayName: String) -> String {
    let layout = displayCount == 1
      ? "1 display was moved."
      : "\(displayCount) displays are arranged."
    guard !mainDisplayName.isEmpty else { return layout }
    return "\(layout) The menu bar is on \(mainDisplayName)."
  }

  /// Says what has to move rather than "invalid", which tells the user
  /// nothing they can act on.
  ///
  /// `Text`, not `LocalizedStringKey`: the named variants interpolate a display's
  /// own name, and routing a runtime value through a lookup key would translate
  /// the user's hardware. Friendly-name resolution belongs to the surface, so the
  /// closure comes in; an unnamed sentence is the fallback when it has no name.
  static func invalidLayout(
    _ problems: [ArrangementProblem], name: (CGDirectDisplayID) -> String
  ) -> Text {
    // `ArrangementRules.problems` never mixes the two kinds: an overlap makes
    // every reachability answer meaningless, so it reports overlaps alone.
    let overlap = problems.lazy.compactMap { problem -> (CGDirectDisplayID, CGDirectDisplayID)? in
      if case let .overlap(first, second) = problem { return (first, second) }
      return nil
    }.first
    if let overlap {
      let names = [name(overlap.0), name(overlap.1)].filter { !$0.isEmpty }
      return names.count == 2
        ? Text(verbatim: "\(names[0]) and \(names[1]) overlap. Displays can touch, but they cannot cover each other.")
        : Text("Two displays overlap. Displays can touch, but they cannot cover each other.")
    }

    let stranded = problems.compactMap { problem -> CGDirectDisplayID? in
      if case let .disconnected(display) = problem { return display }
      return nil
    }
    if stranded.count == 1, !name(stranded[0]).isEmpty {
      return Text(verbatim: "\(name(stranded[0])) is not touching any other display. Every display has to share an edge with the rest.")
    }
    return Text("One or more displays are not touching the rest. Every display has to share an edge with the others.")
  }

  /// A `begin()` that failed. Nothing is outstanding, so there is nothing to
  /// keep or revert.
  static var applyFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not rearrange the displays."
  }

  /// A `confirm()`/`revert()`/expiry that threw. The preview is still on screen
  /// and nothing auto-retries, so this must invite another attempt.
  static var resolveFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not complete that change. The displays are still showing the preview. Try again."
  }

  /// Said only alongside `resolveFailure`: the countdown is spent, so the user
  /// is now the only thing that can end this.
  static var expiryAlreadyRan: LocalizedStringKey {
    "The countdown has already run, so nothing will undo this on its own."
  }

  /// macOS accepted the request, reported success, and produced a different
  /// layout, so "it failed" is the wrong statement to make. Offer the way back.
  static var divergedOffer: LocalizedStringKey {
    "The displays did not end up where they were asked to go. \(AppInfo.productName) can put them back the way they were."
  }

  static var restore: LocalizedStringKey { "Put Them Back" }

  /// Why a saved layout did not come back.
  ///
  /// Restore runs with nobody watching, so this is the only account the user
  /// gets. Every sentence names something they can act on.
  ///
  /// `Text` rather than `LocalizedStringKey` for `invalidLayout`'s reason: a
  /// runtime value routed through a lookup key would translate the user's
  /// hardware.
  static func restoreNotice(
    _ notice: ArrangementReapplyNotice, name: (CGDirectDisplayID) -> String
  ) -> Text {
    switch notice {
    case .ambiguousIdentity:
      // Deliberately does NOT name the displays: the refusal exists
      // because two of them are indistinguishable, so naming one would be the
      // guess this refuses to make.
      Text("Two of your displays report the same identity, so \(AppInfo.productName) cannot tell which saved position belongs to which. The arrangement was left as it is.")
    case .setDiffers:
      Text("The saved arrangement is for a different set of displays, so it was not restored.")
    case .savedForDifferentGeometry:
      // A display that resized since the layout was saved is the ordinary cause,
      // and origins recorded for the old size cannot go back on the new one.
      // Deliberately unnamed: naming one screen reads as an accusation about it.
      Text("Your displays are not the size they were when this arrangement was saved, so it was not restored. Arrange them again to save a new one.")
    case let .layoutNoLongerFits(problems):
      // The same sentence the interactive refusal uses, for the same fact:
      // origins that do not tile at the sizes they were recorded at.
      invalidLayout(problems, name: name)
    case .failed:
      Text("\(AppInfo.productName) could not restore the saved arrangement.")
    }
  }

  /// macOS adjusts a requested layout silently, so the only trustworthy account
  /// of a change is the one read back. A pure translation is deliberately not
  /// reported.
  static func notice(_ notice: ArrangementApplyNotice, name: (CGDirectDisplayID) -> String) -> Text {
    switch notice {
    case .adjusted:
      Text("macOS moved some of the displays to a layout of its own. This is what is on screen now.")
    case let .mainDisplayUnchanged(display):
      name(display).isEmpty
        ? Text("The menu bar did not move to the display that was asked for.")
        : Text(verbatim: "The menu bar did not move to \(name(display)).")
    }
  }
}
