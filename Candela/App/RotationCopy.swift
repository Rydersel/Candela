import CandelaKit
import CoreGraphics
import SwiftUI

/// Every sentence the rotation feature says, in one place, so the settings row
/// and the confirmation window cannot end up spelling one statement two ways.
enum RotationCopy {
  static var sectionTitle: LocalizedStringKey { "Rotation" }
  static var label: LocalizedStringKey { "Orientation:" }

  /// The system's own wording. System Settings offers Standard / 90° / 180° /
  /// 270°, and D25 says familiarity beats novelty — "Portrait" and "Landscape"
  /// would be a second vocabulary for the same four values, and would be wrong
  /// for an already-portrait panel.
  static func angle(_ rotation: DisplayRotation) -> LocalizedStringKey {
    switch rotation {
    case .standard: "Standard"
    case .ninety: "90°"
    case .oneEighty: "180°"
    case .twoSeventy: "270°"
    }
  }

  static var caption: LocalizedStringKey {
    "Rotates the picture on the display itself. You get thirty seconds to keep it."
  }

  /// RT11, said plainly. This is the one place the difference from mirroring
  /// leaks into the user's world, and it must not be papered over: mirroring
  /// undoes itself if Candela dies, and a rotation does not.
  static var persistenceCaption: LocalizedStringKey {
    "macOS remembers a display's orientation, so this outlasts Candela — if the app quits while a display is rotated, it stays rotated. You can always change it back here or in System Settings."
  }

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
    let angle = switch rotation {
    case .standard: "Standard"
    case .ninety: "90°"
    case .oneEighty: "180°"
    case .twoSeventy: "270°"
    }
    return name.isEmpty ? angle : "\(name) — \(angle)"
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
    "The display could not be rotated back. Nothing retries this on its own — try again."
  }
}
