import Foundation

/// How a display uses macOS HDR — the mode Candela last DROVE the display to,
/// not a standing policy it enforces.
///
/// `alwaysOn` does NOT keep HDR engaged, despite the name: nothing re-asserts
/// it on wake, restore or reconfiguration, and the only engage path is a user
/// action through `BrightnessController.setHDRMode`. So the mode can go stale
/// whenever HDR is toggled in System Settings, which is why the panel reads
/// `isHDREngaged` for what the display is actually doing (#84) and
/// `BrightnessPathPolicy.usesNative` ignores the mode entirely (#52). #87
/// tracks whether the mode should become a true mirror of the state.
///
/// Raw value 1 was `boost` (removed 2026-07-30) — NEVER reuse it: displays that
/// stored it must keep decoding to `.off` through `DisplayPrefs.hdrMode`'s
/// unknown-value fallback.
public enum HDRMode: Int, Sendable, CaseIterable {
  case off = 0
  case alwaysOn = 2
}

/// Fork StartupAction (app-level pref `startupAction`): what launch/wake does
/// with saved DDC values. Default `.doNothing` — the safe mode on write-only
/// panels.
public enum StartupAction: Int, Sendable, CaseIterable {
  case doNothing = 0
  case write = 1
  case read = 2
}

/// Fork PollingMode: DDC read tries for the `.read` startup action.
public enum PollingMode: Int, Sendable, CaseIterable {
  case none = -2
  case minimal = -1
  case normal = 0
  case heavy = 1
  case custom = 2
}

/// Whether the panel's volume slider accepts input, overriding the automatic
/// verdict in either direction (D24).
///
/// The automatic signal is the display's own DDC/CI capabilities string: a
/// clean parse with no VCP 0x62 is the ONLY thing that greys the slider on its
/// own. A failed, timed-out or unparseable read resolves to `.unknown` and
/// leaves the slider enabled. CoreAudio no longer gates this at all — "no sink
/// matched" cannot be told apart from "this link carries no audio while the
/// panel's speakers run off another input", so it was never evidence that a
/// working control should be taken away.
///
/// Overrides exist because a capabilities string is unreliable in the field:
/// monitors truncate them, omit codes they implement, and advertise codes they
/// ignore.
public enum AudioSinkOverride: Int, Sendable {
  /// Trust `CapabilityString.support(forVCP:in:)` via `VolumeSliderPolicy`.
  case auto = 0
  /// Always greyed — the panel advertises volume it does not actually apply.
  case forceNone = 1
  /// Always live — the panel takes volume writes its capabilities string denies
  /// (or never returned).
  case forcePresent = 2
}

/// Fork MultiKeyboardVolume: which display(s) the volume keys hit.
public enum MultiKeyboardVolume: Int, Sendable, CaseIterable {
  case mouse = 0
  case allScreens = 1
  case audioDeviceNameMatching = 2
}

/// Menu-bar icon visibility (fork MenuIcon). Raw values are the fork's —
/// `externalOnly` was appended later as 3, so RAW ORDER ≠ UI ORDER; pickers
/// must list cases explicitly (D5).
public enum MenuIcon: Int, Sendable, CaseIterable {
  case show = 0
  case sliderOnly = 1
  case hide = 2
  case externalOnly = 3
}

/// Panel footer style (fork MenuItemStyle).
///
/// RESERVED AND INERT (D32): the key exists so the schema slot is claimed and
/// can never be reused, but no Candela code reads it — Task 5 ships no footer
/// styles. Task 18 documents it as reserved, never as an escape hatch.
public enum MenuItemStyle: Int, Sendable, CaseIterable {
  case icon = 0
  case text = 1
  case hide = 2
}

/// Keyboard mode for one key family (fork KeyboardBrightness/KeyboardVolume —
/// same raw values, one shared enum).
public enum KeyMode: Int, Sendable, CaseIterable {
  case media = 0
  case custom = 1
  case both = 2
  case disabled = 3
}

