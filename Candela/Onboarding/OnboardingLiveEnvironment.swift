import CandelaKit
import Foundation

/// Everything one display contributes to an `OnboardingEnvironment`, as plain
/// values.
///
/// The split exists so every mapping rule below is reachable from a test with
/// no attached display, no enumerated catalog and no defaults domain. The live
/// side only fills this in.
struct OnboardingDisplayInput {
  var persistenceKey: String
  /// Already resolved through `DisplayOrdering.title`: the user's chosen name
  /// when they set one, the hardware name otherwise.
  var name: String
  /// The display's own reported product name, never a rename. The OLED guess
  /// reads this one.
  var productName: String
  /// Native pixels AS MACOS REPORTS THEM, which on a rotated display is the
  /// rotated frame: the Dell is a 3840x2160 panel mounted at 270 degrees and
  /// reports 2160x3840. `entry(for:)` turns this into panel-native.
  var reportedNativePixelWidth: Int?
  var reportedNativePixelHeight: Int?
  /// nil is a real answer (RT7), not a missing reading: a display reporting an
  /// angle this app declines to describe is drawn upright rather than guessed
  /// at.
  var rotationDegrees: Int?
  /// Whole centimetres, as the display declared them. Absent for the built-in
  /// and for anything that never passed through discovery.
  var physicalWidthCm: Int?
  var physicalHeightCm: Int?
  /// Looks-like size in the DISPLAY's frame, which is what a person reads off
  /// a rotated display, so this one is never un-rotated.
  var currentLooksLikeWidth: Int
  var currentLooksLikeHeight: Int
  /// Every rate the display's published modes offer, in any order and at any
  /// size. The card states a CAPABILITY ("Up to N Hz"), so the entry carries
  /// the panel's ceiling rather than whatever it happens to be running: the MAG
  /// sitting at 100 Hz is still a 175 Hz panel.
  var offeredRefreshRates: [Double]
  /// The rate on the glass. Only a fallback here, for a display nothing has
  /// enumerated yet.
  var currentRefreshHz: Double
  /// The stored D24 verdict. nil for an ABSENT entry, meaning the capabilities
  /// probe has not run, which is not a denial.
  var volumeSupport: VCPSupport?
  /// The density model's correction, nil whenever it abstained.
  var recommendation: SizeRecommendation?
  /// The curated size rows, in catalog order. This is the MERGED list, so it
  /// can carry synthesized stops beside the published sizes; `sizeSuggestion`
  /// is where that is filtered, and why.
  var curatedRows: [DisplayModeRow]
  var recommendationDismissed: Bool
  var sizeAppliedThisSession: Bool
  var enrolledInCare: Bool
  /// The stored oledTelemetry pref, harvested so a re-run prefills the
  /// measurement choice a returning user already made.
  var measuredTelemetry: Bool = false
}

/// The pure half of environment assembly: values in, `OnboardingEnvironment`
/// out. Every decision the flow depends on is made here, so the live layer has
/// nothing left to get wrong.
enum OnboardingEnvironmentBuilder {
  static func environment(
    displays: [OnboardingDisplayInput],
    accessibilityGranted: Bool,
    loginItemEnabled: Bool,
    isFirstRun: Bool
  ) -> OnboardingEnvironment {
    OnboardingEnvironment(
      accessibilityGranted: accessibilityGranted,
      loginItemEnabled: loginItemEnabled,
      isFirstRun: isFirstRun,
      // Input order is the app's display-list order, and the flow renders and
      // paginates in exactly that order.
      displays: displays.map(entry(for:))
    )
  }

  static func entry(for input: OnboardingDisplayInput) -> OnboardingDisplayEntry {
    let rotation = input.rotationDegrees ?? 0
    let native = panelNativePixels(for: input, rotation: rotation)
    return OnboardingDisplayEntry(
      persistenceKey: input.persistenceKey,
      name: input.name,
      productName: input.productName,
      nativePixelWidth: native.width,
      nativePixelHeight: native.height,
      rotationDegrees: rotation,
      diagonalInches: diagonalInches(
        widthCm: input.physicalWidthCm, heightCm: input.physicalHeightCm),
      currentLooksLikeWidth: input.currentLooksLikeWidth,
      currentLooksLikeHeight: input.currentLooksLikeHeight,
      refreshHz: maximumRefreshHz(for: input),
      volume: volume(from: input.volumeSupport),
      sizeSuggestion: sizeSuggestion(for: input),
      enrolledInCare: input.enrolledInCare,
      measuredTelemetry: input.measuredTelemetry
    )
  }

