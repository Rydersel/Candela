import Foundation

/// One page of the guided setup flow. The list is always derived (OB2); views
/// render what the plan says and never decide what exists.
enum OnboardingPage: Equatable, Hashable, Identifiable {
  case welcome
  case accessibility
  case detection
  /// Shown instead of detection when no external display is connected: the
  /// slim flow's pivot page.
  case noDisplays
  /// One per display with an active size suggestion (OB8 suppresses the rest
  /// upstream, before the environment is built).
  case size(displayKey: String)
  case oledSelect
  /// Present only while at least one display is designated as an OLED.
  case oledCare
  case finish

  var id: String {
    switch self {
    case .welcome: "welcome"
    case .accessibility: "accessibility"
    case .detection: "detection"
    case .noDisplays: "noDisplays"
    case let .size(key): "size.\(key)"
    case .oledSelect: "oledSelect"
    case .oledCare: "oledCare"
    case .finish: "finish"
    }
  }
}

/// Pure derivation of the flow from an environment snapshot plus the one piece
/// of in-flow state that reshapes it (the OLED designation set). Tested in
/// CandelaAppTests; the flow model calls this and nothing else decides pages.
enum OnboardingPlan {
  static func pages(
    for environment: OnboardingEnvironment,
    designatedOleds: Set<String>
  ) -> [OnboardingPage] {
    // Displays lead: detection and the size suggestion are the payoff pages,
    // so they come before the permission ask (Ryder's ordering, 2026-08-19).
    var pages: [OnboardingPage] = [.welcome]
    if environment.displays.isEmpty {
      pages.append(.noDisplays)
    } else {
      pages.append(.detection)
      for display in environment.displays where display.sizeSuggestion != nil {
        pages.append(.size(displayKey: display.persistenceKey))
      }
    }
    pages.append(.accessibility)
    if !environment.displays.isEmpty {
      pages.append(.oledSelect)
      if environment.displays.contains(where: { designatedOleds.contains($0.persistenceKey) }) {
        pages.append(.oledCare)
      }
    }
    pages.append(.finish)
    return pages
  }

  /// OB4: a display whose reported product name contains "OLED" arrives
  /// preselected as a labeled guess. Case-insensitive, product name only; a
  /// user's rename never feeds the guess.
  static func suggestsOled(productName: String) -> Bool {
    productName.range(of: "oled", options: .caseInsensitive) != nil
  }

  /// The designation set a fresh flow starts from: the name guess plus
  /// anything already enrolled (a re-run arrives prefilled, OB7).
  static func initialDesignation(for environment: OnboardingEnvironment) -> Set<String> {
    Set(
      environment.displays
        .filter { $0.enrolledInCare || suggestsOled(productName: $0.productName) }
        .map(\.persistenceKey)
    )
  }
}
