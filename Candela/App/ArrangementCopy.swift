import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence the arrangement feature says, in one place, so the canvas and
/// the confirmation window cannot end up spelling one statement two ways.
enum ArrangementCopy {
  static var question: LocalizedStringKey { "Keep this arrangement?" }
  static var keep: LocalizedStringKey { "Keep" }
  static var revert: LocalizedStringKey { "Revert Now" }
  static var reportTitle: LocalizedStringKey { "Arrangement not changed" }

  static func countdown(_ seconds: Int) -> String {
    seconds == 1 ? "Reverting in 1 second" : "Reverting in \(seconds) seconds"
  }

  /// The subtitle under the question. It names the display the menu bar is on,
  /// because that is the single most consequential thing an arrangement change
  /// does — the menu bar and the Dock follow whichever display sits at the
  /// origin, and moving it is how someone loses track of where their screen is.
  ///
  /// Falls back to a count when the display cannot be named: `displayName`
  /// returns "" for a display no surface has a name for, and "The menu bar is
  /// now on ." is worse than not saying it.
  static func previewSubtitle(displayCount: Int, mainDisplayName: String) -> String {
    let layout = displayCount == 1
      ? "1 display was moved."
      : "\(displayCount) displays are arranged."
    guard !mainDisplayName.isEmpty else { return layout }
    return "\(layout) The menu bar is on \(mainDisplayName)."
  }

  /// AR7. Says what has to move rather than "invalid", which tells the user
  /// nothing they can act on.
  static func invalidLayout(_ problems: [ArrangementProblem], name: (CGDirectDisplayID) -> String) -> LocalizedStringKey {
    let overlaps = problems.compactMap { problem -> (CGDirectDisplayID, CGDirectDisplayID)? in
      if case let .overlap(first, second) = problem { return (first, second) }
      return nil
    }
    if let first = overlaps.first {
      let names = [name(first.0), name(first.1)].filter { !$0.isEmpty }
      return names.count == 2
        ? "\(names[0]) and \(names[1]) overlap. Displays can touch, but they cannot cover each other."
        : "Two displays overlap. Displays can touch, but they cannot cover each other."
    }
    let stranded = problems.compactMap { problem -> CGDirectDisplayID? in
      if case let .disconnected(display) = problem { return display }
      return nil
    }
    if stranded.count == 1, !name(stranded[0]).isEmpty {
      return "\(name(stranded[0])) is not touching any other display. Every display has to share an edge with the rest."
    }
    return "One or more displays are not touching the rest. Every display has to share an edge with the others."
  }

  /// A `begin()` that failed. Nothing is outstanding, so there is nothing to
  /// keep or revert.
  static var applyFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not rearrange the displays."
  }

  /// A `confirm()`/`revert()`/expiry that threw. The preview is still on screen
  /// and nothing auto-retries, so this must invite another attempt.
  static var resolveFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not complete that change. The displays are still showing the preview — try again."
  }

  /// Said only alongside `resolveFailure`: the countdown is spent, so the user
  /// is now the only thing that can end this.
  static var expiryAlreadyRan: LocalizedStringKey {
    "The countdown has already run, so nothing will undo this on its own."
  }

  /// The #53 case, held open by the coordinator. macOS accepted the request,
  /// reported success, and produced a different layout — so "it failed" is the
  /// wrong shape of statement, and the useful thing to offer is the way back.
  static var divergedOffer: LocalizedStringKey {
    "The displays did not end up where they were asked to go. \(AppInfo.productName) can put them back the way they were."
  }

  static var restore: LocalizedStringKey { "Put Them Back" }

  /// §6.3. macOS adjusts a requested layout silently, so the only trustworthy
  /// account of a change is the one read back — and a notice about it is only
  /// worth showing because a pure translation is deliberately NOT reported.
  static func notice(_ notice: ArrangementApplyNotice, name: (CGDirectDisplayID) -> String) -> LocalizedStringKey {
    switch notice {
    case .adjusted:
      "macOS moved some of the displays to a layout of its own — this is what is on screen now."
    case let .mainDisplayUnchanged(display):
      name(display).isEmpty
        ? "The menu bar did not move to the display that was asked for."
        : "The menu bar did not move to \(name(display))."
    }
  }
}