  /// Panel-native is the geometry the glass was manufactured with, the same
  /// meaning OLED care's `PanelSpaceTransform` gives the term. macOS reports a
  /// rotated display's modes in the rotated frame, so a quarter turn swaps the
  /// axes back and the glyph draws the display as mounted rather than as
  /// manufactured.
  ///
  /// Falling back to the current looks-like size when no mode carried the
  /// native flag is deliberate: the glyph asks this pair for an aspect ratio
  /// only, a scaled size keeps the panel's aspect, and a zero size would draw
  /// every unenumerated display as a square.
  private static func panelNativePixels(
    for input: OnboardingDisplayInput, rotation: Int
  ) -> (width: Int, height: Int) {
    var reported = (width: input.currentLooksLikeWidth, height: input.currentLooksLikeHeight)
    if let width = input.reportedNativePixelWidth, let height = input.reportedNativePixelHeight,
       width > 0, height > 0 {
      reported = (width, height)
    }
    let quarterTurn = rotation == 90 || rotation == 270
    return quarterTurn ? (reported.height, reported.width) : reported
  }

  /// The panel's ceiling, which is what "Up to N Hz" claims. The rate a display
  /// happens to be running is a different sentence, and reading one as the other
  /// described a 175 Hz panel as a 100 Hz one.
  ///
  /// Quantized before comparing: rates arrive carrying float noise, and the
  /// quantizer keeps a genuine 59.9 apart from 60 while collapsing 59.9998 onto
  /// it.
  ///
  /// The running rate is a floor, not only a fallback. An enumeration taken
  /// while the display sits in a mirror set describes the master, so its rates
  /// can be lower than what the panel is demonstrably scanning out.
  private static func maximumRefreshHz(for input: OnboardingDisplayInput) -> Double {
    let current = DisplayMode.quantizedRefresh(input.currentRefreshHz)
    let offered = input.offeredRefreshRates.map(DisplayMode.quantizedRefresh)
    return max(offered.max() ?? 0, current)
  }

  /// Rotation-free by construction: the hypotenuse of the declared physical
  /// size does not care which field holds the long axis.
  ///
  /// nil rather than zero when either dimension is missing or non-positive.
  /// A diagonal is a physical claim, and a claim of zero inches is worse than
  /// no claim at all.
  private static func diagonalInches(widthCm: Int?, heightCm: Int?) -> Double? {
    guard let widthCm, let heightCm, widthCm > 0, heightCm > 0 else { return nil }
    let width = Double(widthCm), height = Double(heightCm)
    return (width * width + height * height).squareRoot() / 2.54
  }

  /// D24. An absent verdict means the capabilities probe has not run, and such
  /// a display is fully usable, so it reads the same as a probe that ran and
  /// failed: unknown, never a denial. Only a cleanly parsed capabilities string
  /// that lacks the volume register is the display declining.
  private static func volume(from support: VCPSupport?) -> OnboardingDisplayEntry.VolumeSupport {
    switch support {
    case .supported: .works
    case .unsupported: .declinedByDisplay
    case .unknown, nil: .unknown
    }
  }

  /// OB8, decided here rather than in `OnboardingPlan`: a display with no
  /// suggestion gets no size page at all, so the flow never asks a person to
  /// confirm what is already correct.
  ///
  /// The conditions match the settings hub's recommendation callout (PD8), so
  /// the two surfaces cannot disagree about whether a display has anything to
  /// correct.
  ///
  /// Matched against `recommendation` rather than `bestInBand`, which the
  /// verdict documents as equal whenever a recommendation exists. Only a
  /// recommendation is a correction: `bestInBand` outlives it as an endorsement,
  /// and an endorsement is a mark on a picker, not a page.
  ///
  /// **Published rows only**, though the catalog's rows are the MERGED list, so
  /// a display opted into synthesized sizes carries stops there and two rows can
  /// share one logical size. A `Choice` is identified by its size alone, so a
  /// duplicate collides in the picker's `ForEach`; the apply seam names a size
  /// rather than a mode, and a synthesized-only size cannot be resolved from
  /// one; and recommending a size that costs a virtual display is a v1
  /// non-goal.
  private static func sizeSuggestion(for input: OnboardingDisplayInput) -> OnboardingSizeSuggestion? {
    guard let recommendation = input.recommendation,
          !input.recommendationDismissed,
          !input.sizeAppliedThisSession
    else { return nil }
    let publishedRows = input.curatedRows.filter { !$0.mode.isSynthesized }
    let matchesRecommendation = { (row: DisplayModeRow) in
      row.mode.logicalWidth == recommendation.logicalWidth
        && row.mode.logicalHeight == recommendation.logicalHeight
    }
    guard publishedRows.contains(where: matchesRecommendation) else { return nil }
    guard recommendation.logicalWidth != input.currentLooksLikeWidth
      || recommendation.logicalHeight != input.currentLooksLikeHeight
    else { return nil }
    return OnboardingSizeSuggestion(
      looksLikeWidth: recommendation.logicalWidth,
      looksLikeHeight: recommendation.logicalHeight,
      alternatives: publishedRows.map {
        OnboardingSizeSuggestion.Choice(
          looksLikeWidth: $0.mode.logicalWidth,
          looksLikeHeight: $0.mode.logicalHeight,
          isHiDPI: $0.mode.isHiDPI
        )
      }
    )
  }
}

