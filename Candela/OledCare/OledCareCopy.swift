import CandelaKit
import Foundation
import SwiftUI

/// The words for a lock dim that did not happen.
///
/// OC7 sub-ruling 4 is the reason this is shared rather than repeated: a skip is
/// "recorded, never reported as dimmed", and both surfaces that report lock dim
/// (the OLED Care pane's status row, the display hub's care preview) printed
/// "Dimmed" for a display the policy had refused. A rule kept by two private
/// switches is a rule that drifts the first time one of them is edited.
///
/// Every string here is written for a display that IS locked: the skip map only
/// carries live refusals, cleared the moment the dim engages.
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
