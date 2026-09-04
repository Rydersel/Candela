import CryptoKit
import Foundation

/// A persistence key without an EDID UUID embeds the panel's serial number, and
/// `.public` os_log lines leave the machine in sysdiagnoses and bug reports. So
/// logs carry a hash. The diagnostics page still shows the raw key: that one is
/// shown on screen and copied by a decision the owner makes.
public enum DisplayLogging {
  /// Stable across launches, so one display's lines correlate across sessions.
  public static func tag(for persistenceKey: String) -> String {
    SHA256.hash(data: Data(persistenceKey.utf8))
      .prefix(4)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
