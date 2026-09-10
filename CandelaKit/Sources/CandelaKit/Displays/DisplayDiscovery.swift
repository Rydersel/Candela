import CoreGraphics

/// One discovery pass: what it kept, and what it saw on the way. The report is the
/// half a caller may store; `controlled` holds a live `DDCWriting` per display, and
/// a writer must not outlive the pass that made it.
public struct DisplayDiscoverySurvey {
  public let controlled: [(display: ExternalDisplay, writer: any DDCWriting, facts: DisplayHardwareFacts)]
  public let report: DisplayDiscoveryReport

  public init(
    controlled: [(display: ExternalDisplay, writer: any DDCWriting, facts: DisplayHardwareFacts)],
    report: DisplayDiscoveryReport
  ) {
    self.controlled = controlled
    self.report = report
  }
}

public enum DisplayDiscovery {
  /// External, non-dummy, DDC-capable displays with a ready writer and the
  /// IOKit facts for each.
  ///
  /// The facts element costs no extra IOKit iteration and no DDC traffic: every
  /// one of those facts (bar the panel size, from a dictionary the match scorer
  /// already builds) was read on this pass and thrown away by `survey`'s `.map`.
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
    survey(excluding: ownedVirtualIDs).controlled
  }

  /// `discover`, keeping what it dropped and why. The commonest bug report is
  /// about a display that is NOT in `controlled`, and a list of survivors cannot
  /// describe an absence.
  ///
  /// The drop nobody expects: `Arm64DDC.getServiceMatches` returns only MATCHED
  /// services, so a candidate that scored nothing is missing from its answer
  /// rather than present with a nil service, and never reaches the filter below.
  /// That is the display behind a hub, and it is why the drops come from comparing
  /// the candidate list against the matches, never from inspecting what came
  /// back.
  public static func survey(excluding ownedVirtualIDs: Set<CGDirectDisplayID> = [])
    -> DisplayDiscoverySurvey {
    #if arch(arm64)
      // Two calls, because the fill call alone reports how many ids it WROTE: it
      // answers 32 whether 32 or 40 displays are online, so a truncated list would
      // read as a complete one. A hotplug between the calls can leave this count
      // ahead of the list below; the list is what discovery acts on.
      //
      // A refusal here is recorded and stepped over. This call decides only what
      // the report can say about the count, so returning would take DDC away from
      // every attached display over a number nothing acts on.
      var onlineTotal: UInt32 = 0
      let onlineCounted = CGGetOnlineDisplayList(0, nil, &onlineTotal) == .success
      // 32, not the historical 16: virtual displays consume this buffer
      // BEFORE the candidate policy filters them, so three slots up would
      // otherwise lower the real-display ceiling to 13.
      var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
      var count: UInt32 = 0
      guard CGGetOnlineDisplayList(32, &displayIDs, &count) == .success else {
        return DisplayDiscoverySurvey(controlled: [], report: .listFailed)
      }
      let classified = DDCCandidatePolicy.classify(
        online: Array(displayIDs.prefix(Int(count))),
        isBuiltIn: { CGDisplayIsBuiltin($0) != 0 },
        ownedVirtualIDs: ownedVirtualIDs,
        isForeignVirtual: VirtualDisplayDetection.isVirtual
      )
      let matches = Arm64DDC.getServiceMatches(displayIDs: classified.candidates)
      let controlled = matches
        .filter { !$0.dummy && $0.service != nil }
        .map { match in
          let key = persistenceKey(from: match.serviceDetails)
          return (
            ExternalDisplay(
              id: match.displayID,
              name: displayName(from: match.serviceDetails, displayID: match.displayID),
              persistenceKey: key
            ),
            // The tag rather than the key: the service logs every read verdict,
            // and a fallback key embeds the panel's serial number.
            Arm64DDCService.create(
              service: match.service,
              displayID: match.displayID,
              logTag: DisplayLogging.tag(for: key)
            ),
            DisplayHardwareFacts.from(
              service: match.serviceDetails,
              matchScore: match.matchScore,
              physicalSizeCm: Arm64DDC.physicalSizeCm(displayID: match.displayID)
            )
          )
        }
      return DisplayDiscoverySurvey(
        controlled: controlled,
        report: .counted(
          excluded: excluded(
            policyDrops: classified.excluded,
            candidates: classified.candidates,
            matches: matches.map(ServiceMatch.init),
            identity: { (CGDisplayVendorNumber($0), CGDisplayModelNumber($0)) }
          ),
          onlineTotal: onlineCounted ? onlineTotal : nil,
          slotCapacity: 32
        )
      )
    #else
      // Intel adapter arrives in a later milestone; IntelDDC stays compiled. No
      // display was enumerated here, and the report says that rather than zero.
      return DisplayDiscoverySurvey(controlled: [], report: .notEnumerated)
    #endif
  }

  /// What service matching answered about one candidate, minus the IOKit handles.
  /// The reason rule is pure and under test, and an `IOAVService` cannot be built
  /// in a test.
  struct ServiceMatch {
    let displayID: CGDirectDisplayID
    let isDummy: Bool
    let hasService: Bool
    let manufacturerID: String
    let productName: String

    init(
      displayID: CGDirectDisplayID, isDummy: Bool, hasService: Bool,
      manufacturerID: String, productName: String
    ) {
      self.displayID = displayID
      self.isDummy = isDummy
      self.hasService = hasService
      self.manufacturerID = manufacturerID
      self.productName = productName
    }

    init(_ match: Arm64DDC.Arm64Service) {
      // The two IOReg strings and nothing else: the walk also carries this
      // display's serial and EDID UUID, and neither may reach a pasted report.
      self.init(
        displayID: match.displayID, isDummy: match.dummy, hasService: match.service != nil,
        manufacturerID: match.serviceDetails.manufacturerID,
        productName: match.serviceDetails.productName)
    }
  }

  /// Every drop, with the reason: the policy drops first, then the candidates that
  /// reached service matching, each block in online-list order.
  ///
  /// Online order rather than the order `getServiceMatches` answered in, which is
  /// by descending match score and can shift between passes on unchanged hardware.
  /// Two blocks concatenated the same way every pass give a report someone can
  /// diff.
  ///
  /// - Parameters:
  ///   - policyDrops: dropped before service matching ran, so they carry no IOReg
  ///     strings and the report falls back to the vendor and model numbers.
  ///   - matches: what `getServiceMatches` answered. A candidate MISSING from it
  ///     scored no service at all, which is a drop nothing else records.
  static func excluded(
    policyDrops: [(CGDirectDisplayID, DisplayExclusionReason)],
    candidates: [CGDirectDisplayID],
    matches: [ServiceMatch],
    identity: (CGDirectDisplayID) -> (vendor: UInt32, model: UInt32)
  ) -> [DisplayDiscoveryReport.Excluded] {
    func row(
      _ displayID: CGDirectDisplayID, _ reason: DisplayExclusionReason,
      manufacturerID: String = "", productName: String = ""
    ) -> DisplayDiscoveryReport.Excluded {
      let numbers = identity(displayID)
      // Empty is not a name. The report needs nil to know to fall back rather
      // than printing a blank where a display should be.
      return DisplayDiscoveryReport.Excluded(
        displayID: displayID, vendorNumber: numbers.vendor, modelNumber: numbers.model,
        manufacturerID: manufacturerID.isEmpty ? nil : manufacturerID,
        productName: productName.isEmpty ? nil : productName,
        reason: reason)
    }
    // `getServiceMatches` claims each display id at most once, so a duplicate here
    // would be a change in that matcher rather than a case to reconcile.
    let matched = Dictionary(matches.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
    return policyDrops.map { row($0.0, $0.1) } + candidates.compactMap { id in
      guard let match = matched[id] else { return row(id, .noDDCService) }
      // The order of the two halves of `controlled`'s filter. A dummy plug HAS a
      // service, so folding them together would send the reader after a cable.
      if match.isDummy {
        return row(id, .dummy, manufacturerID: match.manufacturerID, productName: match.productName)
      }
      if !match.hasService {
        return row(id, .noDDCService, manufacturerID: match.manufacturerID, productName: match.productName)
      }
      return nil
    }
  }

  static func displayName(from service: Arm64DDC.IOregService, displayID: CGDirectDisplayID) -> String {
    service.productName.isEmpty ? "Display \(displayID)" : service.productName
  }

  /// Known limitation: two identical monitors can share an EDID UUID, and the
  /// fallback triple collides more easily when the serial is 0, so twins would
  /// share saved brightness. The fork disambiguated with CGDirectDisplayID at
  /// the cost of stability across ports and reboots.
  ///
  /// The fallback embeds the panel's serial number, so log
  /// `DisplayLogging.tag(for:)` instead of this value.
  static func persistenceKey(from service: Arm64DDC.IOregService) -> String {
    if !service.edidUUID.isEmpty {
      return service.edidUUID
    }
    let name = service.productName.filter { !$0.isWhitespace }
    return "\(name)-\(service.manufacturerID)-\(service.serialNumber)"
  }
}
