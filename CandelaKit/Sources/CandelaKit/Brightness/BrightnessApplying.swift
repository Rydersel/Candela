import CoreGraphics
import os

/// Wiring-bug diagnostics for the appliers: a mismatched target kind means
/// path selection handed a target to the wrong applier.
///
/// **Every line in this category is an assertion about the APP.** The tests
/// that exercise the guards therefore never reach it: they inject a recorder
/// (see `ApplierMismatchReporting`). The test process logs into this same
/// subsystem, so a line written by `swiftpm-testing-helper` reads exactly like a
/// line written by Candela. That is the whole of #148, which read three lines
/// per `swift test` run as three per app launch.
let applierLog = Logger(subsystem: "com.rydersel.Candela", category: "applier")

/// One hardware brightness endpoint's target value. `Equatable` so the
/// coalescer's duplicate-skip compares what actually hits hardware,
/// independent of which applier carries the write.
public enum HardwareTarget: Sendable, Equatable {
  /// Raw DDC value (0...maxDDCValue) for the applier's command — brightness
  /// VCP 0x10 by default, but a remapped or non-brightness command's raw
  /// rides the same case; the code lives with the writer, not here.
  case ddc(raw: UInt16)
  /// Native Apple-display brightness in 0...1 (DisplayServices).
  case native(Float)

  /// The target's kind, stripped of its payload, so a pairing can be compared
  /// without unwrapping a value nothing here needs.
  public var kind: HardwareTargetKind {
    switch self {
    case .ddc: .ddc
    case .native: .native
    }
  }
}

/// Which endpoint a target names, and which endpoint an applier carries.
public enum HardwareTargetKind: Sendable, Equatable {
  case ddc
  case native
}

/// Where a pairing mismatch is reported. Production leaves it nil and the line
/// reaches `applierLog`; a test that deliberately drives the guard passes a
/// recorder, which both keeps the app's assertion channel clean (#148) and
/// turns "it logged" into something a test can actually assert.
public typealias ApplierMismatchReporting = @Sendable (String) -> Void

/// Applies one hardware brightness target. Implementations serialize their
/// own I/O.
public protocol BrightnessApplying: Sendable {
  /// The one kind of target this applier carries. Every other kind is a
  /// path-selection wiring bug and is rejected by `apply`.
  ///
  /// Stated here rather than left implicit in `apply`'s pattern match so the
  /// pairing is a checkable invariant: a mismatch used to be observable only as
  /// a log line two layers downstream of the site that chose the applier, and a
  /// log line is only an assertion if somebody reads it (#148).
  var accepts: HardwareTargetKind { get }

  func apply(_ target: HardwareTarget) async -> Bool
}

/// Native-brightness applier over an injected apply closure: the app injects
/// `DisplayServices.setBrightness`; injection keeps this type (and CandelaKit
/// tests) independent of the private-framework shim. A `.ddc` target is a
/// path-selection wiring bug: rejected (`false`), reported once per instance.
public struct NativeBrightnessApplier: BrightnessApplying {
  public let accepts = HardwareTargetKind.native

  /// Per-instance, not static (review M2): with multiple displays a static
  /// flag would let the first display's wiring bug suppress the report for all
  /// others. Copies share the lock's heap storage, so copies of one instance
  /// still report once; the per-submit-constructed applier reports once per
  /// affected write, which is acceptable: a live wiring bug is a must-fix.
  private let mismatchReported = OSAllocatedUnfairLock(initialState: false)
  private let displayID: CGDirectDisplayID
  private let applyNative: @Sendable (Float, CGDirectDisplayID) -> Bool
  private let onMismatch: ApplierMismatchReporting?

  public init(
    displayID: CGDirectDisplayID,
    apply: @escaping @Sendable (Float, CGDirectDisplayID) -> Bool,
    onMismatch: ApplierMismatchReporting? = nil
  ) {
    self.displayID = displayID
    self.applyNative = apply
    self.onMismatch = onMismatch
  }

  public func apply(_ target: HardwareTarget) async -> Bool {
    guard case let .native(value) = target else {
      reportMismatchOnce(
        mismatchReported, "NativeBrightnessApplier received a .ddc target", to: onMismatch
      )
      return false
    }
    return applyNative(value, displayID)
  }
}

/// Reports `message` only the first time its (per-instance) flag is seen unset:
/// repeated mismatches on the same applier instance produce one report.
///
/// `report` receives exactly the line production would log, so a test asserting
/// on it is asserting on the real diagnostic and not on a paraphrase.
func reportMismatchOnce(
  _ flag: OSAllocatedUnfairLock<Bool>,
  _ message: String,
  to report: ApplierMismatchReporting?
) {
  let firstTime = flag.withLock { reported -> Bool in
    if reported { return false }
    reported = true
    return true
  }
  guard firstTime else { return }
  let line = "\(message) (path-selection wiring bug)"
  if let report {
    report(line)
  } else {
    applierLog.error("\(line, privacy: .public)")
  }
}
