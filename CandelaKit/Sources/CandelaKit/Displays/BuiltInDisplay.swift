import CandelaPrivateAPIs
import CoreGraphics
import Foundation

/// How a `BrightnessController` routes its display's brightness (Task 10).
/// `.builtIn` is a hard short-circuit: always the native leg, no DDC, no
/// software/combined routing, no HDR boost gate, and no persistence — macOS
/// owns built-in brightness across launches.
public enum DisplayRole: Sendable {
  case external
  case builtIn
}

public enum BuiltInDisplayDiscovery {
  /// The built-in display, if one is online. Name from
  /// `CoreDisplay_DisplayCreateInfoDictionary`'s product name, fallback
  /// "Built-in Display".
  public static func discover() -> (id: CGDirectDisplayID, name: String)? {
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &displayIDs, &count) == .success else {
      return nil
    }
    guard let id = displayIDs.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
      return nil
    }
    return (id, productName(for: id) ?? "Built-in Display")
  }

  /// Same source `Arm64DDC.ioregMatchScore` scores against: the localized
  /// `DisplayProductName` table, preferring en_US (e.g. "Built-in Retina
  /// Display").
  private static func productName(for displayID: CGDirectDisplayID) -> String? {
    guard
      let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?
      .takeRetainedValue() as NSDictionary?,
      let nameList = dictionary["DisplayProductName"] as? [String: String],
      let name = nameList["en_US"] ?? nameList.first?.value,
      !name.isEmpty
    else {
      return nil
    }
    return name
  }
}

/// DDC writer for displays with no DDC wire (the built-in panel): every write
/// fails and every read returns nil, so any DDC path reached by mistake
/// degrades instead of touching hardware. Public because the app target
/// constructs it when wiring the built-in controller (re-review T10-D).
public struct NoopDDCWriter: DDCWriting {
  public init() {}

  public func write(command _: UInt8, value _: UInt16) async -> Bool { false }

  public func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }
}
