import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence the rotation feature says, in one place, so the settings row
/// and the confirmation window cannot end up spelling one statement two ways.
enum RotationCopy {
  /// The hub row's label (spec §4 renamed it from "Orientation:" when the
  /// control moved into the Display section, where the word carries the topic).
  static var label: LocalizedStringKey { "Rotation" }

  /// The system's own wording. System Settings offers Standard / 90° / 180° /
  /// 270°, and D25 says familiarity beats novelty — "Portrait" and "Landscape"
  /// would be a second vocabulary for the same four values, and would be wrong
  /// for an already-portrait panel.
  static func angle(_ rotation: DisplayRotation) -> LocalizedStringKey {
    LocalizedStringKey(angleText(rotation))
  }

  /// The same four words, for the `String`-returning surfaces.
  private static func angleText(_ rotation: DisplayRotation) -> String {
    switch rotation {
    case .standard: "Standard"
    case .ninety: "90°"
    case .oneEighty: "180°"
    case .twoSeventy: "270°"
    }
  }

  // The old row captions (the thirty-second countdown and the RT11 persistence
  // note) were retired with the hub restructure (spec §4): the countdown is
  // runtime feedback the confirmation window states itself, and persistence is
  // macOS's own behaviour for this control, matching System Settings.

  static var unavailable: LocalizedStringKey {
    "This version of macOS does not expose display rotation to Candela."
  }

  static var question: LocalizedStringKey { "Keep this orientation?" }
  static var keep: LocalizedStringKey { "Keep" }
  static var revert: LocalizedStringKey { "Revert Now" }
  static var reportTitle: LocalizedStringKey { "Display not rotated" }

  static func countdown(_ seconds: Int) -> String {
    seconds == 1 ? "Reverting in 1 second" : "Reverting in \(seconds) seconds"
  }

  /// The subtitle under the question: which display, and to what.
  static func previewSubtitle(name: String, to rotation: DisplayRotation) -> String {
    let angle = angleText(rotation)
    return name.isEmpty ? angle : "\(name): \(angle)"
  }

  /// Every refusal states its own reason. No `default:` arm — a new
  /// `RotationRefusal` case is a compile error here rather than a silently
  /// generic sentence.
  ///
  /// `unchanged` is present for exhaustiveness but is never shown: the
  /// coordinator returns early on it, because telling someone "no" when the
  /// display is already where they asked for it is a dialog with nothing to say.
  static func refusal(_ refusal: RotationRefusal) -> LocalizedStringKey {
    switch refusal {
    case .unavailable: unavailable
    case .displayGone: "That display disconnected before the change could be made."
    case .unreadable: "This display reports an orientation Candela does not recognise, so it will not offer to change it."
    case .unchanged: "That display is already in this orientation."
    }
  }

  static var applyFailure: LocalizedStringKey {
    "The display did not rotate, and nothing was changed."
  }

  /// The RT8 case, and it is worth its own sentence: macOS accepted the change
  /// and reported success, and the display did not move. "It failed" would be
  /// the wrong shape of statement for a call that returned no error.
  static var resolveFailure: LocalizedStringKey {
    "The display could not be rotated back. Nothing retries this on its own. Try again."
  }
}
