import CandelaPrivateAPIs
import CoreGraphics
import Foundation

/// Is this display SYNTHETIC: Sidecar, AirPlay, a dummy-plug emulator,
/// another app's virtual display, or one of ours?
///
/// One lookup on a dictionary the app already fetches elsewhere, so it adds NO
/// new private-API dependency. Measured 1 for every CGVirtualDisplay and 0
/// for the built-in, including from a second process that created none of them,
/// which is what makes it a FOREIGN-display predicate.
///
/// It answers "virtual", NEVER "ours". Ownership is
/// `VirtualDisplayProviding.ownedDisplayIDs` and nothing else may decide
/// whether Candela may destroy a display.
///
/// Signals deliberately NOT used, each measured and rejected:
/// `CGDisplayIsAsleep` (no discrimination); vendor/model/serial (actively
/// unsafe: a virtual display can impersonate any real monitor exactly);
/// `CGDisplayScreenSize == 0` (real panels with bad EDID report 0 too); the
/// `Virtual-` name prefix (an undocumented private string).
public enum VirtualDisplayDetection {
  static let virtualDeviceKey = "kCGDisplayIsVirtualDevice"

  /// nil when the dictionary or the key is absent; the caller then treats the
  /// display as ORDINARY. That is the degrade path every private-API call site
  /// owes, and why our own displays' protection rests on ownership instead.
  public static func isVirtual(_ displayID: CGDirectDisplayID) -> Bool? {
    guard let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?
      .takeRetainedValue() as NSDictionary?
    else { return nil }
    return flag(in: dictionary)
  }

  /// Split out so the decode is testable with no display attached. Anything
  /// that is not a number is "don't know", never false.
  static func flag(in dictionary: NSDictionary) -> Bool? {
    guard let value = dictionary[virtualDeviceKey] as? NSNumber else { return nil }
    return value.boolValue
  }
}
