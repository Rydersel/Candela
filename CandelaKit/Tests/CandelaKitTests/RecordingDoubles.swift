import CoreGraphics
import Foundation
@testable import CandelaKit

// The software-dimming test doubles, one each (#68). There were three gamma
// recorders and two shade recorders, each grown for one suite and each blind to
// what the others recorded.
//
// The surface here is the STRICT UNION of what they had, so no assertion
// anywhere got weaker in the merge. Where two of them recorded the same thing at
// different resolutions, the richer record wins and the coarser one stays as a
// derived property: `scales` is `calls.map(\.scale)` rather than a second array
// that could drift from it.

/// Records every gamma apply, every table verification, and every baseline
/// recapture, in order.
///
/// `events` is the ordered log and `calls` is the detailed one, and both are
/// needed. Interference tests assert on the INTERLEAVING of verify and apply,
/// which `calls` cannot show; the drawable-target tests assert that the write
/// target and the enforcer target differ, which `events` cannot show. Collapsing
/// either would have hidden the defect its suite exists to catch.
@MainActor
final class RecordingGamma: GammaApplying {
  enum Event: Equatable {
    case verify(CGDirectDisplayID)
    case apply(Double)
  }

  /// What `applyGammaScale` returns. False models a display that will not take
  /// a gamma table, which is what DT17's honest-failure reporting is about.
  var succeeds = true
  /// What `verifyTableIntact` returns. False models another app having taken the
  /// table (the f.lux case).
  var intact = true

  private(set) var events: [Event] = []
  /// Both display IDs of every apply. The separation of the write target from
  /// the enforcer target is the thing under test in the mirroring suites, so a
  /// double that collapsed them could not see the defect.
  private(set) var calls: [(scale: Double, write: CGDirectDisplayID, enforcer: CGDirectDisplayID)] = []
  private(set) var recaptured: [CGDirectDisplayID] = []
  private(set) var resetCount = 0

  /// The scales alone, in order. Derived rather than stored so it cannot drift
  /// from `calls`.
  var scales: [Double] { calls.map(\.scale) }
  /// The same list, reached through the event log. Kept under the name the
  /// interference suite used, since that suite reads it as "what came out of the
  /// event stream" rather than "what was applied".
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

/// Records every shade alpha, removal and re-pin.
@MainActor
final class RecordingShade: ShadeRendering {
  /// What `setShadeAlpha` returns. See `RecordingGamma.succeeds`.
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
