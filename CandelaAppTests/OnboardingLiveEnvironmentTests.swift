import CandelaKit
import Testing

// The pure half of onboarding environment assembly: every mapping rule the
// flow depends on, pinned against constructed values. Nothing here touches a
// display, a catalog or a defaults domain; the live harvest layer is covered by
// the hardware pass instead.
@Suite("Onboarding live environment builder")
struct OnboardingLiveEnvironmentTests {
  private static func row(
    _ width: Int, _ height: Int, pixelWidth: Int? = nil, pixelHeight: Int? = nil
  ) -> DisplayModeRow {
    DisplayModeRow(
      mode: DisplayMode(
        ioModeID: Int32(width + height),
        logicalWidth: width, logicalHeight: height,
        pixelWidth: pixelWidth ?? width, pixelHeight: pixelHeight ?? height,
        refreshHz: 60, isNative: false
      ),
      isScaled: true
    )
  }

  /// A stop the merge appends to the curated list: a size Candela renders by
  /// mirroring onto a virtual display rather than one the display publishes.
  private static func synthesizedRow(_ width: Int, _ height: Int) -> DisplayModeRow {
    DisplayModeRow(
      mode: DisplayMode(
        ioModeID: DisplayMode.syntheticIoModeID(stopIndex: 0),
        logicalWidth: width, logicalHeight: height,
        pixelWidth: width * 2, pixelHeight: height * 2,
        refreshHz: 0, isNative: false, provenance: .synthesized
      ),
      isScaled: true
    )
  }

  private static func input(
    key: String = "panel",
    name: String = "Some Display",
    productName: String = "Some Display",
    nativePixels: (Int, Int)? = (3840, 2160),
    rotation: Int? = 0,
    physicalCm: (Int, Int)? = (60, 34),
    looksLike: (Int, Int) = (3840, 2160),
    refreshHz: Double = 60,
    volume: VCPSupport? = nil,
    recommendation: SizeRecommendation? = nil,
    curatedRows: [DisplayModeRow] = [],
    dismissed: Bool = false,
    appliedThisSession: Bool = false,
    enrolled: Bool = false
  ) -> OnboardingDisplayInput {
    OnboardingDisplayInput(
      persistenceKey: key,
      name: name,
      productName: productName,
      reportedNativePixelWidth: nativePixels?.0,
      reportedNativePixelHeight: nativePixels?.1,
      rotationDegrees: rotation,
      physicalWidthCm: physicalCm?.0,
      physicalHeightCm: physicalCm?.1,
      currentLooksLikeWidth: looksLike.0,
      currentLooksLikeHeight: looksLike.1,
      refreshHz: refreshHz,
      volumeSupport: volume,
      recommendation: recommendation,
      curatedRows: curatedRows,
      recommendationDismissed: dismissed,
      sizeAppliedThisSession: appliedThisSession,
      enrolledInCare: enrolled
    )
  }

  // MARK: - Geometry

