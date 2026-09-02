import Foundation

/// How a display uses macOS HDR: the mode Candela last DROVE the display to, not a
/// standing policy it enforces.
///
/// `alwaysOn` does NOT keep HDR engaged, despite the name. Nothing re-asserts it on
/// wake, restore or reconfiguration, and the only engage path is a user action through
/// `BrightnessController.setHDRMode`, so the mode goes stale whenever HDR is toggled
/// in System Settings. The panel reads `isHDREngaged` for what the display is actually
/// doing, and `BrightnessPathPolicy.usesNative` ignores the mode entirely.
///
/// Raw value 1 was `boost`, now removed. NEVER reuse it: displays that stored it must
/// keep decoding to `.off` through `DisplayPrefs.hdrMode`'s unknown-value fallback.
public enum HDRMode: Int, Sendable, CaseIterable {
  case off = 0
  case alwaysOn = 2
}

/// What launch and wake do with saved DDC values. Defaults to `.doNothing`, the safe
/// answer on a write-only panel.
public enum StartupAction: Int, Sendable, CaseIterable {
  case doNothing = 0
  case write = 1
  case read = 2
}

/// DDC read tries for the `.read` startup action.
public enum PollingMode: Int, Sendable, CaseIterable {
  case none = -2
  case minimal = -1
  case normal = 0
  case heavy = 1
  case custom = 2
}

/// Whether the panel's volume slider accepts input, overriding the automatic
/// verdict in either direction.
///
/// The automatic signal is the display's own DDC/CI capabilities string: a clean
/// parse with no VCP 0x62 is the ONLY thing that greys the slider on its own. A
/// failed, timed-out or unparseable read resolves to `.unknown` and leaves the slider
/// enabled. CoreAudio does not gate this: "no sink matched" cannot be told apart from
/// "this link carries no audio while the panel's speakers run off another input".
///
/// Overrides exist because a capabilities string is unreliable in the field:
/// monitors truncate them, omit codes they implement, and advertise codes they
/// ignore.
public enum AudioSinkOverride: Int, Sendable, CaseIterable {
  /// Trust `CapabilityString.support(forVCP:in:)` via `VolumeSliderPolicy`.
  case auto = 0
  /// Always greyed: the panel advertises volume it does not actually apply.
  case forceNone = 1
  /// Always live: the panel takes volume writes its capabilities string denies
  /// (or never returned).
  case forcePresent = 2
}

/// Which displays the volume keys hit.
public enum MultiKeyboardVolume: Int, Sendable, CaseIterable {
  case mouse = 0
  case allScreens = 1
  case audioDeviceNameMatching = 2
}

/// Menu-bar icon visibility. `externalOnly` was appended later as 3, so RAW ORDER is
/// not UI ORDER: pickers must list the cases explicitly.
public enum MenuIcon: Int, Sendable, CaseIterable {
  case show = 0
  case sliderOnly = 1
  case hide = 2
  case externalOnly = 3
}

/// Panel footer style.
///
/// RESERVED AND INERT: the key exists so the schema slot is claimed and can
/// never be reused, but no Candela code reads it. Documented as reserved, never as an
/// escape hatch.
public enum MenuItemStyle: Int, Sendable, CaseIterable {
  case icon = 0
  case text = 1
  case hide = 2
}

/// Keyboard mode for one key family. Brightness and volume share this enum.
public enum KeyMode: Int, Sendable, CaseIterable {
  case media = 0
  case custom = 1
  case both = 2
  case disabled = 3
}

/// Which displays the brightness keys hit.
public enum MultiKeyboardBrightness: Int, Sendable, CaseIterable {
  case mouse = 0
  case allScreens = 1
  case focusInsteadOfMouse = 2
}

/// One command's DDC tuning row, as the Displays pane's grid presents it.
public struct CommandTuning: Sendable, Equatable {
  public var unavailableDDC: Bool
  public var minDDCOverride: Int
  public var maxDDCOverride: Int
  /// 1…9; 0 (unset) and 5 are both linear (`DimmingMath.curveMultiplier`).
  public var curveIndex: Int
  public var invert: Bool
  public var remapCodes: [UInt8]

  public init(
    unavailableDDC: Bool, minDDCOverride: Int, maxDDCOverride: Int,
    curveIndex: Int, invert: Bool, remapCodes: [UInt8]
  ) {
    self.unavailableDDC = unavailableDDC
    self.minDDCOverride = minDDCOverride
    self.maxDDCOverride = maxDDCOverride
    self.curveIndex = curveIndex
    self.invert = invert
    self.remapCodes = remapCodes
  }

  public var curveMultiplier: Double { DimmingMath.curveMultiplier(forIndex: curveIndex) }

  /// The override wins only when it exceeds the min override; otherwise the read or
  /// assumed max, clamped to 100.
  public func effectiveMaxDDC(readMax: Int?) -> Int {
    maxDDCOverride > minDDCOverride ? maxDDCOverride : min(readMax ?? 100, 100)
  }
}

