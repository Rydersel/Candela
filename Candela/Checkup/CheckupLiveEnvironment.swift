import CandelaKit
import CoreGraphics
import Foundation

/// The live half of `CheckupEnvironment`: the app's own objects in, the value
/// the flow model runs over out.
///
/// Split the way `OnboardingLiveEnvironment` is split, and for its reason:
/// every rule that decides something lives in `entries(from:)`, which is pure
/// and reachable from a test with no display attached, no catalog enumerated
/// and no wire. The live side below fills the fields in and decides nothing.
enum CheckupLiveEnvironment {
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

  /// Strings this builder read for itself, for a display the D24 probe has no
  /// entry for. Kept here rather than pushed into `AppModel`, whose cache is
  /// written only by that probe and only from its own epoch check.
  @MainActor private static var readAtBuild: [String: String] = [:]
  @MainActor private static var readsInFlight: Set<String> = []

  @MainActor
  static func current(
    model: AppModel,
    presenter: any CheckupFieldPresenting,
    coordinator: OledCareCoordinator
  ) -> CheckupEnvironment {
    let configurator = CoreGraphicsDisplayConfigurator()
    let states = model.allControlledStates
    let sources = states.map { source(for: $0, model: model, configurator: configurator) }
    let entries = entries(from: sources)
    // Keyed on the same string the entries carry, uniqued rather than trapping:
    // two identical panels can share an EDID UUID, which is a documented
    // limitation of the persistence key and not a reason to crash the app.
    let writers = Dictionary(
      states.map { ($0.display.persistenceKey, $0.writer) }, uniquingKeysWith: { first, _ in first })
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
          writer: writers[entry.identityKey] ?? NoopDDCWriter(),
          capabilities: capabilities[entry.identityKey] ?? nil,
          hdr: hdr,
          configurator: configurator)
      },
      presenter: presenter,
      bookShowing: { [weak coordinator] identityKey, kind, seconds in
        let size = pixels[identityKey] ?? (0, 0)
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
      capabilities: capabilityString(for: state, model: model, isBuiltIn: isBuiltIn),
      // Discovery admits externals with a live DDC service and nothing else,
      // so membership in that list IS the answer; the built-in slot carries a
      // `NoopDDCWriter` and has no wire at all.
      hasDDCService: !isBuiltIn,
      pixelWidth: native?.width ?? Int(CGDisplayPixelsWide(state.id)),
      pixelHeight: native?.height ?? Int(CGDisplayPixelsHigh(state.id)))
  }

  /// The D24 probe caches a string for every display it is allowed to ask, so
  /// this is normally a cache hit. It misses for a display the probe skipped
  /// (HDR engaged, where DDC is dead anyway) or whose read failed once, since
  /// a failure caches the verdict and not the string.
  ///
  /// Such a display gets one read of its own, started HERE and never at app
  /// launch. The read is async and this builder is synchronous, so its answer
  /// lands for the NEXT checkup rather than this one: the run being assembled
  /// sees the same nil the cache had, and a panel that answers nothing is
  /// classed write-only, which is what a nil already meant everywhere else.
  @MainActor
  private static func capabilityString(
    for state: AppModel.DisplayState, model: AppModel, isBuiltIn: Bool
  ) -> String? {
    let key = state.display.persistenceKey
    if let cached = model.capabilityString[key] { return cached }
    if let read = readAtBuild[key] { return read }
    guard !isBuiltIn, !readsInFlight.contains(key) else { return nil }
    readsInFlight.insert(key)
    let writer = state.writer
    Task { @MainActor in
      let answer = await writer.readCapabilityString()
      readsInFlight.remove(key)
      // Stored only on a successful read, the probe's rule: a nil is a failed
      // transaction, and remembering it would outlive whatever caused it.
      if let answer { readAtBuild[key] = answer }
    }
    return nil
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
      mode: CheckupLiveModeRunner(
        configurator: CoreGraphicsDisplayConfigurator(), displayID: entry.id),
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
