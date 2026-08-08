import Foundation

/// The non-default per-display settings that go into a diagnostics report.
///
/// This is the code the report's PII contract actually rests on. The names it
/// emits are `PrefName` raw values — the BARE key names — and never the keys
/// `DisplayPrefs` composes, because a stored key is `"<name>.<persistenceKey>"`
/// and `DisplayDiscovery.persistenceKey(from:)` returns an EDID UUID or
/// `name-manufacturer-serial`. Naming settings by their storage keys would put
/// the display's serial into every pasted report, straight past the `hasSerial`
/// flag on `DiagnosticsReportSnapshot` that exists to keep it out of public
/// issues. `noEmittedLineCarriesAComposedStorageKey` pins that over every line
/// the summary produces, for both real key shapes.
///
/// That covers every line the FIXTURE provokes, which is not the same as every
/// pref — a setting added below emits nothing unless someone also sets it in the
/// fixture, and for a while this comment claimed otherwise. What closes the gap
/// is `theFixtureCoversEveryPerDisplayPrefName`, which derives both sides from
/// `PrefName.allCases`: a new case is neither reported nor explicitly excluded,
/// so it fails until someone classifies it. Add a pref here and the suite tells
/// you what else to do.
///
/// It lives in the Kit, not beside the page that calls it, for the same reason:
/// a contract held by review alone is a contract until someone is in a hurry.
public enum DiagnosticsPrefSummary {
  /// `remembersMode` arrives from the caller because the flag lives in
  /// `ModePersistence`, keyed by display CONFIG identity rather than by the
  /// persistence key this `DisplayPrefs` is built on — the two are different
  /// keys and only the caller holds both.
  public static func nonDefaultPrefs(_ prefs: DisplayPrefs, remembersMode: Bool) -> [String] {
    var lines: [String] = []
    func note(_ name: PrefName, _ value: String) { lines.append("\(name.rawValue) = \(value)") }
    /// The command is SCOPE, not identity: three commands share one pref name,
    /// so dropping it would print three different settings under one name. It
    /// is also the one component of a storage key that is safe to keep — a
    /// fixed vocabulary, nothing display-derived.
    func noteCommand(_ name: PrefName, _ command: DDCCommand, _ value: String) {
      lines.append("\(name.rawValue).\(command.rawValue) = \(value)")
    }

    // Same rule the panel title uses: a name cleared to whitespace is unset,
    // and reporting it would describe a rename that is not in effect.
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

    // OLED care (W3a). The comparison values ARE the accessor defaults — the
    // Recommended preset, pinned by `oledDefaultsAreTheRecommendedPreset` — so
    // a preset change fails that test first and points here. Churn bugs in the
    // care dim are exactly the reports where "enrolled, blackout on, idle dim
    // at 60 s" is the line that explains everything.
    if prefs.oledCareEnrolled { note(.oledCareEnrolled, "true") }
    if prefs.oledIdleDimSeconds != 300 { note(.oledIdleDimSeconds, "\(prefs.oledIdleDimSeconds)") }
    // Reported as the BRIGHTNESS-while-dimmed the user set (0.1 darkest), not
    // as the overlay opacity the key stores, which is its complement. A report
    // read next to `defaults read` will disagree with it by design; the number
    // here is the one the pane showed, which is what a bug report is about.
    if prefs.oledIdleDimBrightness != 0.5 {
      note(.oledIdleDimLevel, "\(prefs.oledIdleDimBrightness) brightness")
    }
    if !prefs.oledLockDim { note(.oledLockDim, "false") }
    if prefs.oledBlackoutEnabled { note(.oledBlackoutEnabled, "true") }
    if prefs.oledBlackoutSeconds != 1200 { note(.oledBlackoutSeconds, "\(prefs.oledBlackoutSeconds)") }
    if prefs.oledUnfocusedDimEnabled { note(.oledUnfocusedDimEnabled, "true") }
    if prefs.oledUnfocusedDimSeconds != 600 {
      note(.oledUnfocusedDimSeconds, "\(prefs.oledUnfocusedDimSeconds)")
    }
    if prefs.oledUnfocusedDimBrightness != 0.7 {
      note(.oledUnfocusedDimLevel, "\(prefs.oledUnfocusedDimBrightness) brightness")
    }
    if !prefs.oledHoursTracking { note(.oledHoursTracking, "false") }
    // W3b-1's two. Opposite defaults, so opposite tests: telemetry is OFF until
    // the user grants it at the toggle (never as a side effect of enrollment),
    // while window observation needs no permission, is the degraded mode's only
    // data source, and so defaults ON and stores inverted.
    if prefs.oledTelemetry { note(.oledTelemetry, "true") }
    if !prefs.oledWindowObservation { note(.oledWindowObservation, "false") }
    // W3b-2's one. Off by default and the only care feature that alters the
    // screen during active use, so its being ON is exactly the kind of thing a
    // diagnostics reader needs to see when someone reports the display dimming
    // patches while they work.
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
        // Hex, matching how `setTuning` writes them and how the Advanced page
        // takes them — a decimal report could not be pasted back.
        noteCommand(
          .remapDDC, command,
          tuning.remapCodes.map { String(format: "%02x", $0) }.joined(separator: ", ")
        )
      }
    }

    return lines
  }
}
