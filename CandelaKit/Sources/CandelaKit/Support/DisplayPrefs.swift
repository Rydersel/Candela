import Foundation

/// How a display uses macOS HDR. `alwaysOn` keeps HDR engaged; `off` leaves the
/// display's HDR state alone.
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

/// Fork MultiKeyboardVolume: which display(s) the volume keys hit.
public enum MultiKeyboardVolume: Int, Sendable, CaseIterable {
  case mouse = 0
  case allScreens = 1
  case audioDeviceNameMatching = 2
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

  public init(defaults: UserDefaults = .standard, persistenceKey: String) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey
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

  // MARK: - Per-command DDC tuning (M4, engine-level per D2 — settings UI is M5;
  // test via `defaults write` + candela-probe)

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

  /// Manual override for the panel's audio-sink detection: force the volume
  /// slider into its disabled state even when the display DOES enumerate as a
  /// CoreAudio output. For panels that declare audio in their EDID but have
  /// neither speakers nor a jack to play it through — detection cannot tell
  /// those from a jack-equipped panel, so this is the escape hatch. It never
  /// works in reverse: a display with no audio sink stays disabled regardless.
  public var forceNoAudioOutput: Bool {
    get { defaults.bool(forKey: key("forceNoAudioOutput")) }
    set { defaults.set(newValue, forKey: key("forceNoAudioOutput")) }
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
  public var pollingTries: Int {
    switch pollingMode {
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
  public var startupAction: StartupAction {
    get { StartupAction(rawValue: defaults.integer(forKey: "startupAction")) ?? .doNothing }
    set { defaults.set(newValue.rawValue, forKey: "startupAction") }
  }

  /// Which display(s) the volume keys hit (D4).
  public var multiKeyboardVolume: MultiKeyboardVolume {
    get { MultiKeyboardVolume(rawValue: defaults.integer(forKey: "multiKeyboardVolume")) ?? .mouse }
    set { defaults.set(newValue.rawValue, forKey: "multiKeyboardVolume") }
  }

  private func key(_ name: String) -> String {
    "\(name).\(persistenceKey)"
  }

  private func clampSwitchingPoint(_ point: Int) -> Int {
    min(max(point, DimmingMath.switchingPointRange.lowerBound), DimmingMath.switchingPointRange.upperBound)
  }
}