/// Which display(s) the brightness keys hit (fork MultiKeyboardBrightness).
public enum MultiKeyboardBrightness: Int, Sendable, CaseIterable {
  case mouse = 0
  case allScreens = 1
  case focusInsteadOfMouse = 2
}

/// One command's DDC tuning row (fork: the Displays-pane grid — Enabled /
/// Min / Max / Curve / Invert / Remap).
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

  /// Fork maxDDC resolution: the override wins only when it exceeds the min
  /// override; otherwise the (read or assumed) max clamped to
  /// DDC_MAX_DETECT_LIMIT = 100.
  public func effectiveMaxDDC(readMax: Int?) -> Int {
    maxDDCOverride > minDDCOverride ? maxDDCOverride : min(readMax ?? 100, 100)
  }
}

/// Typed per-display settings, stored in UserDefaults under `"<name>.<persistenceKey>"`
/// so every display carries its own copy (the persistence key is the EDID UUID
/// or the identity triple — see `DisplayDiscovery.persistenceKey(from:)`).
///
/// UserDefaults is documented thread-safe, hence the unchecked conformance.
/// (A struct holding a UserDefaults does not satisfy Sendable under Swift 6,
/// so this mirrors `UserDefaultsBrightnessStore`'s shape rather than being a value type.)
public final class DisplayPrefs: @unchecked Sendable {
  private let defaults: UserDefaults
  private let persistenceKey: String

  /// D11 safe-mode seam: one flag injected at construction (never a global or
  /// a UserDefaults lookup). Forces the two startup-traffic getters only;
  /// every setter still writes through, so a pref changed during a safe-mode
  /// session takes effect on the next normal launch. Public so a construction
  /// site can be asserted rather than trusted.
  public let isSafeMode: Bool

