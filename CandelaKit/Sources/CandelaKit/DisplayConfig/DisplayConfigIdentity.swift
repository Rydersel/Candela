import Foundation

/// Stable per-display key for display-configuration state.
///
/// Deliberately NOT `DisplayDiscovery.persistenceKey`, which comes from an
/// `Arm64DDC.IOregService` and so exists only for DDC-capable externals. Mode
/// switching also applies to the built-in and to virtual displays, so identity
/// here comes from public CoreGraphics values every display has (spec DM8).
///
/// Known limitation, inherited from `persistenceKey`: a panel reporting serial 0
/// (the MAG 341C does) collides with an identical unit, so twins share a stored
/// mode.
public struct DisplayConfigIdentity: Sendable, Hashable {
  public let key: String

  public init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltIn: Bool) {
    key = Self.key(vendor: vendor, model: model, serial: serial, isBuiltIn: isBuiltIn)
  }

  /// A UserDefaults key component, **fixed forever once shipped**, like
  /// `DisplayPrefs`' per-command format. The exact-key test pins it.
  public static func key(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltIn: Bool) -> String {
    // One built-in panel per machine, and it cannot be swapped out. The
    // spelling deliberately matches the `persistenceKey` passed to
    // `DisplayPrefs` elsewhere: separate key namespaces, same physical panel, so
    // a `defaults` dump reads as one display and not two. Both formats are
    // frozen; changing either silently orphans stored preferences.
    guard !isBuiltIn else { return "builtIn" }
    return String(format: "%x-%x-%x", vendor, model, serial)
  }
}
