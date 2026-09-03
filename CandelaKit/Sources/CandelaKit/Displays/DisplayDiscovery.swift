import CoreGraphics

public enum DisplayDiscovery {
  /// External, non-dummy, DDC-capable displays with a ready writer and the
  /// IOKit facts for each.
  ///
  /// The facts element costs no extra IOKit iteration and no DDC traffic: every
  /// one of those facts (bar the panel size, from a dictionary the match scorer
  /// already builds) was read on this pass and thrown away by this `.map`.
  ///
  /// A third tuple element rather than three fields on `ExternalDisplay`:
  /// widening that type would touch every construction site and every fixture
  /// for the benefit of one read-only pane.
  ///
  /// - Parameter ownedVirtualIDs: displays Candela itself created. They are
  ///   removed from the candidate pool BEFORE `Arm64DDC.getServiceMatches` sees
  ///   it, alongside foreign virtual displays; `DDCCandidatePolicy` says what
  ///   happens if they are not.
  public static func discover(excluding ownedVirtualIDs: Set<CGDirectDisplayID> = [])
    -> [(display: ExternalDisplay, writer: any DDCWriting, facts: DisplayHardwareFacts)] {
    #if arch(arm64)
      // 32, not the historical 16: virtual displays consume this buffer
      // BEFORE the candidate policy filters them, so three slots up would
      // otherwise lower the real-display ceiling to 13.
      var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
      var count: UInt32 = 0
      guard CGGetOnlineDisplayList(32, &displayIDs, &count) == .success else {
        return []
      }
      let externalIDs = DDCCandidatePolicy.candidates(
        online: Array(displayIDs.prefix(Int(count))),
        isBuiltIn: { CGDisplayIsBuiltin($0) != 0 },
        ownedVirtualIDs: ownedVirtualIDs,
        isForeignVirtual: VirtualDisplayDetection.isVirtual
      )
      return Arm64DDC.getServiceMatches(displayIDs: Array(externalIDs))
        .filter { !$0.dummy && $0.service != nil }
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
      return [] // Intel adapter arrives in a later milestone; IntelDDC stays compiled.
    #endif
  }

  static func displayName(from service: Arm64DDC.IOregService, displayID: CGDirectDisplayID) -> String {
    service.productName.isEmpty ? "Display \(displayID)" : service.productName
  }

  /// Known limitation: two identical monitors can share an EDID UUID, and the
  /// fallback triple collides more easily when the serial is 0, so twins would
  /// share saved brightness. The fork disambiguated with CGDirectDisplayID at
  /// the cost of stability across ports and reboots.
  ///
  /// The fallback embeds the panel's serial number, so this value never goes
  /// into a log at `.public` or into the diagnostics report. Log
  /// `DisplayLogging.tag(for:)` instead.
  static func persistenceKey(from service: Arm64DDC.IOregService) -> String {
    if !service.edidUUID.isEmpty {
      return service.edidUUID
    }
    let name = service.productName.filter { !$0.isWhitespace }
    return "\(name)-\(service.manufacturerID)-\(service.serialNumber)"
  }
}
