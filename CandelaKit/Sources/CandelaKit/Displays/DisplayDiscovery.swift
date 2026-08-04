import CoreGraphics

public enum DisplayDiscovery {
  /// External, non-dummy, DDC-capable displays with a ready writer and the
  /// IOKit facts for each.
  ///
  /// The third element is B8: every one of those facts (bar the panel size,
  /// which comes from a dictionary the match scorer was already building) was
  /// read on this very pass and thrown away by this very `.map`. Returning it
  /// costs no additional IOKit iteration and, emphatically, no DDC traffic.
  ///
  /// A third tuple element rather than three fields on `ExternalDisplay`: that
  /// type is three fields under the engine's one-submitter invariant, and
  /// widening it would touch every construction site and every fixture for the
  /// benefit of one read-only pane. Callers that want only the display and the
  /// writer keep compiling — they already destructure by label.
  public static func discover()
    -> [(display: ExternalDisplay, writer: any DDCWriting, facts: DisplayHardwareFacts)] {
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
           Arm64DDCService.create(service: match.service),
           DisplayHardwareFacts.from(
             service: match.serviceDetails,
             matchScore: match.matchScore,
             physicalSizeCm: Arm64DDC.physicalSizeCm(displayID: match.displayID)
           ))
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
