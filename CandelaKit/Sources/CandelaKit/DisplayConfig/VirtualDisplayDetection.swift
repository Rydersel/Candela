import CandelaPrivateAPIs
import CoreGraphics
import Foundation

/// Is this display SYNTHETIC: Sidecar, AirPlay, a dummy-plug emulator,
/// another app's virtual display, or one of ours?
///
/// One dictionary lookup, on a dictionary the app already fetches in
/// `BuiltInDisplayDiscovery.productName` and `Arm64DDC.ioregMatchScore`, so
/// this adds NO new private-API dependency (VD3). Measured 1 for every
/// CGVirtualDisplay created and 0 for the built-in, including from a second
/// process with no part in creating them, which is what makes it a
/// FOREIGN-display predicate and not just a memory of what we did.
///
/// It answers "virtual", NEVER "ours". Ownership is
/// `VirtualDisplayProviding.ownedDisplayIDs` and nothing else may decide
/// whether Candela may destroy a display (VD12).
///
/// Signals deliberately NOT used, each measured and rejected (S1):
/// `CGDisplayIsAsleep` (no discrimination); vendor/model/serial (actively
/// unsafe: a virtual display can impersonate any real monitor exactly);
/// `CGDisplayScreenSize == 0` (real panels with bad EDID report 0 too); the
/// `Virtual-` name prefix (an undocumented private string).
public enum VirtualDisplayDetection {
  static let virtualDeviceKey = "kCGDisplayIsVirtualDevice"

  /// nil when the dictionary or the key is absent; the caller then treats the
  /// display as ORDINARY, which is exactly today's behavior. That is the
  /// degrade path the project rule requires of every private-API call site,
  /// and it is why our own displays' protection rests on ownership instead.
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
