import CandelaKit
import Foundation

/// The panel's "All displays" row: one slider driving every display it
/// commands to one shared value, resting at their mean.
///
/// Absolute, not delta: a drag writes the handle's value to every participant,
/// so mid-drag the mean is the handle. A delta scheme keeps relative offsets
/// only until clamping erodes them, and then the handle has no honest resting
/// place. No fade yet; that decision is still open, so this snaps like every
/// other brightness change in the app.
enum CombinedBrightness {
  /// Skips displays with keyboard control off, the same opt-out the all-screens
  /// key path honours, so one "everything" control never commands what the other skips.
  @MainActor
  static func participants(
    builtIn: AppModel.DisplayState?,
    externals: [AppModel.DisplayState],
    prefs: (String) -> DisplayPrefs
  ) -> [AppModel.DisplayState] {
    ([builtIn].compactMap { $0 } + externals)
      .filter { !prefs($0.display.persistenceKey).isDisabled }
  }

  /// Below two participants the row would duplicate the slider under it.
  static func shows(participantCount: Int, appPrefs: DisplayPrefs) -> Bool {
    participantCount >= 2 && !appPrefs.hideCombinedBrightness
  }

  /// 0 with no participants, so a row briefly rendered over an emptied set does not read NaN.
  static func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
  }
}
