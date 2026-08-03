import Foundation

/// Stable per-display key for display-configuration state.
///
/// Deliberately NOT `DisplayDiscovery.persistenceKey`, which is derived from an
/// `Arm64DDC.IOregService` and therefore exists only for DDC-capable externals.
/// Mode switching applies to the built-in display and to virtual displays too,
/// so identity here comes from public CoreGraphics values that every display
/// has (spec DM8).
///
/// KNOWN LIMITATION, inherited: a panel reporting serial 0 — the MAG 341C does
/// — collides with an identical unit. Same trade `persistenceKey` already
/// makes; twins would share a stored mode.
public struct DisplayConfigIdentity: Sendable, Hashable {
  public let key: String

  public init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltIn: Bool) {
    key = Self.key(vendor: vendor, model: model, serial: serial, isBuiltIn: isBuiltIn)
  }

  /// Key format is a UserDefaults key component — **fixed forever once
  /// shipped**, like `DisplayPrefs`' per-command format. The exact-key test
  /// pins it.
  public static func key(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltIn: Bool) -> String {
    // One built-in panel per machine, and it cannot be swapped out.
    guard !isBuiltIn else { return "builtin" }
    return String(format: "%x-%x-%x", vendor, model, serial)
  }
}
