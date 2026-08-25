import CoreGraphics
import Foundation

/// A display's orientation, as one of the only four values the platform accepts.
///
/// **RT6 — closed, not an `Int`.** `SLSSetDisplayRotation` refuses `45` with
/// `kCGErrorIllegalArgument`, which is the safe half. The dangerous half is that
/// `-90` and `360` return `CGError` **0 and do nothing** (RS5) — so the obvious
/// spelling of "rotate counter-clockwise" is silently ignored while reporting
/// success. A raw-integer API would make that the natural thing to write.
public enum DisplayRotation: Int, Sendable, CaseIterable, Codable {
  case standard = 0
  case ninety = 90
  case oneEighty = 180
  case twoSeventy = 270

  /// From a `CGDisplayRotation` reading, which is degrees as a `Double`.
  ///
  /// **RT7 — `nil` rather than a nearest match.** A display reporting 45° is one
  /// this feature must decline to describe, not one it should round into a lie.
  /// The tolerance is for float representation only, not for snapping.
  public init?(degrees: Double) {
    guard degrees.isFinite else { return nil }
    let rounded = degrees.rounded()
    guard abs(degrees - rounded) < 0.001, let value = Self(rawValue: Int(rounded)) else {
      return nil
    }
    self = value
  }

  public var degrees: Int32 { Int32(rawValue) }

  /// 90 and 270 exchange the display's width and height — measured, not assumed:
  /// the MAG went 3440×1440 → 1440×3440 and its reported *mode* changed with it
  /// (RS3). This is why a curated mode list captured before a rotation describes
  /// the other orientation.
  public var swapsAxes: Bool { self == .ninety || self == .twoSeventy }
}

/// Why a rotation was not attempted. Four, and each is stated to the user rather
/// than collapsed into "it did not work".
///
/// **RT13** — deliberately short. A refusal list that guesses at what the
/// hardware will refuse goes stale. Mirroring needed eight because CoreGraphics
/// really does refuse eight ways; rotation is not known to refuse at all, so
/// anything not listed here is attempted and the verification in
/// `applyRotation` produces a truthful failure if it does not take.
public enum RotationRefusal: Sendable, Equatable {
  /// This build cannot rotate: the SkyLight symbol did not resolve (RT5).
  case unavailable
  /// The display departed between the request and the apply.
  case displayGone
  /// The display reports an orientation that is not a right angle, so there is
  /// no honest "from" to show or to revert to (RT7).
  case unreadable
  /// The requested angle is already the current one. No countdown opens — a
  /// no-op that starts a 30-second timer is a bug, not a courtesy.
  case unchanged(DisplayRotation)
}

/// A rotation that policy has approved. Carries `from` because the revert path
/// needs it and because the confirmation names both ends.
public struct RotationRequest: Sendable, Equatable {
  public let display: CGDirectDisplayID
  public let from: DisplayRotation
  public let to: DisplayRotation

  public init(display: CGDirectDisplayID, from: DisplayRotation, to: DisplayRotation) {
    self.display = display
    self.from = from
    self.to = to
  }
}

public enum RotationDecision: Sendable, Equatable {
  case rotate(RotationRequest)
  case refused(RotationRefusal)
}

/// The whole decision, in one pure function, for the same reason
/// `MirrorTopologyPolicy` is one: it is the part worth testing exhaustively, and
/// it must not be able to drift from what the UI claims.
public enum RotationPolicy {
  public static func decide(
    display: CGDirectDisplayID,
    to requested: DisplayRotation,
    in displays: [ConfiguredDisplay],
    currentRotation: DisplayRotation?,
    isSupported: Bool
  ) -> RotationDecision {
    guard isSupported else { return .refused(.unavailable) }
    guard displays.contains(where: { $0.id == display }) else { return .refused(.displayGone) }
    guard let current = currentRotation else { return .refused(.unreadable) }
    guard current != requested else { return .refused(.unchanged(current)) }
    return .rotate(RotationRequest(display: display, from: current, to: requested))
  }
}
