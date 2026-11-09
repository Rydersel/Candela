import Testing

// The guided setup flow's derivation: pages come from the environment
// snapshot plus the in-flow OLED designation, never from view logic. These
// pins are the slim flow, the keys page's presence, the upstream
// size-suggestion suppression, and the name guess.
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

  /// Defaults to the shipped key modes (the media keys, which want the event
  /// tap) with no grant, the state a first run arrives in.
  private func environment(
    _ displays: [OnboardingDisplayEntry],
    accessibilityGranted: Bool = false,
    keyModesRequireGrant: Bool = true
  ) -> OnboardingEnvironment {
    OnboardingEnvironment(
      accessibilityGranted: accessibilityGranted, loginItemEnabled: false, isFirstRun: true,
      keyModesRequireGrant: keyModesRequireGrant,
      arrangedDisplayCount: displays.count + 1,
      displays: displays)
  }

  /// The plan as the flow model composes it: the keys page's presence comes
  /// from the same environment the rest of the pages do.
  private func pages(
    _ environment: OnboardingEnvironment, designatedOleds: Set<String> = []
  ) -> [OnboardingPage] {
    OnboardingPlan.pages(
      for: environment, designatedOleds: designatedOleds,
      includesKeysPage: OnboardingPlan.wantsKeysPage(environment))
  }

  private let suggestion = OnboardingSizeSuggestion(
    looksLikeWidth: 2560, looksLikeHeight: 1440, alternatives: [])

  // MARK: - The keys page

  @Test func keysPageWhenAnExternalNeedsTheGrant() {
    let env = environment([entry(key: "mag")])
    #expect(OnboardingPlan.wantsKeysPage(env))
    #expect(pages(env).contains(.accessibility))
  }

  @Test func noKeysPageWhenAlreadyGranted() {
    let env = environment([entry(key: "mag")], accessibilityGranted: true)
    #expect(!OnboardingPlan.wantsKeysPage(env))
    #expect(!pages(env).contains(.accessibility))
  }

  /// Custom shortcuts are Carbon hotkeys and work without the grant, so a rig
  /// set to them has nothing for the page to ask for.
  @Test func noKeysPageForAllCustomShortcuts() {
    let env = environment([entry(key: "mag")], keyModesRequireGrant: false)
    #expect(!OnboardingPlan.wantsKeysPage(env))
    #expect(!pages(env).contains(.accessibility))
  }

  /// The keys control an external display, so with none attached the page has
  /// no subject, even though the modes want the tap and nothing is granted.
  @Test func noKeysPageInTheSlimFlow() {
    let env = environment([])
    #expect(!OnboardingPlan.wantsKeysPage(env))
    #expect(pages(env) == [.welcome, .noDisplays, .finish])
  }

  /// Presence is the caller's decision, passed in, so a latched answer holds
  /// whatever the environment now says.
  @Test func theKeysPageFollowsThePassedFlagNotTheEnvironment() {
    let granted = environment([entry(key: "mag")], accessibilityGranted: true)
    #expect(OnboardingPlan.pages(
      for: granted, designatedOleds: [], includesKeysPage: true).contains(.accessibility))
    let wanted = environment([entry(key: "mag")])
    #expect(!OnboardingPlan.pages(
      for: wanted, designatedOleds: [], includesKeysPage: false).contains(.accessibility))
  }

  @Test func fullRigDerivesDetectionSizeAndDesignation() {
    // Displays lead the flow; the permission ask follows the size pages.
    let env = environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell", productName: "DELL U2725QE", suggestion: suggestion),
    ])
    #expect(pages(env) == [
      .welcome, .detection,
      .size(displayKey: "dell"),
      .accessibility,
      .oledSelect, .finish,
    ])
  }

  @Test func aDisplayWithoutASuggestionGetsNoSizePage() {
    let env = environment([entry(key: "mag")])
    #expect(!pages(env).contains { if case .size = $0 { true } else { false } })
  }

  @Test func sizePagesFollowDisplayOrder() {
    let env = environment([
      entry(key: "a", suggestion: suggestion),
      entry(key: "b", suggestion: suggestion),
    ])
    let sizeKeys: [String] = pages(env).compactMap {
      if case let .size(key) = $0 { key } else { nil }
    }
    #expect(sizeKeys == ["a", "b"])
  }

  @Test func designationAddsTheCarePage() {
    let env = environment([entry(key: "mag"), entry(key: "dell")])
    let without = pages(env)
    let with = pages(env, designatedOleds: ["mag"])
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
    #expect(!pages(env, designatedOleds: ["mag"]).contains(.oledCare))
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