  @Test func panelNativePixelsSurviveAQuarterTurn() {
    // The rig's Dell: manufactured 3840x2160, mounted at 270 degrees, so macOS
    // reports both the native mode and the looks-like size portrait.
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: (2160, 3840), rotation: 270, looksLike: (1440, 2560)))

    #expect(entry.nativePixelWidth == 3840)
    #expect(entry.nativePixelHeight == 2160)
    // The looks-like size is what a person reads off the mounted display, so it
    // is never un-rotated.
    #expect(entry.currentLooksLikeWidth == 1440)
    #expect(entry.currentLooksLikeHeight == 2560)
    #expect(entry.rotationDegrees == 270)
    // Drawn as mounted: portrait.
    #expect(entry.drawnAspect < 1)
  }

  @Test func ninetyDegreesSwapsTheSameWayAsTwoSeventy() {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: (1440, 3440), rotation: 90, looksLike: (1440, 3440)))

    #expect(entry.nativePixelWidth == 3440)
    #expect(entry.nativePixelHeight == 1440)
  }

  @Test func halfTurnsAndUprightDisplaysPassNativePixelsThrough() {
    for rotation in [0, 180] {
      let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
        nativePixels: (3440, 1440), rotation: rotation, looksLike: (3440, 1440)))

      #expect(entry.nativePixelWidth == 3440)
      #expect(entry.nativePixelHeight == 1440)
      #expect(entry.rotationDegrees == rotation)
    }
  }

  @Test func anUndescribableRotationIsDrawnUpright() {
    // RT7: nil is a real answer, not a missing reading.
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: (3440, 1440), rotation: nil, looksLike: (3440, 1440)))

    #expect(entry.rotationDegrees == 0)
    #expect(entry.nativePixelWidth == 3440)
    #expect(entry.nativePixelHeight == 1440)
  }

  @Test func anUnenumeratedDisplayFallsBackToItsLooksLikeAspect() {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: nil, rotation: 0, looksLike: (3440, 1440)))

    #expect(entry.nativePixelWidth == 3440)
    #expect(entry.nativePixelHeight == 1440)
  }

  @Test func theLooksLikeFallbackIsStillSwappedIntoPanelNative() {
    // Both halves at once: no native-flagged mode AND a quarter turn. The
    // looks-like size arrives rotated, so the fallback has to un-rotate it the
    // same way a real native size would be, and `drawnAspect` re-swaps it back
    // to the portrait the display is actually mounted in.
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: nil, rotation: 90, looksLike: (1440, 2560)))

    #expect(entry.nativePixelWidth == 2560)
    #expect(entry.nativePixelHeight == 1440)
    #expect(entry.drawnAspect < 1)
  }

  @Test func aZeroNativePixelSizeIsTreatedAsAbsent() {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: (0, 0), rotation: 0, looksLike: (2560, 1440)))

    #expect(entry.nativePixelWidth == 2560)
    #expect(entry.nativePixelHeight == 1440)
  }

  // MARK: - Physical size

  @Test func diagonalInchesIsTheHypotenuseOfTheDeclaredSize() throws {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(physicalCm: (60, 34)))

    let diagonal = try #require(entry.diagonalInches)
    #expect(abs(diagonal - 27.1511) < 0.001)
  }

  @Test func diagonalInchesDoesNotCareWhichAxisIsLonger() {
    let landscape = OnboardingEnvironmentBuilder.entry(for: Self.input(physicalCm: (60, 34)))
    let portrait = OnboardingEnvironmentBuilder.entry(for: Self.input(physicalCm: (34, 60)))

    #expect(landscape.diagonalInches == portrait.diagonalInches)
  }

  @Test func noPhysicalSizeMeansNoDiagonal() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(physicalCm: nil))
      .diagonalInches == nil)
  }

  @Test func aZeroPhysicalDimensionMeansNoDiagonal() {
    // Zero inches is a worse claim than no claim.
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(physicalCm: (60, 0)))
      .diagonalInches == nil)
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(physicalCm: (0, 34)))
      .diagonalInches == nil)
  }

  // MARK: - Volume (D24)

  @Test func anAdvertisedVolumeRegisterWorks() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(volume: .supported))
      .volume == .works)
  }

  @Test func aCleanDenialIsTheDisplaysOwnReport() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(volume: .unsupported))
      .volume == .declinedByDisplay)
  }

  @Test func anUnreadableCapabilityStringIsUnknownRatherThanADenial() {
    // The MAG answers no DDC read at all, so its verdict is stored as unknown.
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(volume: .unknown))
      .volume == .unknown)
  }

  @Test func anUnprobedDisplayIsUnknownRatherThanADenial() {
    // An absent entry means the probe has not run. Reporting that as "no
    // volume" would grey a working control with no visible reason.
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(volume: nil))
      .volume == .unknown)
  }

  // MARK: - Size suggestion (OB8)

  private static let ladder = [
    Self.row(2560, 1440),
    Self.row(2048, 1152),
    Self.row(1920, 1080, pixelWidth: 3840, pixelHeight: 2160),
  ]

  private static func recommendation(_ width: Int, _ height: Int) -> SizeRecommendation {
    SizeRecommendation(logicalWidth: width, logicalHeight: height, looksLikePPI: 110)
  }

  @Test func aCorrectionBecomesASuggestionWithTheCuratedListBehindIt() throws {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      looksLike: (3840, 2160),
      recommendation: Self.recommendation(2560, 1440),
      curatedRows: Self.ladder))

    let suggestion = try #require(entry.sizeSuggestion)
    #expect(suggestion.looksLikeWidth == 2560)
    #expect(suggestion.looksLikeHeight == 1440)
    // Catalog order, one choice per curated row.
    #expect(suggestion.alternatives.map(\.id) == ["2560x1440", "2048x1152", "1920x1080"])
    #expect(suggestion.alternatives.map(\.isHiDPI) == [false, false, true])
  }

  @Test func anAbstainingVerdictLeavesNoSizePage() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(
      recommendation: nil, curatedRows: Self.ladder)).sizeSuggestion == nil)
  }

  @Test func aDisplayAlreadyRunningTheRecommendedSizeGetsNoSizePage() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(
      looksLike: (2560, 1440),
      recommendation: Self.recommendation(2560, 1440),
      curatedRows: Self.ladder)).sizeSuggestion == nil)
  }

  @Test func aDismissedRecommendationStaysDismissedInTheFlow() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(
      recommendation: Self.recommendation(2560, 1440),
      curatedRows: Self.ladder,
      dismissed: true)).sizeSuggestion == nil)
  }

  @Test func aSizeAppliedThisSessionAnswersTheRecommendation() {
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(
      recommendation: Self.recommendation(2560, 1440),
      curatedRows: Self.ladder,
      appliedThisSession: true)).sizeSuggestion == nil)
  }

  @Test func aRecommendationWithNoCuratedRowHasNothingToApply() {
    // The wire-timing guard can withhold the very size the model named.
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(
      recommendation: Self.recommendation(3200, 1800),
      curatedRows: Self.ladder)).sizeSuggestion == nil)
  }

  @Test func synthesizedStopsAreNotOfferedAsAlternatives() throws {
    // The curated rows are the MERGED list, so a display opted into
    // synthesized sizes carries stops beside the published ones, and a stop can
    // share a logical size with a published row. A `Choice` is identified by
    // its size alone, so an unfiltered list would collide in the picker.
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      looksLike: (3840, 2160),
      recommendation: Self.recommendation(2560, 1440),
      curatedRows: [
        Self.row(2560, 1440),
        Self.synthesizedRow(2560, 1440),
        Self.row(2048, 1152),
        Self.synthesizedRow(2304, 1296),
      ]))

    let suggestion = try #require(entry.sizeSuggestion)
    #expect(suggestion.alternatives.map(\.id) == ["2560x1440", "2048x1152"])
  }

  @Test func aRecommendationOnlyASynthesizedRowCarriesHasNothingToApply() {
    // The apply seam names a size, not a mode, and a synthesized-only size
    // cannot be resolved from one. The density model is fed published rows for
    // the same reason, so this state means the two lists disagreed.
    #expect(OnboardingEnvironmentBuilder.entry(for: Self.input(
      looksLike: (3840, 2160),
      recommendation: Self.recommendation(2580, 1080),
      curatedRows: [Self.row(2560, 1440), Self.synthesizedRow(2580, 1080)]))
      .sizeSuggestion == nil)
  }

  @Test func aRotatedDisplayMatchesItsRecommendationInTheDisplayFrame() throws {
    // The recommendation and the curated rows are both in the display's own
    // frame, so a portrait mount needs no un-rotation on this path.
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      nativePixels: (2160, 3840),
      rotation: 270,
      looksLike: (2160, 3840),
      recommendation: Self.recommendation(1440, 2560),
      curatedRows: [Self.row(1440, 2560), Self.row(1080, 1920)]))

    let suggestion = try #require(entry.sizeSuggestion)
    #expect(suggestion.looksLikeWidth == 1440)
    #expect(suggestion.looksLikeHeight == 2560)
    #expect(entry.nativePixelWidth == 3840)
  }

  // MARK: - Identity and the environment as a whole

  @Test func theNameAndTheProductNameStayApart() {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      name: "Left", productName: "MAG 341CQPX QD-OLED"))

    #expect(entry.name == "Left")
    // The OLED guess reads the product name, so a rename must not reach it.
    #expect(entry.productName == "MAG 341CQPX QD-OLED")
  }

  @Test func theEntryIsIdentifiedByItsPersistenceKey() {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(key: "3669-abc"))
    #expect(entry.id == "3669-abc")
  }

  @Test func displayOrderFollowsInputOrder() {
    let environment = OnboardingEnvironmentBuilder.environment(
      displays: [Self.input(key: "first"), Self.input(key: "second"), Self.input(key: "third")],
      accessibilityGranted: false, loginItemEnabled: false, isFirstRun: true)

    #expect(environment.displays.map(\.persistenceKey) == ["first", "second", "third"])
  }

  @Test func globalInputsArriveUnchanged() {
    let environment = OnboardingEnvironmentBuilder.environment(
      displays: [], accessibilityGranted: true, loginItemEnabled: true, isFirstRun: false)

    #expect(environment.accessibilityGranted)
    #expect(environment.loginItemEnabled)
    #expect(!environment.isFirstRun)
    #expect(environment.displays.isEmpty)
  }

  @Test func enrollmentAndRefreshRateArriveUnchanged() {
    let entry = OnboardingEnvironmentBuilder.entry(for: Self.input(
      refreshHz: 175, enrolled: true))

    #expect(entry.refreshHz == 175)
    #expect(entry.enrolledInCare)
  }

  // MARK: - The plan reads what this builds

  @Test func onlyDisplaysWithASuggestionGetASizePage() {
    let environment = OnboardingEnvironmentBuilder.environment(
      displays: [
        Self.input(key: "no-correction", looksLike: (3440, 1440)),
        Self.input(
          key: "correction", looksLike: (3840, 2160),
          recommendation: Self.recommendation(2560, 1440), curatedRows: Self.ladder),
      ],
      accessibilityGranted: true, loginItemEnabled: false, isFirstRun: true)

    let pages = OnboardingPlan.pages(for: environment, designatedOleds: [])
    #expect(pages.contains(.size(displayKey: "correction")))
    #expect(!pages.contains(.size(displayKey: "no-correction")))
  }
}
