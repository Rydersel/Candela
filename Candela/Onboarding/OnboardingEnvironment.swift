import Foundation

/// The value snapshot the guided setup flow is derived from (OB2). Assembled
/// from `AppModel` and `DisplayModeCoordinator` in live mode, from a fixture in
/// mock mode and tests; the flow itself never reaches past this type.
struct OnboardingEnvironment: Equatable, Sendable {
  var accessibilityGranted: Bool
  var loginItemEnabled: Bool
  /// OB13: a first run arrives with launch at login checked as the presented
  /// recommendation; a re-run arrives at the live registration state.
  var isFirstRun: Bool
  var displays: [OnboardingDisplayEntry]
}

/// One external display as the flow sees it. Everything here is presentation
/// input; commits go through the flow model's seam, never through this value.
struct OnboardingDisplayEntry: Equatable, Sendable, Identifiable {
  /// How the display reported volume support. Drives OB9's positive phrasing:
  /// what works is stated, what the display itself declined is stated as the
  /// display's own report, and unknown is never described as failure.
  enum VolumeSupport: Equatable, Sendable {
    case works
    case declinedByDisplay
    case unknown
  }

  var persistenceKey: String
  /// The name shown and renamed in the flow (the friendly name when one is
  /// set, else the product name).
  var name: String
  /// The display's own reported product name. The OLED preselection (OB4)
  /// reads THIS, never the user's rename.
  var productName: String
  /// Panel-native pixels, manufactured orientation.
  var nativePixelWidth: Int
  var nativePixelHeight: Int
  /// 0, 90, 180 or 270. The glyph draws the display as mounted.
  var rotationDegrees: Int
  var diagonalInches: Double?
  var currentLooksLikeWidth: Int
  var currentLooksLikeHeight: Int
  /// The FASTEST rate the display offers, not the one it is running: the
  /// detection card reads it as a capability.
  var refreshHz: Double
  var volume: VolumeSupport
  /// The recommendation, already filtered upstream: nil when the engine
  /// abstained or the display is already at the best size, so a size page
  /// existing at all is OB8's decision made before the flow begins.
  var sizeSuggestion: OnboardingSizeSuggestion?
  var enrolledInCare: Bool
  /// The stored telemetry choice, meaningful only alongside `enrolledInCare`: a
  /// re-run seeds the measurement choice from it instead of silently
  /// re-recommending measured. Defaulted to the pref's own unwritten value so
  /// fixtures carry no decision.
  var measuredTelemetry: Bool = false

  var id: String { persistenceKey }

  /// Aspect ratio as mounted: rotation swaps the drawn axes.
  var drawnAspect: Double {
    let rotated = rotationDegrees == 90 || rotationDegrees == 270
    let w = Double(rotated ? nativePixelHeight : nativePixelWidth)
    let h = Double(rotated ? nativePixelWidth : nativePixelHeight)
    return h == 0 ? 1 : w / h
  }
}

/// A recommended looks-like size plus the compact curated list behind
/// "Choose Another".
struct OnboardingSizeSuggestion: Equatable, Sendable {
  struct Choice: Equatable, Sendable, Identifiable {
    var looksLikeWidth: Int
    var looksLikeHeight: Int
    var isHiDPI: Bool
    var id: String { "\(looksLikeWidth)x\(looksLikeHeight)" }
  }

  var looksLikeWidth: Int
  var looksLikeHeight: Int
  var alternatives: [Choice]
}