/// The live half: field reads off the app's own objects, handed straight to the
/// builder.
///
/// Nothing here decides anything. It is covered by the hardware pass rather than
/// by unit tests, which is only defensible while every rule stays above.
@MainActor
enum OnboardingLiveEnvironment {
  /// Externals only: `AppModel.displays` excludes the built-in structurally,
  /// and the flow is about displays this app configures.
  static func current(
    model: AppModel,
    loginItem: LoginItem,
    defaults: UserDefaults = .standard
  ) -> OnboardingEnvironment {
    let coordinator = model.displayModes
    let inputs = model.displays.map { state in
      input(for: state, model: model, coordinator: coordinator, defaults: defaults)
    }
    return OnboardingEnvironmentBuilder.environment(
      displays: inputs,
      accessibilityGranted: model.accessibility.isGranted,
      loginItemEnabled: loginItem.isEnabled,
      // D13's marker: an unwritten schema version is the only record that this
      // launch is the first one.
      isFirstRun: PrefsSchema.storedVersion(in: defaults) == nil
    )
  }

  private static func input(
    for state: AppModel.DisplayState,
    model: AppModel,
    coordinator: DisplayModeCoordinator,
    defaults: UserDefaults
  ) -> OnboardingDisplayInput {
    let key = state.display.persistenceKey
    // A catalog is enumerated on demand and onboarding is usually the first
    // surface a display is shown on, so an absent one means "nobody has asked
    // yet" rather than "no modes". Same call the settings hub makes when a
    // display's page appears; it enumerates without configuring.
    if coordinator.catalogs[state.id] == nil {
      coordinator.refreshCatalog(for: state.id)
    }
    let catalog = coordinator.catalogs[state.id]
    // `onScreen`, not `current`: while a synthesized size is engaged the
    // readback names a real descriptor that is not what is on the glass.
    let onScreen = catalog?.onScreen
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: key)
    let facts = model.hardwareFacts[key]
    return OnboardingDisplayInput(
      persistenceKey: key,
      name: DisplayOrdering.title(
        friendlyName: prefs.friendlyName, hardwareName: state.display.name),
      productName: state.display.name,
      reportedNativePixelWidth: catalog?.nativePixels?.width,
      reportedNativePixelHeight: catalog?.nativePixels?.height,
      rotationDegrees: model.rotation.displayedRotation(of: state.id).map { Int($0.degrees) },
      physicalWidthCm: facts?.physicalWidthCm,
      physicalHeightCm: facts?.physicalHeightCm,
      currentLooksLikeWidth: onScreen?.logicalWidth ?? 0,
      currentLooksLikeHeight: onScreen?.logicalHeight ?? 0,
      // Every published mode, not the running one: the card claims a ceiling.
      // Synthesized stops are absent from `all` by construction, which is what
      // keeps their `refreshHz: 0` sentinel out of the maximum.
      offeredRefreshRates: catalog?.all.map(\.refreshHz) ?? [],
      currentRefreshHz: onScreen?.refreshHz ?? 0,
      volumeSupport: model.volumeSupport[key],
      recommendation: catalog?.density?.recommendation,
      curatedRows: catalog?.rows ?? [],
      recommendationDismissed: prefs.sizeRecommendationDismissed,
      sizeAppliedThisSession: coordinator.sizeAppliedByUser.contains(state.id),
      enrolledInCare: prefs.oledCareEnrolled,
      measuredTelemetry: prefs.oledTelemetry
    )
  }
}
