import CryptoKit
import Foundation

/// A display's persistence key is the EDID UUID when the panel offers one and
/// the name/manufacturer/serial triple when it does not, so the raw value can
/// carry the panel's serial number. os_log at `.public` survives into a
/// sysdiagnose and into anything `log show` collects, and both of those leave
/// the machine: attached to a bug report, mailed to support, pasted into a
/// thread, and nobody reads what is in them first. So the key goes out as a tag.
///
/// This is NOT a claim that the serial is unprintable anywhere. The diagnostics
/// page renders both it and the raw key, deliberately: that page is shown to the
/// person whose display it is, on screen, and copied by a decision they make.
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
