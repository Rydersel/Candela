import CoreGraphics
import Foundation
@testable import CandelaKit

/// Both `events` and `calls` are needed. Interference tests assert on the
/// interleaving of verify and apply, which `calls` cannot show; drawable-target
/// tests assert the write target differs from the enforcer target, which
/// `events` cannot show.
@MainActor
final class RecordingGamma: GammaApplying {
  enum Event: Equatable {
    case verify(CGDirectDisplayID)
    case apply(Double)
  }

  /// False models a display that will not take a gamma table (honest-failure
  /// reporting).
  var succeeds = true
  /// False models another app having taken the table (the f.lux case).
  var intact = true

  private(set) var events: [Event] = []
  /// Both display IDs of every apply. The mirroring suites test that the write
  /// target and the enforcer target stay separate, so collapsing them here
  /// would hide the defect.
  private(set) var calls: [(scale: Double, write: CGDirectDisplayID, enforcer: CGDirectDisplayID)] = []
  private(set) var recaptured: [CGDirectDisplayID] = []
  private(set) var resetCount = 0

  /// Derived rather than stored so it cannot drift from `calls`.
  var scales: [Double] { calls.map(\.scale) }
  /// The same list read out of the event stream rather than out of `calls`.
  var appliedScales: [Double] {
    events.compactMap { if case let .apply(scale) = $0 { scale } else { nil } }
  }

  var verifyCount: Int {
    events.filter { if case .verify = $0 { true } else { false } }.count
  }

  @discardableResult
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID, enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    events.append(.apply(scale))
    calls.append((scale, displayID, drawableDisplayID))
    return succeeds
  }

  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool {
    events.append(.verify(displayID))
    return intact
  }

  func recaptureDefaultTable(on displayID: CGDirectDisplayID) { recaptured.append(displayID) }
  func resetAllGamma() { resetCount += 1 }
}

@MainActor
final class RecordingShade: ShadeRendering {
  /// See `RecordingGamma.succeeds`.
  var succeeds = true

  private(set) var alphaCalls: [(alpha: Double, id: CGDirectDisplayID)] = []
  private(set) var removed: [CGDirectDisplayID] = []
  private(set) var removeAllCount = 0
  private(set) var repinCount = 0

  @discardableResult
  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) -> Bool {
    alphaCalls.append((alpha, displayID))
    return succeeds
  }

  func removeShade(for displayID: CGDirectDisplayID) { removed.append(displayID) }
  func removeAllShades() { removeAllCount += 1 }
  func repinFrames() { repinCount += 1 }
}
