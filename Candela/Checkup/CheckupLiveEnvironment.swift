import CandelaKit
import CoreGraphics
import Foundation
import os

/// The live half of `CheckupEnvironment`: the app's own objects in, the value
/// the flow model runs over out.
///
/// Split the way `OnboardingLiveEnvironment` is split, and for its reason:
/// what decides something lives in `entries(from:)` and `readingCapabilities`,
/// both reachable from a test with no display attached, no catalog enumerated
/// and no wire. The live side below fills the fields in and decides nothing.
enum CheckupLiveEnvironment {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "checkup")

  /// One display as the live layer reads it, before any checkup rule applies.
  struct Source {
    var id: CGDirectDisplayID
    /// The display's persistence key: an EDID UUID for an external, so every
    /// stored run is filed under the panel rather than under a display id,
    /// which macOS reassigns across a replug.
    var identityKey: String
    var name: String
    var isBuiltIn: Bool
    var isVirtual: Bool
    /// The cached MCCS capabilities string. nil is "nobody has a string for
    /// this display", never "this display advertises nothing" (D24).
    var capabilities: String?
    var hasDDCService: Bool
    var pixelWidth: Int
    var pixelHeight: Int
  }

  /// CK26: a virtual display is never a checkup target, so it is dropped here
  /// rather than carried to every surface that would have to remember to skip
  /// it. `isOnlyDisplay` counts what survives that filter, because a display
  /// the flow refuses to target is also a display the flow window cannot be
  /// sent to (CK16).
  static func entries(from sources: [Source]) -> [CheckupDisplayEntry] {
    let real = sources.filter { !$0.isVirtual }
    return real.map { source in
      CheckupDisplayEntry(
        id: source.id,
        identityKey: source.identityKey,
        name: source.name,
        isBuiltIn: source.isBuiltIn,
        isVirtual: source.isVirtual,
        panelClass: CheckupPlan.panelClass(
          capabilities: source.capabilities,
          hasDDCService: source.hasDDCService,
          isBuiltIn: source.isBuiltIn),
        pixelWidth: source.pixelWidth,
        pixelHeight: source.pixelHeight,
        isOnlyDisplay: real.count == 1)
    }
  }

  /// The DDC path behind one display, as the capability fill-in needs it.
  struct CapabilityProbe {
    var writer: any DDCWriting
    var hdrEngaged: Bool
  }

  /// Reads a capability string for every external the D24 probe has no entry
  /// for, BEFORE the plan grades anything off it.
  ///
  /// The probe misses for a display whose read failed once: a failure caches
  /// the verdict and not the string, and `CapabilityProbePolicy` then declines
  /// to ask again that session. Without this the checkup would inherit that
  /// nil, and a nil classes the panel write-only, so one transient failure
  /// would put "readback cannot be observed" in a saved report about a Dell.
  ///
  /// The policy's own clauses, in its terms: the guard above IS its cached-nil
  /// case, restated; nothing of this builder's can be outstanding because the
  /// read is awaited here rather than launched; and HDR skips the read, since
  /// DDC is dead while HDR is engaged and the write-only text is what a
  /// silent panel earns.
  @MainActor
  static func readingCapabilities(
    into sources: [Source], probes: [String: CapabilityProbe]
  ) async -> [Source] {
    var filled: [Source] = []
    filled.reserveCapacity(sources.count)
    for var source in sources {
      guard source.capabilities == nil, !source.isBuiltIn,
        let probe = probes[source.identityKey],
        CapabilityProbePolicy.shouldProbe(
          cached: nil, inFlight: false, hdrEngaged: probe.hdrEngaged)
      else {
        filled.append(source)
        continue
      }
      source.capabilities = await probe.writer.readCapabilityString()
      filled.append(source)
    }
    return filled
  }

  @MainActor
  static func current(
    model: AppModel,
    presenter: any CheckupFieldPresenting,
    coordinator: OledCareCoordinator
  ) async -> CheckupEnvironment {
    let configurator = CoreGraphicsDisplayConfigurator()
    let states = model.allControlledStates
    // Keyed on the same string the entries carry, uniqued rather than trapping:
    // two identical panels can share an EDID UUID, which is a documented
    // limitation of the persistence key and not a reason to crash the app.
    let probes = Dictionary(
      states.map {
        ($0.display.persistenceKey,
         CapabilityProbe(writer: $0.writer, hdrEngaged: $0.controller.isHDREngaged))
      },
      uniquingKeysWith: { first, _ in first })
    let sources = await readingCapabilities(
      into: states.map { source(for: $0, model: model, configurator: configurator) },
      probes: probes)
    let entries = entries(from: sources)
    let capabilities = Dictionary(
      sources.map { ($0.identityKey, $0.capabilities) }, uniquingKeysWith: { first, _ in first })
    let pixels = Dictionary(
      entries.map { ($0.identityKey, ($0.pixelWidth, $0.pixelHeight)) },
      uniquingKeysWith: { first, _ in first })
    let hdr = model.hdrToggling

    return CheckupEnvironment(
      displays: entries,
      macOSBuild: ProcessInfo.processInfo.operatingSystemVersionString,
      appBuild: "\(AppInfo.version) (\(AppInfo.build))",
      runners: { entry in
        runnerSet(
          for: entry,
          writer: probes[entry.identityKey]?.writer ?? NoopDDCWriter(),
          capabilities: capabilities[entry.identityKey] ?? nil,
          hdr: hdr,
          configurator: configurator)
      },
      presenter: presenter,
      bookShowing: { [weak coordinator] identityKey, kind, seconds in
        // A zero size makes the witness card's coverage NaN, and the booking's
        // clamp passes a NaN through as full white, so the ledger would gain a
        // full-white showing that never happened. Nothing to book is better.
        guard let size = pixels[identityKey], size.0 > 0, size.1 > 0 else {
          log.error("""
          checkup showing not booked: no pixel size for \(identityKey, privacy: .public)
          """)
          return
        }
        coordinator?.bookCheckupShowing(
          identityKey: identityKey,
          luminance: CheckupField.luminance(
            of: kind, pixelWidth: size.0, pixelHeight: size.1),
          seconds: seconds)
      },
      now: Date.init,
      makeRNG: { SystemRandomNumberGenerator() })
  }

  // MARK: - Sources

  @MainActor
  private static func source(
    for state: AppModel.DisplayState,
    model: AppModel,
    configurator: CoreGraphicsDisplayConfigurator
  ) -> Source {
    let key = state.display.persistenceKey
    let isBuiltIn = model.builtIn?.id == state.id
    // Both answers to "is this virtual", the pair `AppModel` itself asks:
    // ours by ownership, everyone else's by the optional-returning predicate.
    let isVirtual = model.virtualDisplays.ownedDisplayIDs.contains(state.id)
      || VirtualDisplayDetection.isVirtual(state.id) == true
    // Native pixels AS MACOS REPORTS THEM, which on the rotated Dell is the
    // rotated frame. That is the space the field is drawn and tapped in, so it
    // is also the space the planted control's coordinates live in; panel-native
    // would put every plant on the wrong axis.
    let native = configurator.nativePixels(for: state.id)
    let prefs = DisplayPrefs(persistenceKey: key)
    return Source(
      id: state.id,
      identityKey: key,
      name: DisplayOrdering.title(
        friendlyName: prefs.friendlyName, hardwareName: state.display.name),
      isBuiltIn: isBuiltIn,
      isVirtual: isVirtual,
      // The D24 probe's string where it has one; `readingCapabilities` above
      // fills the rest in before anything is graded off them.
      capabilities: model.capabilityString[key],
      // Discovery admits externals with a live DDC service and nothing else,
      // so membership in that list IS the answer; the built-in slot carries a
      // `NoopDDCWriter` and has no wire at all.
      hasDDCService: !isBuiltIn,
      pixelWidth: native?.width ?? Int(CGDisplayPixelsWide(state.id)),
      pixelHeight: native?.height ?? Int(CGDisplayPixelsHigh(state.id)))
  }

  // MARK: - Runners

  @MainActor
  private static func runnerSet(
    for entry: CheckupDisplayEntry,
    writer: any DDCWriting,
    capabilities: String?,
    hdr: any HDRToggling,
    configurator: CoreGraphicsDisplayConfigurator
  ) -> CheckupRunnerSet {
    // One read, shared by the identity leg and the HDR leg: the EOTF flags the
    // HDR runner gates on come out of this record, and reading it twice would
    // let the two legs disagree about the same panel.
    let identity = CheckupIdentityFacts.read(
      displayID: entry.id,
      identityKey: entry.identityKey,
      vendorID: CGDisplayVendorNumber(entry.id),
      modelID: CGDisplayModelNumber(entry.id),
      nativePixels: (entry.pixelWidth, entry.pixelHeight),
      maxRefreshHz: DisplayModeCatalog.distinctRates(configurator.modes(for: entry.id)).max())
    return CheckupRunnerSet(
      identity: { identity },
      capabilities: capabilitiesRunner(for: entry, writer: writer, capabilities: capabilities),
      mode: CheckupLiveModeRunner(configurator: configurator, displayID: entry.id),
      hdr: CheckupLiveHDRRunner(
        hdr: hdr, displayID: entry.id, identity: identity ?? unreadIdentity(for: entry)))
  }

  /// A display with no DDC path had its three capability rows pre-graded by the
  /// plan, and the flow skips the leg entirely, so this is never asked to run.
  /// It exists so the runner set has one shape for every panel class.
  private struct NoCapabilitiesRunner: CheckupCapabilitiesRunning {
    func run() async -> [CheckupClaim] { [] }
  }

  private static func capabilitiesRunner(
    for entry: CheckupDisplayEntry, writer: any DDCWriting, capabilities: String?
  ) -> any CheckupCapabilitiesRunning {
    guard entry.panelClass == .readsDDC, let capabilities else { return NoCapabilitiesRunner() }
    return CheckupLiveCapabilitiesRunner(writer: writer, capabilities: capabilities)
  }

  /// What the HDR runner is handed when the display exposed no parsed EDID
  /// record. Everything in it is what this builder already knew; nothing is
  /// presented as something the panel reported, and the absent EOTF flags are
  /// what the runner reads as "this panel does not advertise HDR".
  private static func unreadIdentity(for entry: CheckupDisplayEntry) -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(
      identityKey: entry.identityKey, vendorID: 0, modelID: 0, serial: nil,
      manufactureWeek: nil, manufactureYear: nil,
      nativePixelWidth: entry.pixelWidth, nativePixelHeight: entry.pixelHeight,
      maxRefreshHz: nil, supportsPQEOTF: false, supportsHDRGammaEOTF: false,
      productName: entry.name)
  }
}
