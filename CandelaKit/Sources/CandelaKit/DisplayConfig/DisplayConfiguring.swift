import CoreGraphics
import Foundation

/// How long an applied mode should last.
///
/// `Equatable` is declared here rather than added by a test-side extension:
/// it is our own type in our own module, so a `@retroactive` conformance
/// would be both unnecessary and wrong.
public enum DisplayConfigScope: Sendable, Equatable {
  /// `kCGConfigureForAppOnly` — reverts when this process exits, including on
  /// a crash. The safe way to show someone a mode before committing to it.
  case preview
  /// `kCGConfigureForSession` — outlives the process.
  case session
}

/// A display that can be reconfigured. Unlike `ExternalDisplay` this includes
/// the built-in panel and any virtual displays, because mode switching applies
/// to all of them.
public struct ConfiguredDisplay: Sendable, Equatable, Identifiable {
  public let id: CGDirectDisplayID
  public let identity: DisplayConfigIdentity
  public let name: String
  public let isBuiltIn: Bool
  /// The display whose content this one is SHOWING, or `kCGNullDirectDisplay`
  /// when it is showing its own — `CGDisplayMirrorsDisplay`, sampled at the same
  /// instant as the list itself so a caller cannot ask about a topology that has
  /// moved on.
  ///
  /// Carried because `displays()` enumerates ONLINE displays, and "online" means
  /// active, asleep, **or mirrored**: a hardware-mirrored secondary appears here
  /// while appearing in no active list at all. Reapply reads absence from this
  /// list as a departure, so it necessarily sees mirror slaves as arrivals too,
  /// and something has to be able to tell them apart.
  ///
  /// The MASTER of a mirror set reports null here and is a perfectly ordinary
  /// display: it owns the framebuffer everyone in the set is showing, and its
  /// resolution is the set's resolution.
  public let mirrorsDisplay: CGDirectDisplayID

  /// True for the SLAVE of a mirror set only. Its own mode decides almost
  /// nothing while the mirror lasts — the pixels on it come from the master —
  /// so it is not a display an unattended pass should be reconfiguring.
  public var isMirrorSlave: Bool { mirrorsDisplay != kCGNullDirectDisplay }

  public init(
    id: CGDirectDisplayID,
    identity: DisplayConfigIdentity,
    name: String,
    isBuiltIn: Bool,
    mirrorsDisplay: CGDirectDisplayID = kCGNullDirectDisplay
  ) {
    self.id = id
    self.identity = identity
    self.name = name
    self.isBuiltIn = isBuiltIn
    self.mirrorsDisplay = mirrorsDisplay
  }
}

public struct DisplayConfigError: Error, Sendable, Equatable {
  public let cgErrorCode: Int32
  public init(cgErrorCode: Int32) { self.cgErrorCode = cgErrorCode }
}

/// The seam between display-configuration policy and CoreGraphics. Everything
/// decidable is tested against a fake conformance; the real one is a thin
/// adapter with no judgement in it.
public protocol DisplayConfiguring: Sendable {
  /// Every display that is ONLINE — connected and powered, whether or not it is
  /// currently drawing. Deliberately not "active": callers read absence from
  /// this list as a DEPARTURE, and a display asleep on the idle timer is
  /// inactive without having gone anywhere. See
  /// `CoreGraphicsDisplayConfigurator.displays()`.
  func displays() -> [ConfiguredDisplay]
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode]
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode?
  /// The panel's own pixel count, from the mode flagged native. Needed to tell
  /// scaled modes from native ones.
  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)?
  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws
}
