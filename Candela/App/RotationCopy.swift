import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence the rotation feature says, in one place, so the settings row
/// and the confirmation window cannot end up spelling one statement two ways.
enum RotationCopy {
  /// The hub row's label. Not "Orientation": the control sits in the Display
  /// section, where this word carries the topic.
  static var label: LocalizedStringKey { "Rotation" }

  /// The system's own wording. D25: familiarity beats novelty, and "Portrait"
  /// and "Landscape" would be a second vocabulary for the same values, wrong for
  /// an already-portrait panel.
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

  // No row caption for the countdown or for persistence: the confirmation window
  // states the countdown itself, and persistence is macOS's own behaviour here.

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

  /// Every refusal states its own reason. No `default:` arm: a new
  /// `RotationRefusal` case is a compile error rather than a generic sentence.
  ///
  /// `unchanged` is here for exhaustiveness and never shown; the coordinator
  /// returns early on it.
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

  /// The RT8 case, worth its own sentence: macOS accepted the change, reported
  /// success, and the display did not move. "It failed" is the wrong shape of
  /// statement for a call that returned no error.
  static var resolveFailure: LocalizedStringKey {
    "The display could not be rotated back. Nothing retries this on its own. Try again."
  }
}
