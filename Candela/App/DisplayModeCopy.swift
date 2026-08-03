import CandelaKit
import Foundation
import SwiftUI

/// The words every surface uses to name a display mode: the settings section,
/// the panel's resolution list, and the floating confirmation panel.
///
/// Shared rather than repeated because RM11 is a copy *rule* — "looks like",
/// never "true native HiDPI" — and a rule enforced in three private helpers is
/// a rule that drifts the first time one of them is edited.
enum DisplayModeCopy {
  /// RM11. On a fixed panel only one logical size is a true 2× of the native
  /// framebuffer; everything else renders oversized and downsamples, so the
  /// honest claim is about how big things look, not about what the panel is.
  static func size(_ mode: DisplayMode) -> String {
    "Looks like \(mode.logicalWidth) × \(mode.logicalHeight)"
  }

  /// Rates are quantized to one decimal at the CoreGraphics boundary, so 59.9
  /// is a real value and truncating it to "59 Hz" would both misreport it and
  /// collide with a genuine 59 Hz row.
  static func refresh(_ hz: Double) -> String {
    hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz)
  }

  static func countdown(_ seconds: Int) -> String {
    seconds == 1
      ? "Reverting to the previous resolution in 1 second."
      : "Reverting to the previous resolution in \(seconds) seconds."
  }

  // The three sentences below are shown by two surfaces each and are stated
  // once here for the same reason as the labels above: they agree today, and
  // agreement is not a property two literals keep. The CoreGraphics code stays
  // out of them deliberately — it is diagnostic, and belongs in a tooltip
  // rather than in a sentence someone has to read while their screen is wrong.

  // Computed, not stored: `LocalizedStringKey` is not `Sendable`, so a static
  // `let` of one is a concurrency error under complete checking. Each of these
  // is a literal with no state behind it.

  /// A `begin()` that failed. Nothing was applied, so nothing needs answering.
  static var startFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not switch this display. Nothing changed."
  }

  /// A `confirm()`/`revert()`/expiry that threw. The preview is still on the
  /// display and nothing auto-retries, so this must invite another attempt.
  static var resolveFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not complete that change. The display is still showing the preview — try again."
  }

  /// Said only alongside `resolveFailure`: the countdown is spent, so the user
  /// is now the only thing that can end this.
  static var expiryAlreadyRan: LocalizedStringKey {
    "The automatic revert has already run, so it will not try again on its own."
  }
}
