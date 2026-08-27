import CandelaKit
import CoreGraphics
import Foundation

/// Gathers one attached display's values from the stores and hands them to
/// the assembler. Every read goes through the coordinator's single-instance
/// doors: a second tracker over a key double-books every tick.
@MainActor
enum ProvenanceExporter {
  /// Call from an action, never from a view body: `hoursTracker(for:)` and
  /// `wearTracker(for:)` memoise into observation-tracked state, so a body that
  /// reads them writes to what it is observing.
  static func record(for state: AppModel.DisplayState, model: AppModel, now: Date = .now) -> ProvenanceRecord {
    let key = state.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: key)
    let care = model.oledCare
    let runs = ((try? CheckupStore(directory: CheckupStore.defaultDirectory()).list(identityKey: key)) ?? [])
      .map(\.envelope)

    let hours: ProvenanceSection<ProvenanceAssembler.HoursInput>
    if !prefs.oledCareEnrolled {
      hours = .notCollected(.notEnrolled)
    } else if !prefs.oledHoursTracking {
      hours = .notCollected(.trackingOff)
    } else {
      let tracker = care.hoursTracker(for: key)
      hours = .collected(.init(lifetimeSeconds: tracker.totalHours * 3600,
                               secondsSinceStandby: tracker.hoursSinceStandby * 3600))
    }

    let exposure: ProvenanceSection<ProvenanceAssembler.ExposureInput>
    if !prefs.oledCareEnrolled {
      exposure = .notCollected(.notEnrolled)
    } else {
      let summary = care.healthSummary(for: key)
      let confidence: ProvenanceExposure.Confidence = switch summary.confidence {
      case .measured: .measured
      case .estimated: .estimated
      case .insufficient: .insufficient
      }
      exposure = .collected(.init(
        map: care.exposureMap(for: key), confidence: confidence,
        histogram: care.wearTracker(for: key).histogram()))
    }

    return ProvenanceAssembler.assemble(
      identity: identity(for: state, model: model, identityRun: latestReadIdentityRun(runs)),
      hours: hours, exposure: exposure, checkups: runs,
      appBuild: "\(AppInfo.version) (\(AppInfo.build))",
      macOSBuild: ProcessInfo.processInfo.operatingSystemVersionString,
      now: now)
  }

  /// Only a run that actually read the display, `CheckupSummaryText`'s rule and
  /// its reason: an abandoned run stores a placeholder identity, which would be
  /// carried here as a serial and a native size nothing ever observed.
  ///
  /// The tie-break is the assembler's total order, not time alone: two runs
  /// booked in the same instant would otherwise pick unstably, and the same
  /// stores would export under two different identities.
  private static func latestReadIdentityRun(_ runs: [CheckupReportEnvelope]) -> CheckupReportEnvelope? {
    runs.filter { CheckupSummaryText.identityWasRead($0.report) }.max {
      $0.report.startedAt == $1.report.startedAt
        ? $0.sha256 < $1.sha256
        : $0.report.startedAt < $1.report.startedAt
    }
  }

  /// The same read the checkup leg performs, with the same sources: native
  /// pixels off the native-flagged mode, never `CGDisplayPixelsWide`, which
  /// answers with the CURRENT mode's logical width and would file a scaled size
  /// under "native resolution" in a document that travels with the display.
  private static func liveIdentity(for state: AppModel.DisplayState) -> CheckupDisplayIdentity? {
    let configurator = CoreGraphicsDisplayConfigurator()
    let modes = configurator.modes(for: state.display.id)
    let native = configurator.nativePixels(for: state.display.id)
    return CheckupIdentityFacts.read(
      displayID: state.display.id, identityKey: state.display.persistenceKey,
      vendorID: CGDisplayVendorNumber(state.display.id), modelID: CGDisplayModelNumber(state.display.id),
      nativePixels: (native?.width ?? Int(CGDisplayPixelsWide(state.display.id)),
                     native?.height ?? Int(CGDisplayPixelsHigh(state.display.id))),
      maxRefreshHz: DisplayModeCatalog.distinctRates(modes).max())
  }

  /// The checkup's own identity read first, because a run measured native
  /// pixels and refresh the way the checkup defines them; the live read is the
  /// fallback for a display that has never been checked.
  private static func identity(for state: AppModel.DisplayState, model: AppModel,
                               identityRun: CheckupReportEnvelope?) -> ProvenanceIdentity {
    let key = state.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: key)
    let edid = identityRun?.report.identity ?? liveIdentity(for: state)
    let facts = model.hardwareFacts[key]
    return ProvenanceIdentity(
      persistenceKey: key,
      displayName: DisplayOrdering.title(friendlyName: prefs.friendlyName, hardwareName: state.display.name),
      edid: edid,
      hardware: facts.map {
        ProvenanceHardware(
          transport: $0.transportUpstream ?? $0.transportDownstream,
          manufacturerID: $0.manufacturerID,
          alphanumericSerial: $0.alphanumericSerialNumber,
          numericSerial: $0.numericSerialNumber,
          physicalWidthCm: $0.physicalWidthCm, physicalHeightCm: $0.physicalHeightCm)
      })
  }
}
