import CandelaKit
import Foundation
import SwiftUI

/// Why OLED care is paused on a display. One engine state (`.suspended`) with
/// several causes, and every surface that reports it has to name which: a
/// person who never mirrored anything must not be told they did.
enum OledCareSuspensionReason: Equatable, CaseIterable {
  /// Mirroring the user set up.
  case mirrored
  /// The mirror Candela engages to render a synthesized size (SS8).
  case synthesizedSize
  case checkup
}

/// The words for the care states whose reason is not visible in the state
/// itself: a lock dim that did not happen, and a pause whose cause the user may
/// never have asked for.
///
/// Shared rather than repeated (OC7 sub-ruling 4): a skip is "recorded, never
/// reported as dimmed", and when two private switches kept that rule both
/// surfaces printed "Dimmed" for a display the policy had refused.
///
/// Every lock-dim string here is written for a display that IS locked: the skip
/// map only carries live refusals, cleared the moment the dim engages.
enum OledCareCopy {
  /// The OLED Care pane's status row: full sentence, names the reason.
  static func lockDimStatus(_ skip: LockDimSkip?) -> LocalizedStringKey {
    switch skip {
    case nil: "Dimmed: the screen is locked"
    case .nothingDrivesBrightness:
      "Locked, not dimmed: nothing here controls this display's brightness"
    case .outsideSoftwareBand:
      "Locked, not dimmed: dimming would not change anything at this brightness"
    case .alreadyAtTarget:
      "Locked, not dimmed: the display is already this dark"
    }
  }

  /// The OLED Care pane's status row for OC13's pause. One state under every
  /// reason, so the row names which rather than telling a user they mirrored
  /// something they did not. No arm ends in a period, matching every
  /// neighbouring status string.
  static func suspendedStatus(reason: OledCareSuspensionReason) -> LocalizedStringKey {
    switch reason {
    case .mirrored: "Paused while this display is mirrored"
    case .synthesizedSize: "Paused while a synthesized size is active"
    case .checkup: "Paused while a checkup field is showing"
    }
  }

  /// The summary tile's short form of the same pause. It keeps its reason where
  /// the lock-dim preview drops one: "Paused" alone would leave the overview
  /// page saying nothing about a mirror the user never made.
  static func suspendedPreview(reason: OledCareSuspensionReason) -> String {
    switch reason {
    case .mirrored: "Paused while mirrored"
    case .synthesizedSize: "Paused for a synthesized size"
    case .checkup: "Paused for a checkup"
    }
  }

  /// The hub's spoken preview of the pause, carrying the reason its two-word
  /// sighted neighbour leaves to the pane. Word for word like the status row and
  /// a SEPARATE builder anyway: deriving either from the other would make the
  /// next edit to one silently an edit to both.
  static func suspendedSpokenPreview(reason: OledCareSuspensionReason) -> String {
    switch reason {
    case .mirrored: "Paused while this display is mirrored"
    case .synthesizedSize: "Paused while a synthesized size is active"
    case .checkup: "Paused while a checkup field is showing"
    }
  }

  /// What the two halves of the usage histogram count, said out loud because
  /// they do not count the same thing.
  ///
  /// OC17's denominator is MASK-COULD-APPLY time: suspended seconds are excluded
  /// from the percentage, because a protective dim cannot apply during them. The
  /// bars exclude nothing, so without this a reader takes the percentage for a
  /// share of the bars.
  static var wearFractionScope: String {
    "The bars cover every state this display was tracked in. The percentage covers only the time a protective dim could apply."
  }

  /// The hub's SO3 value preview: two words, and it defers the reason to the
  /// pane exactly as "Paused" already does.
  static func lockDimPreview(_ skip: LockDimSkip?) -> String {
    skip == nil ? "Dimmed" : "Not dimmed"
  }

  /// The hub's spoken preview, which carries the reason the sighted preview
  /// leaves to the pane.
  static func lockDimSpokenPreview(_ skip: LockDimSkip?) -> String {
    switch skip {
    case nil: "Dimmed, the screen is locked"
    case .nothingDrivesBrightness:
      "Locked but not dimmed, nothing here controls this display's brightness"
    case .outsideSoftwareBand:
      "Locked but not dimmed, dimming would not change anything at this brightness"
    case .alreadyAtTarget:
      "Locked but not dimmed, the display is already this dark"
    }
  }
}