  public init(defaults: UserDefaults = .standard, persistenceKey: String, safeMode: Bool = false) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey
    isSafeMode = safeMode
  }

  /// Unknown stored raw values fall back to `.off` — an unset key reads 0,
  /// which is `.off` already. That fallback is also the migration path for the
  /// retired `boost` raw value 1.
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

  // MARK: - OLED care (W3a)

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

  /// **How bright the display is while dimmed**: 0.1 is darkest, 0.9 is barely
  /// dimmed. This is the number the user sets and reads, and it is the ONLY
  /// meaning of "level" anywhere above this line.
  ///
  /// **The stored value is its complement, the overlay's OPACITY**, which is
  /// what the key has always held and still holds: 0.5 on disk has meant, and
  /// still means, a half-opaque overlay. The inversion lives here, at the
  /// accessor, so that no stored value changes meaning and no migration is
  /// owed. Everything that already existed on disk keeps rendering exactly as
  /// before; only the number shown to the user flipped, which was the ask
  /// (users read "10%" as "10% brightness", not "10% dimming").
  ///
  /// This accessor is the only INTERPRETER of the key. The other three uses of
  /// the string are uninterpreted: `resetOledCare` removes it, and `PrefName`
  /// carries it as a propagation identifier. Verified before choosing this over
  /// a new key, because the whole argument depends on it.
  ///
  /// The engine still dims with an overlay whose alpha is this complement; the
  /// lock dim, which is delivered on the wire, uses this number directly as the
  /// fraction of the user's brightness to keep.
  public var oledIdleDimBrightness: Double {
    get { 1 - (defaults.object(forKey: key("oledIdleDimLevel")) as? Double ?? 0.5) }
    set { defaults.set(1 - newValue, forKey: key("oledIdleDimLevel")) }
  }

  public var oledLockDim: Bool {
    get { !defaults.bool(forKey: key("oledLockDimOff")) }
    set { defaults.set(!newValue, forKey: key("oledLockDimOff")) }
  }

  /// Exposure sampling. Requires Screen Recording, so it defaults OFF and is
  /// never enabled as a side effect of enrollment — the grant is a decision
  /// the user makes at the toggle, not one the preset makes for them.
  public var oledTelemetry: Bool {
    get { defaults.bool(forKey: key("oledTelemetry")) }
    set { defaults.set(newValue, forKey: key("oledTelemetry")) }
  }

  /// Window geometry and owner-app observation (OC18). Needs no permission
  /// and is the degraded no-permission mode's only data source, so it defaults
  /// ON and stores inverted.
  public var oledWindowObservation: Bool {
    get { !defaults.bool(forKey: key("oledWindowObservationOff")) }
    set { defaults.set(!newValue, forKey: key("oledWindowObservationOff")) }
  }

  /// Detection-driven region dimming (#20).
  ///
  /// **Off by default even for an enrolled display, and not in the Recommended
  /// preset.** Every other care feature acts when the user is away or the
  /// screen is locked; this one alters the screen while they are looking at it,
  /// which makes it the only one where a wrong nomination is visible as a
  /// defect rather than as protection. Opting in is the point.
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
  /// Default 0.7, BRIGHTER than the idle dim's 0.5 on purpose: an unfocused
  /// display is still in the user's view, so it gets a gentler dim than one
  /// nobody has touched for five minutes. The stored 0.3 is unchanged; it is
  /// the same gentler dim, written as the overlay opacity it has always been.
  public var oledUnfocusedDimBrightness: Double {
    get { 1 - (defaults.object(forKey: key("oledUnfocusedDimLevel")) as? Double ?? 0.3) }
    set { defaults.set(1 - newValue, forKey: key("oledUnfocusedDimLevel")) }
  }

  public var oledHoursTracking: Bool {
    get { !defaults.bool(forKey: key("oledHoursTrackingOff")) }
    set { defaults.set(!newValue, forKey: key("oledHoursTrackingOff")) }
  }

  /// Returns this display to the Recommended preset by REMOVING the thirteen keys
  /// rather than writing their current default values back.
  ///
  /// The difference is not cosmetic: the accessors above document that an
  /// absent key follows the preset, so a display reset by writing today's
  /// numbers would be pinned to them and would stop tracking a later change to
  /// the preset — the one property the "defaults ARE the preset" design buys.
  ///
  /// Accumulated panel hours are deliberately NOT touched. They are wear data
  /// about the panel, not a setting, and they sit under their own keys
  /// (`PanelHoursTracker`); the per-display reset keeps them for the same
  /// reason it keeps the saved brightness, volume and contrast levels.
  public func resetOledCare() {
    for name in [
      "oledCareEnrolled", "oledIdleDimSeconds", "oledIdleDimLevel", "oledLockDimOff",
      "oledBlackoutEnabled", "oledBlackoutSeconds",
      "oledUnfocusedDimEnabled", "oledUnfocusedDimSeconds", "oledUnfocusedDimLevel",
      "oledHoursTrackingOff",
      // Note the inverted spelling: clearing "oledWindowObservation" would
      // clear nothing and leave a disabled observation disabled through a
      // reset. The accumulated exposure map is NOT cleared here, for the same
      // reason panel hours are not — it is wear data, not a setting, and it
      // has its own delete action in the panel health view.
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

  /// Fork getRemapControlCodes: comma-separated hex bytes; whitespace trimmed;
  /// empty, zero and non-hex tokens dropped.
  public static func parseRemapCodes(_ raw: String) -> [UInt8] {
    raw.components(separatedBy: ",").compactMap { token in
      let trimmed = token.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, let code = UInt8(trimmed, radix: 16), code != 0 else { return nil }
      return code
    }
  }

  /// Per-command key format `"<name>.<cmd.rawValue>.<pk>"` — fixed forever
  /// once shipped (the exact-key tests pin it).
  private func commandKey(_ name: String, _ command: DDCCommand) -> String {
    "\(name).\(command.rawValue).\(persistenceKey)"
  }

  // MARK: - Per-display audio/polling options (M4)

  /// Real DDC mute (VCP 0x8D) instead of writing volume 0. Default false —
  /// no 0x8D traffic (fork default).
  public var enableMuteUnmute: Bool {
    get { defaults.bool(forKey: key("enableMuteUnmute")) }
    set { defaults.set(newValue, forKey: key("enableMuteUnmute")) }
  }

  /// Logical mute flag. Persists in BOTH mute strategies (D3 resolves the
  /// fork's stepVolume/toggleMute inconsistency in favor of always-persist).
  public var muted: Bool {
    get { defaults.bool(forKey: key("muted")) }
    set { defaults.set(newValue, forKey: key("muted")) }
  }

  /// Name matched (normalized) against the default output device in
  /// audioDeviceNameMatching mode; empty = use the raw display name.
  public var audioDeviceNameOverride: String {
    get { defaults.string(forKey: key("audioDeviceNameOverride")) ?? "" }
    set { defaults.set(newValue, forKey: key("audioDeviceNameOverride")) }
  }

  public var hideVolumeSlider: Bool {
    get { defaults.bool(forKey: key("hideVolumeSlider")) }
    set { defaults.set(newValue, forKey: key("hideVolumeSlider")) }
  }

  /// User-chosen display name; "" = use the hardware name (fork friendlyName).
  public var friendlyName: String {
    get { defaults.string(forKey: key("friendlyName")) ?? "" }
    set { defaults.set(newValue, forKey: key("friendlyName")) }
  }

  /// Per-display hide: the panel skips this display's section entirely
  /// (spec §2 "per-display hide" — the fork never shipped the control; D7).
  public var hideDisplay: Bool {
    get { defaults.bool(forKey: key("hideDisplay")) }
    set { defaults.set(newValue, forKey: key("hideDisplay")) }
  }

  /// Fork longerDelay: slower-paced DDC reads.
  ///
  /// RESERVED AND INERT (D26 CORRECTION / D32): the key exists so the schema
  /// slot is claimed, but NOTHING in Candela reads it — the paced-read plumbing
  /// was never ported, and D26 cut both the control and the fork's
  /// start-at-login safety interlock. Task 18 documents it as reserved.
  public var longerDelay: Bool {
    get { defaults.bool(forKey: key("longerDelay")) }
    set { defaults.set(newValue, forKey: key("longerDelay")) }
  }

  /// Manual override for the panel's volume-slider verdict, in both directions
  /// (see `AudioSinkOverride` — the automatic signal is the display's own
  /// capabilities string, not CoreAudio). Unknown raw values fall back to
  /// `.auto`, so a stray write can never strand the slider in a state the user
  /// cannot undo.
  public var audioSinkOverride: AudioSinkOverride {
    get { AudioSinkOverride(rawValue: defaults.integer(forKey: key("audioSinkOverride"))) ?? .auto }
    set { defaults.set(newValue.rawValue, forKey: key("audioSinkOverride")) }
  }

  /// Per-display "disable keyboard control" (fork `isDisabled`): media keys
  /// skip this display in every key loop's BODY — the tap still swallows the
  /// event (fork parity; there is no pass-through for disabled displays).
  /// Honored in AppModel/KeyActionExecutor target resolution (Task 10).
  public var isDisabled: Bool {
    get { defaults.bool(forKey: key("isDisabled")) }
    set { defaults.set(newValue, forKey: key("isDisabled")) }
  }

  /// Per-display "hide volume OSD" (fork `hideOsd`): suppresses the VOLUME/
  /// MUTE HUD pills only — brightness/contrast pills ignore it (fork parity:
  /// the fork consults it solely on the volume paths). Honored in the
  /// executor's volume HUD funnel (Task 10).
  public var hideOsd: Bool {
    get { defaults.bool(forKey: key("hideOsd")) }
    set { defaults.set(newValue, forKey: key("hideOsd")) }
  }

  /// Unknown raw values fall back to `.normal` — the fork's default for an
  /// unset pref (raw 0).
  public var pollingMode: PollingMode {
    get { PollingMode(rawValue: defaults.integer(forKey: key("pollingMode"))) ?? .normal }
    set { defaults.set(newValue.rawValue, forKey: key("pollingMode")) }
  }

  public var pollingCount: Int {
    get { defaults.integer(forKey: key("pollingCount")) }
    set { defaults.set(newValue, forKey: key("pollingCount")) }
  }

  /// Mode → DDC read tries (fork OtherDisplay.pollingCount).
  ///
  /// D11: safe mode issues no DDC reads at all, so the try budget is zero
  /// regardless of the stored mode. Belt-and-braces — `startupAction` is
  /// already forced to `.doNothing` and `pollingTries` is consulted only on
  /// the `.read` path, so under safe mode this second override is unreachable
  /// through the first. It is kept because it is the honest expression of "no
  /// reads this session" and survives any future call site that consults
  /// `pollingTries` directly.
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

  // Shared across displays (no persistence suffix), but surfaced here so the
  // engine reads every dimming preference through one object. They mirror the
  // fork's global PrefKeys of the same names.

  /// Disable the combined software+hardware scale: brightness maps onto the
  /// DDC range alone, with no software-dimming zone (fork `.disableCombinedBrightness`).
  public var disableCombinedBrightness: Bool {
    get { defaults.bool(forKey: "disableCombinedBrightness") }
    set { defaults.set(newValue, forKey: "disableCombinedBrightness") }
  }

  /// Let software dimming reach fully black instead of stopping at 15% of the
  /// panel's output (fork `.allowZeroSwBrightness`, "can blank the display").
  public var allowZeroSwBrightness: Bool {
    get { defaults.bool(forKey: "allowZeroSwBrightness") }
    set { defaults.set(newValue, forKey: "allowZeroSwBrightness") }
  }

  /// Step brightness keys on the separate combined scale
  /// (`DimmingMath.stepCombined`, 32 chiclets) instead of the plain 16-chiclet
  /// transplant, when the combined path is active (fork `.separateCombinedScale`).
  public var separateCombinedScale: Bool {
    get { defaults.bool(forKey: "separateCombinedScale") }
    set { defaults.set(newValue, forKey: "separateCombinedScale") }
  }

  /// Show the contrast slider in the panel (fork `.showContrast`, default false).
  public var showContrast: Bool {
    get { defaults.bool(forKey: "showContrast") }
    set { defaults.set(newValue, forKey: "showContrast") }
  }

  /// What launch/reconfigure/wake does with saved DDC values (D5).
  ///
  /// D11: under safe mode the GETTER reports `.doNothing`, which disables both
  /// the startup restore and the wake restore (`RestoreCoordinator` gates on
  /// `== .write`) and the volume/contrast readback (`DDCValueController`
  /// gates on `== .read`) for the session. The SETTER still writes the real
  /// value through, so a pref changed during a safe-mode session takes effect
  /// on the next normal launch.
  public var startupAction: StartupAction {
    get {
      isSafeMode
        ? .doNothing
        : (StartupAction(rawValue: defaults.integer(forKey: "startupAction")) ?? .doNothing)
    }
    set { defaults.set(newValue.rawValue, forKey: "startupAction") }
  }

  /// Which display(s) the volume keys hit (D4).
  public var multiKeyboardVolume: MultiKeyboardVolume {
    get { MultiKeyboardVolume(rawValue: defaults.integer(forKey: "multiKeyboardVolume")) ?? .mouse }
    set { defaults.set(newValue.rawValue, forKey: "multiKeyboardVolume") }
  }

  public var menuIcon: MenuIcon {
    get { MenuIcon(rawValue: defaults.integer(forKey: "menuIcon")) ?? .show }
    set { defaults.set(newValue.rawValue, forKey: "menuIcon") }
  }

  /// Reserved and inert — see `MenuItemStyle` (D32).
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

  /// Reserved and inert (D32): nothing renders tick marks — Task 6 ships none.
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

  /// Where the brightness and contrast pills sit on the display they are drawn
  /// on. `HUDPosition` (defined with its placement math in `HUDPlacement`)
  /// stores `topRight` as 0, so an install that has never touched this keeps
  /// exactly the position the app always used.
  public var hudPositionBrightness: HUDPosition {
    get { HUDPosition(rawValue: defaults.integer(forKey: "hudPositionBrightness")) ?? .topRight }
    set { defaults.set(newValue.rawValue, forKey: "hudPositionBrightness") }
  }

  /// The volume and mute pills' own position. Separate from the brightness one
  /// so the two can be kept out of each other's way, and split along the same
  /// line `hideOsd` already draws: volume and mute on one side, brightness and
  /// contrast on the other.
  public var hudPositionVolume: HUDPosition {
    get { HUDPosition(rawValue: defaults.integer(forKey: "hudPositionVolume")) ?? .topRight }
    set { defaults.set(newValue.rawValue, forKey: "hudPositionVolume") }
  }

  /// Hide the built-in display's panel section (Candela's positive-default
  /// equivalent of the fork's dead hideAppleFromMenu — the filter WORKS here, D2).
  public var hideBuiltInDisplay: Bool {
    get { defaults.bool(forKey: "hideBuiltInDisplay") }
    set { defaults.set(newValue, forKey: "hideBuiltInDisplay") }
  }

  /// D26 escape hatch for #110, with NO UI by design. Default ON, so the
  /// stored form is the override rather than the setting: an absent key means
  /// guarded.
  ///
  /// Off, the mode picker again offers revealed modes at refreshes the panel
  /// has no native-width timing for — measured to scan out pillarboxed and
  /// cropped on the MAG 341C. It exists because the rule is inferred from ONE
  /// panel family's behaviour: a display the rule misjudges would otherwise
  /// lose good modes with no way back short of a new build.
  /// `object(forKey:)` decides only PRESENCE; `bool(forKey:)` reads the value.
  /// Casting the object to `Bool` instead looks equivalent and is not: the cast
  /// fails on `defaults write … wireTimingGuard NO`, which stores the STRING
  /// "NO", and the hatch would then silently do nothing for anyone who omitted
  /// `-bool`. Measured while verifying this key on hardware. `bool(forKey:)`
  /// coerces "NO", "0" and `0` the way every other pref here already does.
  public var wireTimingGuard: Bool {
    get {
      defaults.object(forKey: "wireTimingGuard") == nil
        ? true : defaults.bool(forKey: "wireTimingGuard")
    }
    set { defaults.set(newValue, forKey: "wireTimingGuard") }
  }

  // App-level keys. The key strings are shipped schema — never rename them.

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

  /// INVERTED on disk (fork key). UI binds through
  /// `interceptAlternateBrightnessKeys` below (D1).
  public var disableAltBrightnessKeys: Bool {
    get { defaults.bool(forKey: "disableAltBrightnessKeys") }
    set { defaults.set(newValue, forKey: "disableAltBrightnessKeys") }
  }

  // D1 binding-layer positives: checked-in-UI == true here == "off" on disk.

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

  /// SO22: whether ANYTHING has ever been stored for this display — prefs,
  /// saved levels, tuning. Every per-display key ends `".<persistenceKey>"`
  /// (this type's `key`/`commandKey`, the brightness/volume/contrast stores'
  /// `"<name>.<pk>"` storage keys), so an empty answer means the domain is
  /// genuinely fresh, which is what distinguishes "first time seeing this
  /// display" from "its settings failed to restore". A suffix scan, not a
  /// prefix: the persistence key is the TAIL of every stored key.
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
