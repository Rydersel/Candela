import Foundation

/// Which software backend is carrying a software dimming leg.
///
/// Cases are named for what the user sees, never for the pref behind them:
/// `avoidGamma` never reaches a label.
public enum SoftwareDimmingBackend: Sendable, Equatable {
  /// The display's color profile (gamma table).
  case gamma
  /// A dark overlay window drawn over the screen.
  case overlay
}

/// Why nothing is moving this display's brightness.
///
/// Typed rather than a `String`: a reason composed in the view
/// drifts from the branch that produced it.
public enum BrightnessPathBlock: Sendable, Equatable {
  /// DDC brightness is turned off and there is no software leg to fall back
  /// on, either because combined dimming is off or because its switching point
  /// is 0, which gives the software leg a band of zero width.
  case ddcTurnedOffWithNoSoftwareLeg
  /// The same corner, reached because the WIRE stopped answering. Its own case
  /// because only one of the two names a switch the user can put back.
  case ddcUnresponsiveWithNoSoftwareLeg
}

/// Why a display CONFIGURED for a hardware leg is nevertheless running on the
/// software leg alone.
///
/// Typed for the same reason as `BrightnessPathBlock`, and
/// kept apart from it: a block means nothing responds, this means part of the
/// range still does.
public enum SoftwareOnlyReason: Sendable, Equatable {
  /// DDC brightness is turned off for this display (`unavailableDDC` on the
  /// brightness command), so only combined mode's software half runs.
  case ddcTurnedOff
  /// DDC writes have been failing in a row (`DDCWireHealth`), so combined
  /// mode's hardware half submits into a wire that is not carrying it. Apart
  /// from `ddcTurnedOff` because only one is something the user did.
  case ddcUnresponsive
}

/// What is ACTUALLY moving this display's brightness right now.
public enum BrightnessPath: Sendable, Equatable {
  /// DisplayServices native brightness only, full range. Built-in, or HDR live.
  case native
  /// The software leg only, full range.
  case software(SoftwareDimmingBackend)
  /// DDC only, full range.
  case hardware
  /// Split: below `switchingValue` the software leg dims and DDC holds at its
  /// floor; above it, DDC carries the whole range.
  ///
  /// Reachable ONLY with a live DDC leg; see `BrightnessPathPolicy.path`.
  case combined(switchingValue: Double, backend: SoftwareDimmingBackend)
  /// Combined dimming is configured but its hardware half is not running, so
  /// the software leg carries a PARTIAL range: below `dimsBelow` it dims, at or
  /// above it nothing moves. `dimsBelow` is always greater than 0; a zero-width
  /// band is `.unavailable(.ddcTurnedOffWithNoSoftwareLeg)`.
  case softwareOnly(
    backend: SoftwareDimmingBackend, reason: SoftwareOnlyReason, dimsBelow: Double
  )
  /// Nothing can move this display's brightness, and why.
  case unavailable(BrightnessPathBlock)
}

public extension BrightnessPath {
  /// Whether this path drives the display's brightness REGISTER. A question
  /// about the wire, not the slider: the software leg moves the display and
  /// still answers false.
  ///
  /// Software dimming only subtracts, so it assumes a register at full range. A
  /// path that stops driving the register inherits wherever the last one left
  /// it, and combined mode leaves it at the hardware floor below the switching
  /// point: the app then reports 100% over a panel at minimum backlight.
  var drivesDDCBrightness: Bool {
    switch self {
    case .combined, .hardware: true
    case .native, .software, .softwareOnly, .unavailable: false
    }
  }
}

/// The path table from `BrightnessController.applyPaths`, stated ONCE, in the
/// Kit, under test.
///
/// The engine consults this rather than carrying its own copy. `applyPaths`,
/// `usesNative` and `softwareBackendChoice` are private, so a pane would
/// otherwise re-derive path selection from prefs and drift from it.
public enum BrightnessPathPolicy {
  public struct Inputs: Sendable, Equatable {
    public let role: DisplayRole
    public let isHDRActive: Bool
    public let forceSoftware: Bool
    public let avoidGamma: Bool
    public let disableCombinedBrightness: Bool
    /// `prefs.tuning(for: .brightness).unavailableDDC`.
    public let unavailableDDC: Bool
    /// `DDCWireHealth.isUnresponsive` for this display's wire.
    public let wireUnresponsive: Bool
    /// `DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint)`.
    public let switchingValue: Double

