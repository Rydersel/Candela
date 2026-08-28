import CandelaKit
import Foundation

/// The panel's "All displays" row: one slider that drives every display it
/// commands to one shared value, and rests at their mean.
///
/// Absolute, not delta (the reference implementation's answer, adopted): a
/// drag writes the handle's value to every participant, so mid-drag the mean
/// IS the handle and there is nothing to suppress. A delta scheme would keep
/// the displays' relative offsets, but clamping at either end erodes those
/// offsets anyway and the handle then has no honest resting place.
///
/// No fade: the fade question is open on its own issue, and until it is
/// settled this snaps like every other brightness change in the app.
enum CombinedBrightness {
  /// The displays the row commands: the built-in when the panel shows it, then
  /// the externals the panel renders, minus any display whose keyboard
  /// control is off. The same opt-out the all-screens key path honours, so a
  /// display the user excluded from one "everything" control is excluded from
  /// the other.
  @MainActor
  static func participants(
    builtIn: AppModel.DisplayState?,
    externals: [AppModel.DisplayState],
    prefs: (String) -> DisplayPrefs
  ) -> [AppModel.DisplayState] {
    ([builtIn].compactMap { $0 } + externals)
      .filter { !prefs($0.display.persistenceKey).isDisabled }
  }

  /// Fewer than two participants and the row duplicates the slider under it,
  /// so it is absent rather than redundant. The pref hides it on top of that.
  static func shows(participantCount: Int, appPrefs: DisplayPrefs) -> Bool {
    participantCount >= 2 && !appPrefs.hideCombinedBrightness
  }

  /// Arithmetic mean of the participants' current brightness; 0 with none, so
  /// a row briefly rendered over an emptied set cannot divide by zero.
  static func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
  }
}
