import Foundation

/// Which software backend is carrying a software dimming leg.
///
/// Named for what the user sees, never for the pref behind it (D25):
/// `avoidGamma` never reaches a label.
public enum SoftwareDimmingBackend: Sendable, Equatable {
  /// The display's color profile (gamma table).
  case gamma
  /// A dark overlay window drawn over the screen.
  case overlay
}

/// Why nothing is moving this display's brightness.
///
/// A separate type rather than a `String`, because DT30 rule (a) requires every
/// "unavailable" row to draw its reason from a TYPED value — a reason composed
/// in the view is a reason that drifts from the branch that produced it.
public enum BrightnessPathBlock: Sendable, Equatable {
  /// No leg carries the value: DDC brightness is turned off for this display
  /// AND there is no software leg to fall back on — either because combined
  /// dimming is off (branch 4 of `applyPaths` submits nothing at all), or
  /// because combined dimming is on with the switching point at 0, which gives
  /// the software leg a band of zero width.
  case ddcTurnedOffWithNoSoftwareLeg
}

/// Why a display CONFIGURED for a hardware leg is nevertheless running on the
/// software leg alone.
///
/// The sibling of `BrightnessPathBlock`, and typed for the same reason (DT30
/// rule (a)). The two are kept apart because the consequences differ and the
/// user-visible sentence differs with them: a block means nothing at all
/// responds, while this means part of the range still responds and the rest
/// does not.
public enum SoftwareOnlyReason: Sendable, Equatable {
  /// DDC brightness is turned off for this display (`unavailableDDC` on the
  /// brightness command), so combined mode's hardware submit is skipped and
  /// only its software half runs.
  case ddcTurnedOff
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
  /// Reachable ONLY with a live DDC leg — see `BrightnessPathPolicy.path`, and
  /// the ruling recorded there.
  case combined(switchingValue: Double, backend: SoftwareDimmingBackend)
  /// Combined dimming is configured but its hardware half is not running, so
  /// the software leg is carrying the display by itself over a PARTIAL range:
  /// values below `dimsBelow` dim, and values at or above it move nothing,
  /// because `DimmingMath.combinedSplit` hands the software leg a flat `1`
  /// there and hands the rest to a DDC submit that never happens.
  ///
  /// `dimsBelow` is always greater than 0 — a zero-width software band is a
  /// `.unavailable(.ddcTurnedOffWithNoSoftwareLeg)`, not a leg that dims below
  /// nothing.
  case softwareOnly(
    backend: SoftwareDimmingBackend, reason: SoftwareOnlyReason, dimsBelow: Double
  )
  /// Nothing can move this display's brightness, and why.
  case unavailable(BrightnessPathBlock)
}

public extension BrightnessPath {
  /// Whether this path puts the display's brightness REGISTER under Candela's
  /// control. Read it as a question about the wire, not about the slider: a
  /// path can move the display (the software leg does) and still answer false.
  ///
  /// The false answers are what matter, and #143 is why they are worth naming.
  /// Software dimming can only ever subtract from whatever the panel is already
  /// emitting, so it assumes a register at full range. A path that stops
  /// driving the register therefore inherits wherever the previous path left
  /// it, and combined mode leaves it at the hardware floor for every value
  /// below the switching point: the app then reports 100% over a panel at its
  /// minimum backlight, with the gamma table already at 1.0 and nothing left to
  /// brighten with.
  var drivesDDCBrightness: Bool {
    switch self {
    case .combined, .hardware: true
    case .native, .software, .softwareOnly, .unavailable: false
    }
  }
}

/// The four-branch path table from `BrightnessController.applyPaths`, stated
/// ONCE, in the Kit, under test.
///
/// The engine CONSULTS this (Task 3) rather than carrying its own copy. That is
/// what makes "the diagnostics pane cannot drift from the engine" structural
/// instead of a promise: `applyPaths`, `usesNative` and `softwareBackendChoice`
/// are all private, so a pane would otherwise have to re-derive path selection
/// from prefs — a second copy of a four-branch table, which drifts.
public enum BrightnessPathPolicy {
  public struct Inputs: Sendable, Equatable {
    public let role: DisplayRole
    public let isHDRActive: Bool
    public let forceSoftware: Bool
    public let avoidGamma: Bool
    public let disableCombinedBrightness: Bool
    /// `prefs.tuning(for: .brightness).unavailableDDC`.
    public let unavailableDDC: Bool
    /// `DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint)`.
    public let switchingValue: Double

    public init(
      role: DisplayRole,
      isHDRActive: Bool,
      forceSoftware: Bool,
      avoidGamma: Bool,
      disableCombinedBrightness: Bool,
      unavailableDDC: Bool,
      switchingValue: Double
    ) {
      self.role = role
      self.isHDRActive = isHDRActive
      self.forceSoftware = forceSoftware
      self.avoidGamma = avoidGamma
      self.disableCombinedBrightness = disableCombinedBrightness
      self.unavailableDDC = unavailableDDC
      self.switchingValue = switchingValue
    }
  }

  /// ORDER IS THE CONTRACT, and it is the fork's order (dossier §2/§10):
  /// native, then force-software, then combined, then pure DDC.
  ///
  /// The `unavailableDDC` check is deliberately placed INSIDE the combined
  /// branch, and both halves of that placement are load-bearing:
  ///
  /// - Not ABOVE it. Hoisting it is the tempting simplification and it is
  ///   wrong: in combined mode the software leg still dims, so answering
  ///   `.unavailable` there would report a display that visibly responds to the
  ///   slider as dead.
  /// - Not IGNORED inside it either — controller ruling R-A, and the reason
  ///   this file is worth having. `.combined` means "DDC carries the top of the
  ///   range", which is exactly what a display with its DDC leg turned off is
  ///   NOT doing; `DisplayCardPolicy` projects `.combined` to "Hardware (DDC)
  ///   control", so returning it here would caption a dead wire as hardware
  ///   control in the one feature built to tell the truth about that. The
  ///   untruth is unrepresentable rather than merely avoided: this state has
  ///   its own case, so no consumer switching over `BrightnessPath` can receive
  ///   a `.combined` whose hardware half is not running.
  ///
  /// `switchingValue == 0` (pref point −8, "pure hardware") is the corner of
  /// that same state where the software band has zero width — `combinedSplit`'s
  /// hardware branch always wins — so nothing moves at all and the honest
  /// answer is the block, not a leg advertised as dimming below 0%.
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
      return .combined(switchingValue: inputs.switchingValue, backend: backend)
    }
    guard !inputs.unavailableDDC else {
      return .unavailable(.ddcTurnedOffWithNoSoftwareLeg)
    }
    return .hardware
  }

  /// The native predicate on its own, for the hot paths that need it without
  /// building an `Inputs`.
  ///
  /// Live HDR is the condition; Candela's own HDR *mode* is deliberately not
  /// an input, and both directions of that were paid for. With HDR off the
  /// MAG341C answers `DisplayServicesSetBrightness` with SUCCESS and changes
  /// nothing, so a mode alone must never route native. And System Settings can
  /// engage HDR with our mode still `.off` — where DDC writes cannot land — so
  /// live HDR must route native whoever turned it on (#52). Role `.builtIn` is
  /// constitutively native — no DDC wire, no combined/software routing.
  public static func usesNative(role: DisplayRole, isHDRActive: Bool) -> Bool {
    role == .builtIn || isHDRActive
  }
}