    public init(
      role: DisplayRole,
      isHDRActive: Bool,
      forceSoftware: Bool,
      avoidGamma: Bool,
      disableCombinedBrightness: Bool,
      unavailableDDC: Bool,
      switchingValue: Double,
      // Defaulted for callers with no wire: the standalone predicate and the
      // pane-side projections. The engine passes it.
      wireUnresponsive: Bool = false
    ) {
      self.role = role
      self.isHDRActive = isHDRActive
      self.forceSoftware = forceSoftware
      self.avoidGamma = avoidGamma
      self.disableCombinedBrightness = disableCombinedBrightness
      self.unavailableDDC = unavailableDDC
      self.switchingValue = switchingValue
      self.wireUnresponsive = wireUnresponsive
    }
  }

  /// ORDER IS THE CONTRACT, and it is the MonitorControl fork's order:
  /// native, then force-software, then combined, then pure DDC.
  ///
  /// `unavailableDDC` is checked INSIDE the combined branch. Hoisting it above
  /// would report a display that still dims on its software leg as dead;
  /// ignoring it inside would hand out `.combined`, which `DisplayCardPolicy`
  /// captions as hardware control over a wire that is off (ruling R-A). The
  /// separate case makes that untruth unrepresentable.
  ///
  /// `wireUnresponsive` sits BELOW `unavailableDDC` in both branches: a control
  /// the user turned off reads as turned off whatever the wire is doing.
  /// `switchingValue == 0` gives the software band zero width, so nothing moves
  /// and the honest answer is the block.
  public static func path(_ inputs: Inputs) -> BrightnessPath {
    if usesNative(role: inputs.role, isHDRActive: inputs.isHDRActive) {
      return .native
    }
    let backend: SoftwareDimmingBackend = inputs.avoidGamma ? .overlay : .gamma
    if inputs.forceSoftware {
      return .software(backend)
    }
    if !inputs.disableCombinedBrightness {
      guard !inputs.unavailableDDC else {
        guard inputs.switchingValue > 0 else {
          return .unavailable(.ddcTurnedOffWithNoSoftwareLeg)
        }
        return .softwareOnly(
          backend: backend, reason: .ddcTurnedOff, dimsBelow: inputs.switchingValue
        )
      }
      guard !inputs.wireUnresponsive else {
        guard inputs.switchingValue > 0 else {
          return .unavailable(.ddcUnresponsiveWithNoSoftwareLeg)
        }
        return .softwareOnly(
          backend: backend, reason: .ddcUnresponsive, dimsBelow: inputs.switchingValue
        )
      }
      return .combined(switchingValue: inputs.switchingValue, backend: backend)
    }
    guard !inputs.unavailableDDC else {
      return .unavailable(.ddcTurnedOffWithNoSoftwareLeg)
    }
    // Full-range software leg: no combined split to respect here, and the
    // demotion exists so the display still dims.
    if inputs.wireUnresponsive {
      return .software(backend)
    }
    return .hardware
  }

  /// The native predicate on its own, for hot paths that need it without
  /// building an `Inputs`.
  ///
  /// Live HDR is the condition, never Candela's own HDR mode. With HDR off the
  /// MAG341C answers `DisplayServicesSetBrightness` with SUCCESS and changes
  /// nothing, so a mode alone must not route native; System Settings can engage
  /// HDR while our mode is `.off`, where DDC writes cannot land, so live HDR
  /// routes native whoever turned it on. Role `.builtIn` has no DDC wire.
  public static func usesNative(role: DisplayRole, isHDRActive: Bool) -> Bool {
    role == .builtIn || isHDRActive
  }
}