/// Typed per-display settings, stored in UserDefaults under `"<name>.<persistenceKey>"`
/// so every display carries its own copy (the persistence key is the EDID UUID
/// or the identity triple; see `DisplayDiscovery.persistenceKey(from:)`).
///
/// `@unchecked Sendable` because UserDefaults is documented thread-safe and holds all
/// the state. A struct holding a UserDefaults does not satisfy Sendable under Swift 6,
/// so this is a class like `UserDefaultsBrightnessStore` rather than a value type.
public final class DisplayPrefs: @unchecked Sendable {
  private let defaults: UserDefaults
  private let persistenceKey: String

  /// Safe-mode seam, injected at construction, never a global or a UserDefaults
  /// lookup. It forces the startup-traffic getters only: every setter still writes
  /// through, so a pref changed during a safe-mode session takes effect on the next
  /// normal launch. Public so a construction site can be asserted rather than trusted.
  public let isSafeMode: Bool

  public init(defaults: UserDefaults = .standard, persistenceKey: String, safeMode: Bool = false) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey
    isSafeMode = safeMode
  }

  /// Unknown stored raw values fall back to `.off`, which is also what an unset key
  /// reads. That fallback is the migration path for the retired `boost` raw value 1.
  public var hdrMode: HDRMode {
    get { HDRMode(rawValue: defaults.integer(forKey: key("hdrMode"))) ?? .off }
    set { defaults.set(newValue.rawValue, forKey: key("hdrMode")) }
  }

  /// Dim this display in software only, never over DDC.
  public var forceSoftware: Bool {
    get { defaults.bool(forKey: key("forceSw")) }
    set { defaults.set(newValue, forKey: key("forceSw")) }
  }

  /// Use the shade overlay instead of the gamma table for software dimming
  /// (needed for virtual displays and when another app fights over gamma).
  public var avoidGamma: Bool {
    get { defaults.bool(forKey: key("avoidGamma")) }
    set { defaults.set(newValue, forKey: key("avoidGamma")) }
  }

  /// Where the combined scale hands off from software to hardware dimming,
  /// as a slider point in `DimmingMath.switchingPointRange`; feed it to
  /// `DimmingMath.switchingValue(fromPoint:)`. Out-of-range writes are clamped.
  public var combinedSwitchingPoint: Int {
    get { clampSwitchingPoint(defaults.integer(forKey: key("combinedSwitchingPoint"))) }
    set { defaults.set(clampSwitchingPoint(newValue), forKey: key("combinedSwitchingPoint")) }
  }

  // MARK: - OLED care

  // The defaults ARE the Recommended preset, so enrolling writes nothing but
  // `oledCareEnrolled` and an un-tuned display stays on the preset even as the
  // preset changes. The two true-default bools store INVERTED, under
  // `…Off` keys, so an absent key reads as ON rather than as OFF.

  public var oledCareEnrolled: Bool {
    get { defaults.bool(forKey: key("oledCareEnrolled")) }
    set { defaults.set(newValue, forKey: key("oledCareEnrolled")) }
  }

  /// Idle before the care dim engages, in seconds.
  public var oledIdleDimSeconds: Int {
    get { defaults.object(forKey: key("oledIdleDimSeconds")) as? Int ?? 300 }
    set { defaults.set(newValue, forKey: key("oledIdleDimSeconds")) }
  }

  /// **How bright the display is while dimmed**: 0.1 is darkest, 0.9 is barely dimmed.
  /// This is the number the user sets and reads.
  ///
  /// **The stored value is its complement, the overlay's OPACITY.** The inversion lives
  /// here at the accessor, so no stored value changes meaning and no migration is
  /// owed. This accessor is the only INTERPRETER of the key: `resetOledCare` removes
  /// it and `PrefName` carries it as a propagation identifier, both uninterpreted.
  ///
  /// The engine dims with an overlay whose alpha is this complement. The lock dim,
  /// delivered on the wire, uses this number directly as the fraction of the user's
  /// brightness to keep.
  public var oledIdleDimBrightness: Double {
    get { 1 - (defaults.object(forKey: key("oledIdleDimLevel")) as? Double ?? 0.5) }
    set { defaults.set(1 - newValue, forKey: key("oledIdleDimLevel")) }
  }

  public var oledLockDim: Bool {
    get { !defaults.bool(forKey: key("oledLockDimOff")) }
    set { defaults.set(!newValue, forKey: key("oledLockDimOff")) }
  }

  /// Exposure sampling. Needs Screen Recording, so it defaults OFF and is never
  /// enabled as a side effect of enrollment: the grant is the user's decision at the
  /// toggle, not the preset's.
  public var oledTelemetry: Bool {
    get { defaults.bool(forKey: key("oledTelemetry")) }
    set { defaults.set(newValue, forKey: key("oledTelemetry")) }
  }

  /// Window geometry and owner-app observation. Needs no permission
  /// and is the degraded no-permission mode's only data source, so it defaults
  /// ON and stores inverted.
  public var oledWindowObservation: Bool {
    get { !defaults.bool(forKey: key("oledWindowObservationOff")) }
    set { defaults.set(!newValue, forKey: key("oledWindowObservationOff")) }
  }

  /// Detection-driven region dimming.
  ///
  /// **Off by default even for an enrolled display, and not in the Recommended
  /// preset.** Every other care feature acts when the user is away or the screen is
  /// locked. This one alters the screen while they are looking at it, so a wrong
  /// nomination reads as a defect rather than as protection.
  public var oledDetectionDimming: Bool {
    get { defaults.bool(forKey: key("oledDetectionDimming")) }
    set { defaults.set(newValue, forKey: key("oledDetectionDimming")) }
  }

  public var oledBlackoutEnabled: Bool {
    get { defaults.bool(forKey: key("oledBlackoutEnabled")) }
    set { defaults.set(newValue, forKey: key("oledBlackoutEnabled")) }
  }

  public var oledBlackoutSeconds: Int {
    get { defaults.object(forKey: key("oledBlackoutSeconds")) as? Int ?? 1200 }
    set { defaults.set(newValue, forKey: key("oledBlackoutSeconds")) }
  }

  public var oledUnfocusedDimEnabled: Bool {
    get { defaults.bool(forKey: key("oledUnfocusedDimEnabled")) }
    set { defaults.set(newValue, forKey: key("oledUnfocusedDimEnabled")) }
  }

  public var oledUnfocusedDimSeconds: Int {
    get { defaults.object(forKey: key("oledUnfocusedDimSeconds")) as? Int ?? 600 }
    set { defaults.set(newValue, forKey: key("oledUnfocusedDimSeconds")) }
  }

  /// Brightness while dimmed, same scale and same stored complement as
  /// `oledIdleDimBrightness`.
  ///
  /// Brighter than the idle dim on purpose: an unfocused display is still in the
  /// user's view, so it gets a gentler dim than one nobody has touched for minutes.
  public var oledUnfocusedDimBrightness: Double {
    get { 1 - (defaults.object(forKey: key("oledUnfocusedDimLevel")) as? Double ?? 0.3) }
    set { defaults.set(1 - newValue, forKey: key("oledUnfocusedDimLevel")) }
  }

  public var oledHoursTracking: Bool {
    get { !defaults.bool(forKey: key("oledHoursTrackingOff")) }
    set { defaults.set(!newValue, forKey: key("oledHoursTrackingOff")) }
  }

  /// Returns this display to the Recommended preset by REMOVING its keys rather than
  /// writing their current default values back. An absent key follows the preset, so a
  /// display reset by writing today's numbers would be pinned to them and stop
  /// tracking a later change to the preset.
  ///
  /// Accumulated panel hours are deliberately NOT touched: they are wear data about
  /// the panel rather than a setting, and they sit under `PanelHoursTracker`'s own
  /// keys.
  public func resetOledCare() {
    for name in [
      "oledCareEnrolled", "oledIdleDimSeconds", "oledIdleDimLevel", "oledLockDimOff",
      "oledBlackoutEnabled", "oledBlackoutSeconds",
      "oledUnfocusedDimEnabled", "oledUnfocusedDimSeconds", "oledUnfocusedDimLevel",
      "oledHoursTrackingOff",
      // Note the inverted spelling: clearing "oledWindowObservation" would clear
      // nothing and leave a disabled observation disabled through a reset. The
      // accumulated exposure map is NOT cleared here, for the same reason panel hours
      // are not: it is wear data with its own delete action in the panel health view.
      "oledTelemetry", "oledWindowObservationOff", "oledDetectionDimming",
    ] {
      defaults.removeObject(forKey: key(name))
    }
  }

  // MARK: - Per-command DDC tuning

  public func tuning(for command: DDCCommand) -> CommandTuning {
    CommandTuning(
      unavailableDDC: defaults.bool(forKey: commandKey("unavailableDDC", command)),
      minDDCOverride: defaults.integer(forKey: commandKey("minDDCOverride", command)),
      maxDDCOverride: defaults.integer(forKey: commandKey("maxDDCOverride", command)),
      curveIndex: defaults.integer(forKey: commandKey("curveDDC", command)),
      invert: defaults.bool(forKey: commandKey("invertDDC", command)),
      remapCodes: Self.parseRemapCodes(defaults.string(forKey: commandKey("remapDDC", command)) ?? "")
    )
  }

  public func setTuning(_ tuning: CommandTuning, for command: DDCCommand) {
    defaults.set(tuning.unavailableDDC, forKey: commandKey("unavailableDDC", command))
    defaults.set(tuning.minDDCOverride, forKey: commandKey("minDDCOverride", command))
    defaults.set(tuning.maxDDCOverride, forKey: commandKey("maxDDCOverride", command))
    defaults.set(tuning.curveIndex, forKey: commandKey("curveDDC", command))
    defaults.set(tuning.invert, forKey: commandKey("invertDDC", command))
    defaults.set(
      tuning.remapCodes.map { String(format: "%02x", $0) }.joined(separator: ", "),
      forKey: commandKey("remapDDC", command)
    )
  }

  /// Comma-separated hex bytes; whitespace trimmed, and empty, zero and non-hex
  /// tokens dropped.
  public static func parseRemapCodes(_ raw: String) -> [UInt8] {
    raw.components(separatedBy: ",").compactMap { token in
      let trimmed = token.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, let code = UInt8(trimmed, radix: 16), code != 0 else { return nil }
      return code
    }
  }

  /// Per-command key format `"<name>.<cmd.rawValue>.<pk>"`, fixed forever once
  /// shipped. The exact-key tests pin it.
  private func commandKey(_ name: String, _ command: DDCCommand) -> String {
    "\(name).\(command.rawValue).\(persistenceKey)"
  }

  // MARK: - Per-display audio/polling options

  /// Real DDC mute (VCP 0x8D) instead of writing volume 0. Defaults to false, so no
  /// 0x8D traffic.
  public var enableMuteUnmute: Bool {
    get { defaults.bool(forKey: key("enableMuteUnmute")) }
    set { defaults.set(newValue, forKey: key("enableMuteUnmute")) }
  }

  /// Logical mute flag. Persists under BOTH mute strategies.
  public var muted: Bool {
    get { defaults.bool(forKey: key("muted")) }
    set { defaults.set(newValue, forKey: key("muted")) }
  }

  /// Matched, normalized, against the default output device in
  /// `audioDeviceNameMatching` mode. Empty means use the raw display name.
  public var audioDeviceNameOverride: String {
    get { defaults.string(forKey: key("audioDeviceNameOverride")) ?? "" }
    set { defaults.set(newValue, forKey: key("audioDeviceNameOverride")) }
  }

  public var hideVolumeSlider: Bool {
    get { defaults.bool(forKey: key("hideVolumeSlider")) }
    set { defaults.set(newValue, forKey: key("hideVolumeSlider")) }
  }

  /// User-chosen display name. Empty means use the hardware name.
  public var friendlyName: String {
    get { defaults.string(forKey: key("friendlyName")) ?? "" }
    set { defaults.set(newValue, forKey: key("friendlyName")) }
  }

  /// The panel skips this display's section entirely.
  public var hideDisplay: Bool {
    get { defaults.bool(forKey: key("hideDisplay")) }
    set { defaults.set(newValue, forKey: key("hideDisplay")) }
  }

  /// Slower-paced DDC reads.
  ///
  /// RESERVED AND INERT: the key exists so the schema slot is claimed, but
  /// NOTHING in Candela reads it. The paced-read plumbing was never built, and the
  /// control was cut anyway.
  public var longerDelay: Bool {
    get { defaults.bool(forKey: key("longerDelay")) }
    set { defaults.set(newValue, forKey: key("longerDelay")) }
  }

  /// The user closed this display's size suggestion. The Recommended mark stays
  /// on the size itself; only the hub's callout row honors this, so the
  /// suggestion is still legible where a size is chosen after it is waved off.
  public var sizeRecommendationDismissed: Bool {
    get { defaults.bool(forKey: key("sizeRecommendationDismissed")) }
    set { defaults.set(newValue, forKey: key("sizeRecommendationDismissed")) }
  }

  /// Manual override for the panel's volume-slider verdict, in both directions; see
  /// `AudioSinkOverride`. Unknown raw values fall back to `.auto`, so a stray write
  /// can never strand the slider in a state the user cannot undo.
  public var audioSinkOverride: AudioSinkOverride {
    get { AudioSinkOverride(rawValue: defaults.integer(forKey: key("audioSinkOverride"))) ?? .auto }
    set { defaults.set(newValue.rawValue, forKey: key("audioSinkOverride")) }
  }

  /// Media keys skip this display in every key loop's BODY, but the tap still
  /// swallows the event: there is no pass-through for a disabled display.
  public var isDisabled: Bool {
    get { defaults.bool(forKey: key("isDisabled")) }
    set { defaults.set(newValue, forKey: key("isDisabled")) }
  }

  /// Suppresses the VOLUME and MUTE HUD pills only. Brightness and contrast pills
  /// ignore it.
  public var hideOsd: Bool {
    get { defaults.bool(forKey: key("hideOsd")) }
    set { defaults.set(newValue, forKey: key("hideOsd")) }
  }

  /// Unknown raw values fall back to `.normal`, which is raw 0 and so also what an
  /// unset pref reads.
  public var pollingMode: PollingMode {
    get { PollingMode(rawValue: defaults.integer(forKey: key("pollingMode"))) ?? .normal }
    set { defaults.set(newValue.rawValue, forKey: key("pollingMode")) }
  }

  public var pollingCount: Int {
    get { defaults.integer(forKey: key("pollingCount")) }
    set { defaults.set(newValue, forKey: key("pollingCount")) }
  }

  /// Mode to DDC read tries.
  ///
  /// Safe mode issues no DDC reads, so the budget is zero whatever the stored
  /// mode. Unreachable today, since `startupAction` is already forced to `.doNothing`
  /// and only the `.read` path consults this. Kept because it survives any future
  /// call site that reads `pollingTries` directly.
  public var pollingTries: Int {
    if isSafeMode { return 0 }
    return switch pollingMode {
    case .none: 0
    case .minimal: 1
    case .normal: 5
    case .heavy: 20
    case .custom: max(0, pollingCount)
    }
  }

  // MARK: - App-level defaults

  // Shared across displays (no persistence suffix), surfaced here so the engine reads
  // every dimming preference through one object.

  /// Disable the combined software and hardware scale: brightness maps onto the DDC
  /// range alone, with no software-dimming zone.
  public var disableCombinedBrightness: Bool {
    get { defaults.bool(forKey: "disableCombinedBrightness") }
    set { defaults.set(newValue, forKey: "disableCombinedBrightness") }
  }

  /// Let software dimming reach fully black instead of stopping at 15% of the panel's
  /// output. It can blank the display.
  public var allowZeroSwBrightness: Bool {
    get { defaults.bool(forKey: "allowZeroSwBrightness") }
    set { defaults.set(newValue, forKey: "allowZeroSwBrightness") }
  }

  /// Step brightness keys on the separate combined scale (`DimmingMath.stepCombined`,
  /// 32 chiclets) instead of the plain 16-chiclet one, while the combined path is
  /// active.
  public var separateCombinedScale: Bool {
    get { defaults.bool(forKey: "separateCombinedScale") }
    set { defaults.set(newValue, forKey: "separateCombinedScale") }
  }

  /// Show the contrast slider in the panel. Defaults to false.
  public var showContrast: Bool {
    get { defaults.bool(forKey: "showContrast") }
    set { defaults.set(newValue, forKey: "showContrast") }
  }

  /// What launch/reconfigure/wake does with saved DDC values.
  ///
  /// Under safe mode the GETTER reports `.doNothing`, which closes the startup
  /// and wake restores (`RestoreCoordinator` gates on `== .write`) and the volume and
  /// contrast readback (`DDCValueController` gates on `== .read`) for the session. The
  /// SETTER still writes the real value through, so a pref changed during a safe-mode
  /// session takes effect on the next normal launch.
  public var startupAction: StartupAction {
    get {
      isSafeMode
        ? .doNothing
        : (StartupAction(rawValue: defaults.integer(forKey: "startupAction")) ?? .doNothing)
    }
    set { defaults.set(newValue.rawValue, forKey: "startupAction") }
  }

  /// Which display(s) the volume keys hit.
  public var multiKeyboardVolume: MultiKeyboardVolume {
    get { MultiKeyboardVolume(rawValue: defaults.integer(forKey: "multiKeyboardVolume")) ?? .mouse }
    set { defaults.set(newValue.rawValue, forKey: "multiKeyboardVolume") }
  }

  public var menuIcon: MenuIcon {
    get { MenuIcon(rawValue: defaults.integer(forKey: "menuIcon")) ?? .show }
    set { defaults.set(newValue.rawValue, forKey: "menuIcon") }
  }

  /// Reserved and inert; see `MenuItemStyle`.
  public var menuItemStyle: MenuItemStyle {
    get { MenuItemStyle(rawValue: defaults.integer(forKey: "menuItemStyle")) ?? .icon }
    set { defaults.set(newValue.rawValue, forKey: "menuItemStyle") }
  }

  public var keyboardBrightness: KeyMode {
    get { KeyMode(rawValue: defaults.integer(forKey: "keyboardBrightness")) ?? .media }
    set { defaults.set(newValue.rawValue, forKey: "keyboardBrightness") }
  }

  public var keyboardVolume: KeyMode {
    get { KeyMode(rawValue: defaults.integer(forKey: "keyboardVolume")) ?? .media }
    set { defaults.set(newValue.rawValue, forKey: "keyboardVolume") }
  }

  public var multiKeyboardBrightness: MultiKeyboardBrightness {
    get { MultiKeyboardBrightness(rawValue: defaults.integer(forKey: "multiKeyboardBrightness")) ?? .mouse }
    set { defaults.set(newValue.rawValue, forKey: "multiKeyboardBrightness") }
  }

  /// No UI: shows the Health pane's model-comparison instrument, a soak-only
  /// gauge kept off the shipped window until the exposure-model verdict is recorded.
  public var showModelComparison: Bool {
    get { defaults.bool(forKey: "showModelComparison") }
    set { defaults.set(newValue, forKey: "showModelComparison") }
  }

  /// Reserved and inert: nothing renders tick marks.
  public var showTickMarks: Bool {
    get { defaults.bool(forKey: "showTickMarks") }
    set { defaults.set(newValue, forKey: "showTickMarks") }
  }

  public var enableSliderSnap: Bool {
    get { defaults.bool(forKey: "enableSliderSnap") }
    set { defaults.set(newValue, forKey: "enableSliderSnap") }
  }

  public var enableSliderPercent: Bool {
    get { defaults.bool(forKey: "enableSliderPercent") }
    set { defaults.set(newValue, forKey: "enableSliderPercent") }
  }

  /// Where the brightness and contrast pills sit on the display they are drawn on.
  /// The shipped default is `topCenter`, but `HUDPosition` stores `topRight` as 0, so
  /// an absent key and an explicit top-right choice differ only by PRESENCE. Hence
  /// `object(forKey:)` rather than `integer(forKey:)`: a stored choice, top right
  /// included, is always honoured.
  public var hudPositionBrightness: HUDPosition {
    get { storedHUDPosition(forKey: "hudPositionBrightness") }
    set { defaults.set(newValue.rawValue, forKey: "hudPositionBrightness") }
  }

  /// The volume and mute pills' own position, split along the same line `hideOsd`
  /// already draws.
  ///
  /// Two keys give each KIND a stable home of its own. Not a way to see both at once:
  /// `BrightnessHUD` keys one window per DISPLAY, so the two kinds take turns in it,
  /// and pressing volume then brightness inside the fade moves that one window from
  /// one anchor to the other.
  public var hudPositionVolume: HUDPosition {
    get { storedHUDPosition(forKey: "hudPositionVolume") }
    set { defaults.set(newValue.rawValue, forKey: "hudPositionVolume") }
  }

  /// Absent key or unknown raw value gives the shipped `topCenter`. A present, valid
  /// value is the user's choice, and 0 (top right) is a choice like any other, which
  /// `integer(forKey:)`'s 0-for-absent could not express.
  private func storedHUDPosition(forKey key: String) -> HUDPosition {
    guard let stored = defaults.object(forKey: key) as? Int else { return .topCenter }
    return HUDPosition(rawValue: stored) ?? .topCenter
  }

  /// How every indicator pill draws, app-level like the two position keys.
  /// Plain `integer(forKey:)` is correct here, unlike the positions: raw 0 IS the
  /// shipped default, so absent and default agree.
  public var hudStyle: HUDStyle {
    get { HUDStyle(rawValue: defaults.integer(forKey: "hudStyle")) ?? .system }
    set { defaults.set(newValue.rawValue, forKey: "hudStyle") }
  }

  /// Hide the built-in display's panel section.
  public var hideBuiltInDisplay: Bool {
    get { defaults.bool(forKey: "hideBuiltInDisplay") }
    set { defaults.set(newValue, forKey: "hideBuiltInDisplay") }
  }

  /// Hide the panel's Keep Display Awake row. Presentation only: hiding the row
  /// never releases an assertion the row took, because a control's visibility
  /// is not a statement about the state it controls.
  public var hideKeepAwake: Bool {
    get { defaults.bool(forKey: "hideKeepAwake") }
    set { defaults.set(newValue, forKey: "hideKeepAwake") }
  }

  /// Presentation only, like `hideKeepAwake`. The row is already absent below
  /// two commandable displays, so this key only matters on a multi-display rig.
  public var hideCombinedBrightness: Bool {
    get { defaults.bool(forKey: "hideCombinedBrightness") }
    set { defaults.set(newValue, forKey: "hideCombinedBrightness") }
  }

  /// Escape hatch, with NO UI by design. Default ON, so the stored form is the
  /// override rather than the setting: an absent key means guarded.
  ///
  /// Off, the mode picker again offers revealed modes at refreshes the panel has no
  /// native-width timing for, measured to scan out pillarboxed and cropped on the MAG
  /// 341C. It exists because the rule is inferred from ONE panel family's behaviour,
  /// and a display the rule misjudges would otherwise lose good modes with no way back
  /// short of a new build.
  ///
  /// `object(forKey:)` decides only PRESENCE and `bool(forKey:)` reads the value.
  /// Casting the object to `Bool` looks equivalent and is not: the cast fails on
  /// `defaults write … wireTimingGuard NO`, which stores the STRING "NO", so the hatch
  /// would silently do nothing for anyone who omitted `-bool` [MEASURED].
  public var wireTimingGuard: Bool {
    get {
      defaults.object(forKey: "wireTimingGuard") == nil
        ? true : defaults.bool(forKey: "wireTimingGuard")
    }
    set { defaults.set(newValue, forKey: "wireTimingGuard") }
  }

  // App-level keys. The key strings are shipped schema: never rename them.

  public var enableBrightnessSync: Bool {
    get { defaults.bool(forKey: "enableBrightnessSync") }
    set { defaults.set(newValue, forKey: "enableBrightnessSync") }
  }

  public var useFineScaleBrightness: Bool {
    get { defaults.bool(forKey: "useFineScaleBrightness") }
    set { defaults.set(newValue, forKey: "useFineScaleBrightness") }
  }

  public var useFineScaleVolume: Bool {
    get { defaults.bool(forKey: "useFineScaleVolume") }
    set { defaults.set(newValue, forKey: "useFineScaleVolume") }
  }

  /// INVERTED on disk. The UI binds through `interceptAlternateBrightnessKeys`
  /// below.
  public var disableAltBrightnessKeys: Bool {
    get { defaults.bool(forKey: "disableAltBrightnessKeys") }
    set { defaults.set(newValue, forKey: "disableAltBrightnessKeys") }
  }

  // Binding-layer positives: checked in the UI is true here and "off" on disk.

  public var combinedBrightness: Bool {
    get { !disableCombinedBrightness }
    set { disableCombinedBrightness = !newValue }
  }

  public var interceptAlternateBrightnessKeys: Bool {
    get { !disableAltBrightnessKeys }
    set { disableAltBrightnessKeys = !newValue }
  }

  private func key(_ name: String) -> String {
    "\(name).\(persistenceKey)"
  }

  // MARK: - Virtual display slots

  // App-level, slot-suffixed keys (`virtualSlotConfigured.<slot>`), following the
  // per-command composition. The keys are shipped schema: add, never rename. Defaults
  // describe the slot before anything was stored, an unconfigured 1920x1080 HiDPI
  // display with the slot's default name.
  private func vdKey(_ name: String, _ slot: Int) -> String { "\(name).\(slot)" }

  /// Numeric fields read through the COERCING accessors behind a presence check,
  /// never `object(forKey:) as? Int`. A shell `defaults write … virtualSlotWidth.1
  /// 3440` stores a STRING that the typed cast silently rejects while `defaults.bool`
  /// accepts "YES" for `configured`, so a staged slot would half-apply with no error
  /// anywhere. Width and height are clamped to the pane's entry range so a wild stored
  /// value cannot reach the engine.
  public func virtualSlot(_ slot: Int) -> VirtualSlotDefinition {
    func presentInt(_ name: String, default fallback: Int, clampedTo range: ClosedRange<Int>) -> Int {
      defaults.object(forKey: vdKey(name, slot)) == nil
        ? fallback
        : min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: vdKey(name, slot))))
    }
    let configured = defaults.bool(forKey: vdKey("virtualSlotConfigured", slot))
    return VirtualSlotDefinition(
      // Absent key falls back to `configured` so a slot staged before the
      // defined marker existed (or by a shell write that only set
      // configured) still shows its tile.
      defined: defaults.object(forKey: vdKey("virtualSlotDefined", slot)) == nil
        ? configured : defaults.bool(forKey: vdKey("virtualSlotDefined", slot)),
      configured: configured,
      name: defaults.string(forKey: vdKey("virtualSlotName", slot))
        ?? VirtualDisplayIdentity.defaultName(slot: slot),
      width: presentInt("virtualSlotWidth", default: 1920, clampedTo: 320 ... 8192),
      height: presentInt("virtualSlotHeight", default: 1080, clampedTo: 320 ... 8192),
      hiDPI: defaults.object(forKey: vdKey("virtualSlotHiDPI", slot)) == nil
        ? true : defaults.bool(forKey: vdKey("virtualSlotHiDPI", slot)),
      refreshHz: defaults.object(forKey: vdKey("virtualSlotRefreshHz", slot)) == nil
        ? 60 : defaults.double(forKey: vdKey("virtualSlotRefreshHz", slot)),
      recreateAtLaunch: defaults.bool(forKey: vdKey("virtualSlotRecreateAtLaunch", slot)),
      uuid: defaults.string(forKey: vdKey("virtualSlotUUID", slot)).flatMap(UUID.init(uuidString:))
    )
  }

  public func setVirtualSlot(_ definition: VirtualSlotDefinition, slot: Int) {
    defaults.set(definition.defined, forKey: vdKey("virtualSlotDefined", slot))
    defaults.set(definition.configured, forKey: vdKey("virtualSlotConfigured", slot))
    defaults.set(definition.name, forKey: vdKey("virtualSlotName", slot))
    defaults.set(definition.width, forKey: vdKey("virtualSlotWidth", slot))
    defaults.set(definition.height, forKey: vdKey("virtualSlotHeight", slot))
    defaults.set(definition.hiDPI, forKey: vdKey("virtualSlotHiDPI", slot))
    defaults.set(definition.refreshHz, forKey: vdKey("virtualSlotRefreshHz", slot))
    defaults.set(definition.recreateAtLaunch, forKey: vdKey("virtualSlotRecreateAtLaunch", slot))
    if let uuid = definition.uuid {
      defaults.set(uuid.uuidString, forKey: vdKey("virtualSlotUUID", slot))
    }
    // A nil uuid is a NO-OP, never a removal: the accessor also reads nil for an
    // unparseable stored string, so a read-modify-write from a pane control would
    // delete the identity as a side effect of toggling Retina. Removal is
    // `clearVirtualSlots` alone.
  }

  /// The slot definitions the reconciler consumes, keyed by slot. User slots
  /// only: synthesis slots carry no stored definition.
  public func virtualSlotDefinitions() -> [Int: VirtualSlotDefinition] {
    Dictionary(
      uniqueKeysWithValues: VirtualDisplayIdentity.userSlotRange.map { ($0, virtualSlot($0)) }
    )
  }

  /// The reset calls this AFTER the live displays are destroyed
  /// and immediately before the domain wipe. Redundant with the wipe today,
  /// load-bearing for any future partial reset, and the ONLY place a stored uuid is
  /// removed. Field-by-field, so a newly added key needs its own line here.
  public func clearVirtualSlots() {
    // The WHOLE family, deliberately: this is a removal, not an allocation, and a
    // reset that left a synthesis slot's keys behind is the one way stored state
    // could outlive the wipe.
    for slot in VirtualDisplayIdentity.slotRange {
      clearVirtualSlot(slot)
    }
  }

  /// The pane's Remove: the slot's whole stored definition goes, tile included. The
  /// caller unconfigures FIRST so the departing display is destroyed from a snapshot
  /// that still described it.
  public func clearVirtualSlot(_ slot: Int) {
    for name in ["virtualSlotDefined", "virtualSlotConfigured", "virtualSlotName",
                 "virtualSlotWidth", "virtualSlotHeight", "virtualSlotHiDPI",
                 "virtualSlotRefreshHz", "virtualSlotRecreateAtLaunch", "virtualSlotUUID"] {
      defaults.removeObject(forKey: vdKey(name, slot))
    }
  }

  // MARK: - Synthesized sizes

  // Per-display, composed by `key(_:)` like every other per-display pref, so both keys
  // end `".<persistenceKey>"`. Written through the pref-propagation path.
  //
  // Read-only properties plus named write methods, the `ModePersistence` shape rather
  // than the settable properties above. Synthesis requires a verified engine disengage
  // BEFORE the opt-in is persisted false, so these accessors only read and write their
  // own key: the ordering is the caller's, and an accessor with a side effect would
  // take that choice away from it.

  /// Whether synthesized stops are offered for this display. Off until
  /// someone opts in: synthesis costs a virtual display and a mirror.
  public var offerSyntheticSizes: Bool {
    // `bool(forKey:)`, never `object(forKey:) as? Bool`: `defaults write …
    // offerSyntheticSizes YES` stores the STRING "YES", which the cast rejects and
    // this accessor coerces. No presence check, unlike `wireTimingGuard`: absent and
    // stored-false mean the same thing here.
    defaults.bool(forKey: key("offerSyntheticSizes"))
  }

  public func setOfferSyntheticSizes(_ enabled: Bool) {
    defaults.set(enabled, forKey: key("offerSyntheticSizes"))
  }

  /// The synthesized stop this display is set to, or nil when none is stored.
  ///
  /// A descriptor, never a mode ID: synthesized rows carry sentinel negative
  /// `ioModeID`s that mean nothing across a relaunch, and the ladder is regenerated on
  /// read anyway. Undecodable data reads as nil, so a corrupted value degrades to "no
  /// stored choice" rather than trapping.
  public var storedSyntheticSize: SyntheticSizeDescriptor? {
    guard let data = defaults.data(forKey: key("storedSyntheticSize")) else { return nil }
    return try? JSONDecoder().decode(SyntheticSizeDescriptor.self, from: data)
  }

  /// nil REMOVES the key rather than writing an empty value, since absence is what
  /// the read above reports as "no stored choice". The opt-in is untouched either way,
  /// the same split `ModePersistence.clear` draws.
  public func setStoredSyntheticSize(_ descriptor: SyntheticSizeDescriptor?) {
    guard let descriptor else {
      defaults.removeObject(forKey: key("storedSyntheticSize"))
      return
    }
    guard let data = try? JSONEncoder().encode(descriptor) else { return }
    defaults.set(data, forKey: key("storedSyntheticSize"))
  }

  /// Whether ANYTHING has ever been stored for this display, prefs, saved
  /// levels or tuning. Every per-display key ends `".<persistenceKey>"`, so an empty
  /// answer means the domain is genuinely fresh, which is what tells "first time
  /// seeing this display" apart from "its settings failed to restore". A suffix scan,
  /// not a prefix: the persistence key is the TAIL of every stored key.
  public static func hasAnyStoredValue(
    forKey persistenceKey: String, defaults: UserDefaults = .standard
  ) -> Bool {
    let suffix = ".\(persistenceKey)"
    return defaults.dictionaryRepresentation().keys.contains { $0.hasSuffix(suffix) }
  }

  private func clampSwitchingPoint(_ point: Int) -> Int {
    min(max(point, DimmingMath.switchingPointRange.lowerBound), DimmingMath.switchingPointRange.upperBound)
  }
}
