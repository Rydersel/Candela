import CandelaKit
import Foundation

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
}
