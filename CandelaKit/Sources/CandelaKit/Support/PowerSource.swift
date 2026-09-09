import Foundation
import IOKit.ps

/// Mains or battery, for anything that should cost less when unplugged.
public enum PowerSource {
  /// True only when an internal battery is the source in use. Everything this
  /// cannot see (no battery, sources that will not enumerate) answers false, the
  /// mains answer, so it degrades toward polling more often.
  public static func isOnBattery() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return false }
    return sources.contains { source in
      guard
        let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
          as? [String: Any],
        info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { return false }
      return info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
    }
  }
}
