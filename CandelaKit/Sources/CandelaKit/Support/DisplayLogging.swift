import CryptoKit
import Foundation

/// A display's persistence key is the EDID UUID when the panel offers one and
/// the name/manufacturer/serial triple when it does not, so the raw value can
/// carry the panel's serial number. os_log at `.public` survives into a
/// sysdiagnose and into anything `log show` collects, so the key goes out as a
/// tag instead: the diagnostics report already refuses to carry a serial value,
/// and the log honours the same contract.
public enum DisplayLogging {
  /// Same key, same tag, every launch: correlating one display's lines across
  /// sessions is the only reason to log the key at all.
  public static func tag(for persistenceKey: String) -> String {
    SHA256.hash(data: Data(persistenceKey.utf8))
      .prefix(4)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
