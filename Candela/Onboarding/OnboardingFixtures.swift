#if DEBUG
  import Foundation

  /// The real rig as a committed snapshot, so the mock flow is clickable end to
  /// end with no pref writes and no display changes. Update it when the
  /// rig changes, or the mock stops matching what a run actually shows.
  enum OnboardingFixtures {
    static var rig: OnboardingEnvironment {
      OnboardingEnvironment(
        accessibilityGranted: false,
        loginItemEnabled: false,
        isFirstRun: true,
        displays: [
          OnboardingDisplayEntry(
            persistenceKey: "fixture-mag",
            name: "MAG 341CQPX QD-OLED",
            productName: "MAG 341CQPX QD-OLED",
            nativePixelWidth: 3440,
            nativePixelHeight: 1440,
            rotationDegrees: 0,
            diagonalInches: 34,
            currentLooksLikeWidth: 3440,
            currentLooksLikeHeight: 1440,
            refreshHz: 175,
            volume: .unknown,
            sizeSuggestion: nil,
            enrolledInCare: false
          ),
          OnboardingDisplayEntry(
            persistenceKey: "fixture-dell",
            name: "DELL U2725QE",
            productName: "DELL U2725QE",
            nativePixelWidth: 3840,
            nativePixelHeight: 2160,
            rotationDegrees: 270,
            diagonalInches: 27,
            currentLooksLikeWidth: 2160,
            currentLooksLikeHeight: 3840,
            refreshHz: 120,
            volume: .declinedByDisplay,
            sizeSuggestion: OnboardingSizeSuggestion(
              looksLikeWidth: 1440,
              looksLikeHeight: 2560,
              alternatives: [
                .init(looksLikeWidth: 2160, looksLikeHeight: 3840, isHiDPI: false),
                .init(looksLikeWidth: 1800, looksLikeHeight: 3200, isHiDPI: true),
                .init(looksLikeWidth: 1620, looksLikeHeight: 2880, isHiDPI: true),
                .init(looksLikeWidth: 1440, looksLikeHeight: 2560, isHiDPI: true),
                .init(looksLikeWidth: 1350, looksLikeHeight: 2400, isHiDPI: true),
                .init(looksLikeWidth: 1215, looksLikeHeight: 2160, isHiDPI: true),
                .init(looksLikeWidth: 1080, looksLikeHeight: 1920, isHiDPI: true),
                .init(looksLikeWidth: 810, looksLikeHeight: 1440, isHiDPI: true),
              ]
            ),
            enrolledInCare: false
          ),
        ]
      )
    }
  }
#endif
