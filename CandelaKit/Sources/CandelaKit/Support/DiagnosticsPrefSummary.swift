import Foundation

/// The non-default per-display settings that go into a diagnostics report.
///
/// Emits bare `PrefName` raw values, never the composed `"<name>.<persistenceKey>"`
/// storage keys: a persistence key is an EDID UUID or `name-manufacturer-serial`,
/// so naming a setting by its storage key would paste the display's serial into a
/// public report.
public enum DiagnosticsPrefSummary {
  /// `remembersMode` comes from the caller: it lives in `ModePersistence`, keyed
  /// by display CONFIG identity rather than this `DisplayPrefs`'s persistence key.
  public static func nonDefaultPrefs(_ prefs: DisplayPrefs, remembersMode: Bool) -> [String] {
    var lines: [String] = []
    func note(_ name: PrefName, _ value: String) { lines.append("\(name.rawValue) = \(value)") }
    /// The command qualifies scope, not identity: several commands share one pref
    /// name. Safe to include, being a fixed vocabulary with nothing display-derived.
    func noteCommand(_ name: PrefName, _ command: DDCCommand, _ value: String) {
      lines.append("\(name.rawValue).\(command.rawValue) = \(value)")
    }

    // A name cleared to whitespace is unset, same rule as the panel title.
    // Reporting it would describe a rename that is not in effect.
    let friendlyName = DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName)
    if !friendlyName.isEmpty { note(.friendlyName, friendlyName) }
    if prefs.hideDisplay { note(.hideDisplay, "true") }
    if prefs.isDisabled { note(.isDisabled, "true") }
    if prefs.hideVolumeSlider { note(.hideVolumeSlider, "true") }
    if prefs.hideOsd { note(.hideOsd, "true") }
    if prefs.forceSoftware { note(.forceSw, "true") }
    if prefs.avoidGamma { note(.avoidGamma, "true") }
    if prefs.combinedSwitchingPoint != 0 {
      note(.combinedSwitchingPoint, "\(prefs.combinedSwitchingPoint)")
    }
    if prefs.enableMuteUnmute { note(.enableMuteUnmute, "true") }
    if prefs.audioSinkOverride != .auto { note(.audioSinkOverride, "\(prefs.audioSinkOverride)") }
    if !prefs.audioDeviceNameOverride.isEmpty {
      note(.audioDeviceNameOverride, prefs.audioDeviceNameOverride)
    }
    if prefs.pollingMode != .normal { note(.pollingMode, "\(prefs.pollingMode)") }
    if prefs.pollingCount != 0 { note(.pollingCount, "\(prefs.pollingCount)") }
    if remembersMode { note(.rememberDisplayMode, "true") }
    // Answers "the app never suggested a size here". Without it, a dismissed
    // suggestion is indistinguishable from the density model abstaining.
    if prefs.sizeRecommendationDismissed { note(.sizeRecommendationDismissed, "true") }
    // The synthesized-sizes opt-in, reported because it explains a size list the
    // panel never advertised. The stored stop stays out, like `storedDisplayMode`:
    // the size in force belongs in the mode line.
    if prefs.offerSyntheticSizes { note(.offerSyntheticSizes, "true") }

    // The comparison values are the accessor defaults (the Recommended preset),
    // pinned by `oledDefaultsAreTheRecommendedPreset`: change the preset and that
    // test fails first.
    if prefs.oledCareEnrolled { note(.oledCareEnrolled, "true") }
    if prefs.oledIdleDimSeconds != 300 { note(.oledIdleDimSeconds, "\(prefs.oledIdleDimSeconds)") }
    if prefs.oledIdleDimBrightness != 0.5 {
      note(.oledIdleDimLevel, dimLevel(brightness: prefs.oledIdleDimBrightness))
    }
    if !prefs.oledLockDim { note(.oledLockDim, "false") }
    if prefs.oledBlackoutEnabled { note(.oledBlackoutEnabled, "true") }
    if prefs.oledBlackoutSeconds != 1200 { note(.oledBlackoutSeconds, "\(prefs.oledBlackoutSeconds)") }
    if prefs.oledUnfocusedDimEnabled { note(.oledUnfocusedDimEnabled, "true") }
    if prefs.oledUnfocusedDimSeconds != 600 {
      note(.oledUnfocusedDimSeconds, "\(prefs.oledUnfocusedDimSeconds)")
    }
    if prefs.oledUnfocusedDimBrightness != 0.7 {
      note(.oledUnfocusedDimLevel, dimLevel(brightness: prefs.oledUnfocusedDimBrightness))
    }
    if !prefs.oledHoursTracking { note(.oledHoursTracking, "false") }
    // Opposite defaults: telemetry stays off until the user grants it at the
    // toggle, never through enrollment. Window observation defaults on, stores inverted.
    if prefs.oledTelemetry { note(.oledTelemetry, "true") }
    if !prefs.oledWindowObservation { note(.oledWindowObservation, "false") }
    // The only care feature that alters the screen during active use, so a reader
    // triaging "it dims patches while I work" needs to see that it is on.
    if prefs.oledDetectionDimming { note(.oledDetectionDimming, "true") }

    for command in DDCCommand.allCases {
      let tuning = prefs.tuning(for: command)
      guard tuning != .unset else { continue }
      if tuning.unavailableDDC { noteCommand(.unavailableDDC, command, "true") }
      if tuning.minDDCOverride != DDCOverrideValidation.unset {
        noteCommand(.minDDCOverride, command, "\(tuning.minDDCOverride)")
      }
      if tuning.maxDDCOverride != DDCOverrideValidation.unset {
        noteCommand(.maxDDCOverride, command, "\(tuning.maxDDCOverride)")
      }
      // `DimmingMath.curveMultiplier` treats 0 (unset) and 5 alike, so neither
      // is a departure from the default.
      if tuning.curveIndex != 0, tuning.curveIndex != 5 {
        noteCommand(.curveDDC, command, "\(tuning.curveIndex)")
      }
      if tuning.invert { noteCommand(.invertDDC, command, "true") }
      if !tuning.remapCodes.isEmpty {
        // Hex, matching `setTuning` and the Advanced page: a decimal report
        // could not be pasted back.
        noteCommand(
          .remapDDC, command,
          tuning.remapCodes.map { String(format: "%02x", $0) }.joined(separator: ", ")
        )
      }
    }

    return lines
  }

  /// Both numbers a reader may be holding: the stored dim amount the key is named
  /// for, and the brightness the panel is left at, which is what the pane showed.
  /// Naming one under the other made a reader conclude the report and the domain
  /// disagreed. Percent-formatted because `1 - stored` gives 0.09999999999999998
  /// for 0.9, and binary noise in a pasted report reads as a bug.
  private static func dimLevel(brightness: Double) -> String {
    "\(SliderSnap.percentText(1 - brightness)) (leaves \(SliderSnap.percentText(brightness)) brightness)"
  }
}
