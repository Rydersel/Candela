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

  public init(id: CGDirectDisplayID, identity: DisplayConfigIdentity, name: String, isBuiltIn: Bool) {
    self.id = id
    self.identity = identity
    self.name = name
    self.isBuiltIn = isBuiltIn
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
  func displays() -> [ConfiguredDisplay]
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode]
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode?
  /// The panel's own pixel count, from the mode flagged native. Needed to tell
  /// scaled modes from native ones.
  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)?
  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws
}
