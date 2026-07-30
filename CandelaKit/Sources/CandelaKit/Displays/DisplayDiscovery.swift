import CoreGraphics

public enum DisplayDiscovery {
  /// External, non-dummy, DDC-capable displays with a ready writer for each.
  public static func discover() -> [(display: ExternalDisplay, writer: any DDCWriting)] {
    #if arch(arm64)
      var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
      var count: UInt32 = 0
      guard CGGetOnlineDisplayList(16, &displayIDs, &count) == .success else {
        return []
      }
      let externalIDs = displayIDs.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
      return Arm64DDC.getServiceMatches(displayIDs: Array(externalIDs))
        .filter { !$0.dummy && !$0.discouraged && $0.service != nil }
        .map { match in
          (ExternalDisplay(id: match.displayID,
                           name: displayName(from: match.serviceDetails, displayID: match.displayID),
                           persistenceKey: persistenceKey(from: match.serviceDetails)),
           Arm64DDCService.create(service: match.service))
        }
    #else
      return [] // Intel adapter arrives in a later milestone (spec §2 keeps IntelDDC compiled).
    #endif
  }

  static func displayName(from service: Arm64DDC.IOregService, displayID: CGDirectDisplayID) -> String {
    service.productName.isEmpty ? "Display \(displayID)" : service.productName
  }

  /// Known limitation: two identical monitors (same model/firmware) can share
  /// an EDID UUID, and the fallback triple collides even more easily when the
  /// serial is 0 — twins would then share saved brightness. The fork
  /// disambiguated with CGDirectDisplayID at the cost of stability across
  /// ports/reboots. Single-monitor dev hardware can't test this; revisit if a
  /// multi-monitor user reports it.
  static func persistenceKey(from service: Arm64DDC.IOregService) -> String {
    if !service.edidUUID.isEmpty {
      return service.edidUUID
    }
    let name = service.productName.filter { !$0.isWhitespace }
    return "\(name)-\(service.manufacturerID)-\(service.serialNumber)"
  }
}
