import CoreGraphics
import Foundation

/// What the caller asks a virtual display to be. Values are the SOURCE OF
/// TRUTH: nothing is ever read back from a live virtual display (VD5), so a
/// spec change means destroy-and-recreate under the same slot (VD1).
public struct VirtualDisplaySpec: Sendable, Equatable {
  public var name: String
  public var logicalWidth: Int
  public var logicalHeight: Int
  public var hiDPI: Bool
  public var refreshHz: Double

  public init(name: String, logicalWidth: Int, logicalHeight: Int, hiDPI: Bool, refreshHz: Double) {
    self.name = name
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.hiDPI = hiDPI
    self.refreshHz = refreshHz
  }

  /// Both axes rounded DOWN to even, clamped to the advertised pixel ceiling,
  /// refresh quantized through `DisplayMode.quantizedRefresh`. The only place
  /// these rules live.
  ///
  /// The even rounding is DEFENSIVE: S2 recorded odd dimensions silently
  /// yielding non-HiDPI once, and a follow-up could not reproduce parity as the
  /// cause. Kept because it costs nothing and the failure is unexplained.
  ///
  /// The ceiling clamp is not defensive: prefs are an escape-hatch surface
  /// (defaults write), and an unclamped width would trap the UInt32 conversion
  /// in the host on every launch with no way back from inside the app.
  public var normalized: VirtualDisplaySpec {
    var copy = self
    copy.logicalWidth = min(
      VirtualDisplayIdentity.maxPixels.wide, max(2, logicalWidth - logicalWidth % 2)
    )
    copy.logicalHeight = min(
      VirtualDisplayIdentity.maxPixels.high, max(2, logicalHeight - logicalHeight % 2)
    )
    copy.refreshHz = DisplayMode.quantizedRefresh(refreshHz)
    return copy
  }
}

/// One live virtual display.
///
/// `uuid` is the identity everything hangs off across recreation and
/// relaunch (VD9); `displayID` is a RUNTIME handle that differs on every
/// creation. An identical descriptor re-created after release produced
/// 63 -> 64, and IDs climbed 7 -> 133 across one session, so nothing may be
/// keyed on it.
public struct VirtualDisplayHandle: Sendable, Equatable {
  public let uuid: UUID
  public let slot: Int
  public let displayID: CGDirectDisplayID
  public let identity: DisplayConfigIdentity
  /// Normalized. This is what the display IS; the live object is never asked.
  public let spec: VirtualDisplaySpec

  public init(
    uuid: UUID, slot: Int, displayID: CGDirectDisplayID,
    identity: DisplayConfigIdentity, spec: VirtualDisplaySpec
  ) {
    self.uuid = uuid
    self.slot = slot
    self.displayID = displayID
    self.identity = identity
    self.spec = spec
  }
}

public enum VirtualDisplayFailure: Error, Sendable, Equatable {
  /// `NSClassFromString` returned nil for one of the private classes. Every
  /// entry point is then inert; the whole class family is private, so there is
  /// no public path to degrade to (VD10).
  case classFamilyUnavailable
  /// The slot is outside `VirtualDisplayIdentity.slotRange` or already live.
  case capExceeded
  /// `initWithDescriptor:` returned nil.
  case refused
  /// `initWithDescriptor:` produced `displayID == 0`: the measured
  /// duplicate-identity refusal. Unreachable under the product-per-slot scheme,
  /// and kept because it is a PROTECTION, never to be defeated by randomising
  /// the identity.
  case identityInUse
  /// `applySettings:` returned NO, the only creation-failure signal it gives:
  /// an empty mode list returns NO and the display never appears.
  case settingsRejected
  /// Created, but never appeared in `CGGetOnlineDisplayList` before the
  /// deadline. Released before reporting; a half-created display is exactly
  /// the thing later code would treat as live.
  case neverAppearedOnline
  /// `CGMainDisplayID()` moved across the creation, and the display was
  /// destroyed before this was returned. Destroy-and-report rather than
  /// move-it-back: main-display transaction semantics are unverified, and
  /// nothing may risk state that outlives the process.
  case wouldBecomeMainDisplay
  /// A destroy released the display but it stayed in the online list past
  /// the deadline. The slot is stranded for the session: the token is gone,
  /// so nothing can destroy it again, and its identity is still advertised.
  case didNotDepart
}

/// The lifetime seam for displays Candela creates.
///
/// A SIBLING of `DisplayConfiguring`, never a member of it: that protocol is a
/// thin adapter over PUBLIC CoreGraphics, while creation is private-API and
/// fallible in ways `apply` is not, and adding a requirement there would force
/// every existing fake to grow a conformance for something it will never do.
///
/// Everything is synchronous and everything can block: `create` and `destroy`
/// poll the online list. It is therefore FORBIDDEN to call either on the main
/// thread during an NSMenu tracking session; menu tracking starves main-actor
/// work, measured twice in this project.
public protocol VirtualDisplayProviding: Sendable {
  /// False when the private class family is absent. Every other member is
  /// then inert: `create` fails every spec, `live()` is empty, `destroy` is
  /// a no-op.
  var isAvailable: Bool { get }

  /// Synchronously readable, and the ONLY authority on "did Candela create
  /// this?" (VD12). Consumed by `DisplayDiscovery.discover(excluding:)`.
  var ownedDisplayIDs: Set<CGDirectDisplayID> { get }

  func live() -> [VirtualDisplayHandle]

  func create(
    _ spec: VirtualDisplaySpec, slot: Int, uuid: UUID, appearanceTimeout: TimeInterval
  ) -> Result<VirtualDisplayHandle, VirtualDisplayFailure>

  /// Releases the slot's display and polls the online list until it is gone.
  /// Returns false if it was still online at the deadline; it reports rather
  /// than hangs. Idempotent; a slot with no live display is a no-op. Candela
  /// never destroys a display it does not own (VD12).
  @discardableResult
  func destroy(slot: Int, departureTimeout: TimeInterval) -> Bool

  @discardableResult
  func destroyAll(departureTimeout: TimeInterval) -> Bool
}
