import Testing

// The guided setup flow's derivation: pages come from the environment
// snapshot plus the in-flow OLED designation, never from view logic. These
// pins are the slim flow, the upstream size-suggestion suppression, and the
// name guess.
@Suite("Onboarding plan derivation")
struct OnboardingPlanTests {
  private func entry(
    key: String,
    productName: String = "Generic Display",
    suggestion: OnboardingSizeSuggestion? = nil,
    enrolled: Bool = false
  ) -> OnboardingDisplayEntry {
    OnboardingDisplayEntry(
      persistenceKey: key,
      name: productName,
      productName: productName,
      nativePixelWidth: 3840,
      nativePixelHeight: 2160,
      rotationDegrees: 0,
      diagonalInches: 27,
      currentLooksLikeWidth: 3840,
      currentLooksLikeHeight: 2160,
      refreshHz: 60,
      volume: .unknown,
      sizeSuggestion: suggestion,
      enrolledInCare: enrolled
    )
  }

  private func environment(_ displays: [OnboardingDisplayEntry]) -> OnboardingEnvironment {
    OnboardingEnvironment(
      accessibilityGranted: false, loginItemEnabled: false, isFirstRun: true,
      displays: displays)
  }

  private let suggestion = OnboardingSizeSuggestion(
    looksLikeWidth: 2560, looksLikeHeight: 1440, alternatives: [])

  @Test func slimFlowWithNoExternalDisplays() {
    let pages = OnboardingPlan.pages(for: environment([]), designatedOleds: [])
    #expect(pages == [.welcome, .noDisplays, .accessibility, .finish])
  }

  @Test func fullRigDerivesDetectionSizeAndDesignation() {
    // Displays lead the flow; the permission ask follows the size pages.
    let env = environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell", productName: "DELL U2725QE", suggestion: suggestion),
    ])
    let pages = OnboardingPlan.pages(for: env, designatedOleds: [])
    #expect(pages == [
      .welcome, .detection,
      .size(displayKey: "dell"),
      .accessibility,
      .oledSelect, .finish,
    ])
  }

  @Test func aDisplayWithoutASuggestionGetsNoSizePage() {
    let env = environment([entry(key: "mag")])
    let pages = OnboardingPlan.pages(for: env, designatedOleds: [])
    #expect(!pages.contains { if case .size = $0 { true } else { false } })
  }

  @Test func sizePagesFollowDisplayOrder() {
    let env = environment([
      entry(key: "a", suggestion: suggestion),
      entry(key: "b", suggestion: suggestion),
    ])
    let pages = OnboardingPlan.pages(for: env, designatedOleds: [])
    let sizeKeys: [String] = pages.compactMap {
      if case let .size(key) = $0 { key } else { nil }
    }
    #expect(sizeKeys == ["a", "b"])
  }

  @Test func designationAddsTheCarePage() {
    let env = environment([entry(key: "mag"), entry(key: "dell")])
    let without = OnboardingPlan.pages(for: env, designatedOleds: [])
    let with = OnboardingPlan.pages(for: env, designatedOleds: ["mag"])
    #expect(!without.contains(.oledCare))
    #expect(with.contains(.oledCare))
    // The care page sits between designation and finish.
    #expect(with.firstIndex(of: .oledCare)! > with.firstIndex(of: .oledSelect)!)
    #expect(with.last == .finish)
  }

  @Test func aStaleDesignationForAVanishedDisplayAddsNoCarePage() {
    // Mid-flow unplug: the designation set can hold a key the environment no
    // longer contains, and the plan must not build a care page for a ghost.
    let env = environment([entry(key: "dell")])
    let pages = OnboardingPlan.pages(for: env, designatedOleds: ["mag"])
    #expect(!pages.contains(.oledCare))
  }

  @Test func theNameGuessIsCaseInsensitiveAndSubstring() {
    #expect(OnboardingPlan.suggestsOled(productName: "MAG 341CQPX QD-OLED"))
    #expect(OnboardingPlan.suggestsOled(productName: "lg oled42c2"))
    #expect(OnboardingPlan.suggestsOled(productName: "Oled Panel Pro"))
    #expect(!OnboardingPlan.suggestsOled(productName: "DELL U2725QE"))
    #expect(!OnboardingPlan.suggestsOled(productName: ""))
  }

  @Test func initialDesignationCombinesGuessAndEnrollment() {
    let env = environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell", productName: "DELL U2725QE"),
      entry(key: "spare", productName: "Plain Monitor", enrolled: true),
    ])
    #expect(OnboardingPlan.initialDesignation(for: env) == ["mag", "spare"])
  }

  @Test func aRenameNeverFeedsTheGuess() {
    // The guess reads the reported product name, not the friendly name.
    var display = entry(key: "dell", productName: "DELL U2725QE")
    display.name = "My OLED Desk Display"
    let env = environment([display])
    #expect(OnboardingPlan.initialDesignation(for: env).isEmpty)
  }
}
