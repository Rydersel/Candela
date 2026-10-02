import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import os

/// The live half of `CheckupEnvironment`. Split like `OnboardingLiveEnvironment`:
/// what decides something lives in `entries(from:)` and `readingLiveState`,
/// testable with no display attached; the live side fills fields in and decides nothing.
enum CheckupLiveEnvironment {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "checkup")

  /// One display as the live layer reads it, before any checkup rule applies.
  struct Source {
    var id: CGDirectDisplayID
    /// The persistence key (an EDID UUID for an external), so runs file under
    /// the panel rather than a display id macOS reassigns across a replug.
    var identityKey: String
    var name: String
    var isBuiltIn: Bool
    var isVirtual: Bool
    /// No `NSScreen` of its own, so no field can be drawn on it.
    var isMirroring: Bool
    /// The cached MCCS capabilities string. nil is "nobody has a string for
    /// this display", never "this display advertises nothing".
    var capabilities: String?
    var hasDDCService: Bool
    /// Whether the panel is in HDR right now. DDC is dead while it is.
    var hdrEngaged: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var pointHeight: Double
  }

  /// A virtual display is never a target, and neither is a mirroring one,
  /// so both drop here rather than at every surface. `isOnlyDisplay` counts what
  /// survives: a display the flow cannot target cannot host the window either.
  static func entries(from sources: [Source]) -> [CheckupDisplayEntry] {
    let real = sources.filter { exclusion(for: $0) == nil }
    return real.map { source in
      CheckupDisplayEntry(
        id: source.id,
        identityKey: source.identityKey,
        name: source.name,
        isBuiltIn: source.isBuiltIn,
        isVirtual: source.isVirtual,
        isMirroring: source.isMirroring,
        panelClass: CheckupPlan.panelClass(
          capabilities: source.capabilities,
          hasDDCService: source.hasDDCService,
          isBuiltIn: source.isBuiltIn),
        hdrEngaged: source.hdrEngaged,
        pixelWidth: source.pixelWidth,
        pixelHeight: source.pixelHeight,
        pointHeight: source.pointHeight,
        isOnlyDisplay: real.count == 1)
    }
  }

  /// The complement of `entries(from:)` over the same sources, each row
  /// carrying why it was dropped.
  static func excluded(from sources: [Source]) -> [CheckupExcludedDisplay] {
    sources.compactMap { source in
      guard let reason = exclusion(for: source) else { return nil }
      return CheckupExcludedDisplay(
        id: source.id, name: source.name, pixelWidth: source.pixelWidth,
        pixelHeight: source.pixelHeight, reason: reason)
    }
  }

  /// The one predicate both lists derive from, so no display can be offered and
  /// excluded at once. Virtual wins a tie: what the thing IS outranks how it is
  /// wired.
  private static func exclusion(for source: Source) -> CheckupExcludedDisplay.Reason? {
    if source.isVirtual { return .virtual }
    if source.isMirroring { return .mirroring }
    return nil
  }

  /// Reads the live state the plan grades off, BEFORE it grades anything: HDR
  /// from the panel, then a capability string for every external the capabilities probe
  /// lacks one for. A nil `hdr` leaves the caller's value alone.
  ///
  /// Both re-reads exist because the cached answers lie. The controller's HDR
  /// mirror goes stale when HDR is toggled outside the app, and a failed
  /// capability read caches the verdict with no retry that session, which would
  /// class a panel that answers DDC as write-only in a saved report. HDR skips
  /// the capability read, since DDC is dead while HDR is engaged.
  @MainActor
  static func readingLiveState(
    into sources: [Source], writers: [String: any DDCWriting], hdr: (any HDRToggling)?
  ) async -> [Source] {
    var filled: [Source] = []
    filled.reserveCapacity(sources.count)
    for var source in sources {
      if let hdr, !source.isBuiltIn {
        source.hdrEngaged = await hdr.measuredHDREnabled(displayID: source.id)
      }
      guard source.capabilities == nil, !source.isBuiltIn,
        let writer = writers[source.identityKey],
        CapabilityProbePolicy.shouldProbe(
          cached: nil, inFlight: false, hdrEngaged: source.hdrEngaged)
      else {
        filled.append(source)
        continue
      }
      source.capabilities = await writer.readCapabilityString()
      filled.append(source)
    }
    return filled
  }

  @MainActor
  static func current(
    model: AppModel,
    presenter: any CheckupFieldPresenting,
    coordinator: OledCareCoordinator,
    readSource: (@MainActor (AppModel.DisplayState) -> Source)? = nil
  ) async -> CheckupEnvironment {
    let configurator = model.displayConfigurator
    let readSource = readSource ?? { source(for: $0, model: model, configurator: configurator) }
    let states = model.allControlledStates
    // Uniqued rather than trapping: two identical panels can share an EDID
    // UUID, a documented limit of the persistence key.
    let writers = Dictionary(
      states.map { ($0.display.persistenceKey, $0.writer) },
      uniquingKeysWith: { first, _ in first })
    let hdr = model.hdrToggling
    let sources = await readingLiveState(
      into: states.map { readSource($0) },
      writers: writers,
      hdr: hdr)
    let entries = entries(from: sources)
    // Virtual displays have no brightness controller. Use the online topology
    // for exclusions only, so these rows never become field or DDC targets.
    let controlledIDs = Set(sources.map(\.id))
    let ownedVirtualIDs = model.virtualDisplays.ownedDisplayIDs
    let uncontrolled = model.mirrorTopology.topology().displays
      .filter { !controlledIDs.contains($0.id) }
      .map { display in
        let mode = CGDisplayCopyDisplayMode(display.id)
        return Source(
          id: display.id, identityKey: display.identity.key,
          name: OverlayWindow.screen(for: display.id)?.localizedName ?? display.name,
          isBuiltIn: display.isBuiltIn,
          isVirtual: ownedVirtualIDs.contains(display.id)
            || VirtualDisplayDetection.isVirtual(display.id) == true,
          isMirroring: display.isMirrorSlave,
          capabilities: nil, hasDDCService: false, hdrEngaged: false,
          pixelWidth: mode?.pixelWidth ?? 0, pixelHeight: mode?.pixelHeight ?? 0,
          pointHeight: Double(CGDisplayBounds(display.id).height))
      }
    let capabilities = Dictionary(
      sources.map { ($0.identityKey, $0.capabilities) }, uniquingKeysWith: { first, _ in first })
    let pixels = Dictionary(
      entries.map { ($0.identityKey, ($0.pixelWidth, $0.pixelHeight)) },
      uniquingKeysWith: { first, _ in first })

    let hasCurrentIdentity: @MainActor (CheckupDisplayEntry) -> Bool = { [weak model] entry in
      guard let model,
            let captured = states.first(where: { $0.id == entry.id && $0.display.persistenceKey == entry.identityKey })
      else { return false }
      return model.allControlledStates.contains(where: { $0.id == entry.id && $0.controller === captured.controller })
    }
    let isCurrentTarget: @MainActor (CheckupDisplayEntry) async -> Bool = { [weak model] entry in
      guard let model, hasCurrentIdentity(entry) else { return false }
      // The picker can remain open while HDR or the display layout changes.
      // Re-read after taking the gate, before building runners from its snapshot.
      let hdrEngaged = entry.isBuiltIn ? false : await hdr.measuredHDREnabled(displayID: entry.id)
      guard hasCurrentIdentity(entry), hdrEngaged == entry.hdrEngaged else { return false }
      let current = Self.entries(from: model.allControlledStates.map { readSource($0) })
      guard let live = current.first(where: { $0.id == entry.id && $0.identityKey == entry.identityKey })
      else { return false }
      return live.isBuiltIn == entry.isBuiltIn
        && live.pixelWidth == entry.pixelWidth && live.pixelHeight == entry.pixelHeight
        && live.pointHeight == entry.pointHeight && live.isOnlyDisplay == entry.isOnlyDisplay
    }

    return CheckupEnvironment(
      displays: entries,
      excluded: excluded(from: sources + uncontrolled),
      macOSBuild: ProcessInfo.processInfo.operatingSystemVersionString,
      appBuild: AppInfo.version,
      runners: { [weak model] entry in
        runnerSet(
          for: entry,
          writer: writers[entry.identityKey] ?? NoopDDCWriter(),
          capabilities: capabilities[entry.identityKey] ?? nil,
          hdr: hdr,
          configurator: configurator,
          // Looked up when the leg ends, not captured now: a replug mid-run
          // rebuilds this panel's controllers, leaving a snapshot at a dead wire.
          restoreControls: {
            guard let state = model?.allControlledStates.first(where: {
              $0.display.persistenceKey == entry.identityKey
            }) else { return }
            restoringControls(of: state)
          })
      },
      presenter: presenter,
      bookShowing: { [weak coordinator] identityKey, kind, seconds in
        // A zero size makes the witness card's coverage NaN, and the booking's
        // clamp passes NaN through as full white. Nothing to book is better.
        guard let size = pixels[identityKey], size.0 > 0, size.1 > 0 else {
          log.error("""
          checkup showing not booked: no pixel size for \(DisplayLogging.tag(for: identityKey), privacy: .public)
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
      makeRNG: { SystemRandomNumberGenerator() },
      beginConfiguration: { [weak model] entry in
        guard let model, hasCurrentIdentity(entry) else { return "The display changed. Open the checkup again." }
        if let refusal = await model.beginCheckupConfiguration() { return refusal }
        guard hasCurrentIdentity(entry) else {
          await model.endCheckupConfiguration()
          return "The display changed. Open the checkup again."
        }
        return nil
      },
      endConfiguration: { [weak model] in await model?.endCheckupConfiguration() },
      isCurrentTarget: isCurrentTarget)

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
    // Native pixels as macOS reports them (the rotated frame on the rotated
    // Dell): the space the field is drawn and tapped in, so the plant's space too.
    let native = configurator.nativePixels(for: state.id)
    let prefs = DisplayPrefs(persistenceKey: key)
    return Source(
      id: state.id,
      identityKey: key,
      name: DisplayOrdering.title(
        friendlyName: prefs.friendlyName, hardwareName: state.display.name),
      isBuiltIn: isBuiltIn,
      isVirtual: isVirtual,
      // Both halves: CoreGraphics names the mirrored-onto display, the missing
      // `NSScreen` is what actually stops the draw. Either alone lets a run fabricate a showing.
      isMirroring: CGDisplayMirrorsDisplay(state.id) != kCGNullDirectDisplay
        || OverlayWindow.screen(for: state.id) == nil,
      // The capabilities probe's string where it has one; `readingLiveState` above
      // fills the rest in before anything is graded off them.
      capabilities: model.capabilityString[key],
      // Discovery admits only externals with a live DDC service, so membership
      // is the answer; the built-in carries a `NoopDDCWriter`.
      hasDDCService: !isBuiltIn,
      // Starting value only: `readingLiveState` re-reads the panel, since this cached
      // mirror goes stale when HDR is toggled outside the app. The built-in has no DDC.
      hdrEngaged: !isBuiltIn && state.controller.isHDREngaged,
      pixelWidth: native?.width ?? Int(CGDisplayPixelsWide(state.id)),
      pixelHeight: native?.height ?? Int(CGDisplayPixelsHigh(state.id)),
      // The field view's own height. `CGDisplayBounds` is in points and follows
      // rotation, matching the rotated native size above.
      pointHeight: Double(CGDisplayBounds(state.id).height))
  }

  // MARK: - Runners

  @MainActor
  private static func runnerSet(
    for entry: CheckupDisplayEntry,
    writer: any DDCWriting,
    capabilities: String?,
    hdr: any HDRToggling,
    configurator: CoreGraphicsDisplayConfigurator,
    restoreControls: @escaping @Sendable @MainActor () -> Void
  ) -> CheckupRunnerSet {
    // One read shared by the identity and HDR legs, so the two cannot disagree
    // about the same panel.
    let identity = CheckupIdentityFacts.read(
      displayID: entry.id,
      identityKey: entry.identityKey,
      vendorID: CGDisplayVendorNumber(entry.id),
      modelID: CGDisplayModelNumber(entry.id),
      nativePixels: (entry.pixelWidth, entry.pixelHeight),
      maxRefreshHz: DisplayModeCatalog.distinctRates(configurator.modes(for: entry.id)).max())
    return CheckupRunnerSet(
      identity: { identity },
      capabilities: capabilitiesRunner(
        for: entry, writer: writer, capabilities: capabilities,
        restoreControls: restoreControls),
      mode: CheckupLiveModeRunner(configurator: configurator, displayID: entry.id),
      hdr: CheckupLiveHDRRunner(
        hdr: IdentityCheckedHDRToggling(
          base: hdr, isPresent: presence(of: entry.id, configurator: configurator)),
        displayID: entry.id, identity: identity ?? unreadIdentity(for: entry)))
  }

  /// Captured now, at runner build: the HDR leg asks later whether the same
  /// hardware still holds this display ID.
  private static func presence(
    of displayID: CGDirectDisplayID, configurator: CoreGraphicsDisplayConfigurator
  ) -> @Sendable () -> Bool {
    let identity = configurator.displays().first(where: { $0.id == displayID })?.identity
    return {
      guard let identity else { return false }
      return configurator.displays().contains { $0.id == displayID && $0.identity == identity }
    }
  }

  /// Never asked to run: the plan pre-grades a display with no DDC path. Exists
  /// so the runner set has one shape.
  private struct NoCapabilitiesRunner: CheckupCapabilitiesRunning {
    func run() async -> [CheckupClaim] { [] }
  }

  /// The capabilities round trip writes VCP registers straight at the display, past the
  /// coalescers that own them. A control moved mid-leg is left at the runner's
  /// read-back value while the coalescer's memo names the newer one, so the
  /// move back is skipped as a duplicate. Restores whatever the verdict: the
  /// writes went out either way.
  struct ControlRestoringCapabilitiesRunner: CheckupCapabilitiesRunning {
    let base: any CheckupCapabilitiesRunning
    let restore: @Sendable @MainActor () -> Void

    func run() async -> [CheckupClaim] {
      let claims = await base.run()
      await restore()
      return claims
    }
  }

  /// Same gates as the startup/wake restore: `restoreToHardware` gates itself,
  /// and a panel this app never wrote must not be handed an assumed default.
  @MainActor
  static func restoringControls(of state: AppModel.DisplayState) {
    if state.controller.hasStoredValue {
      state.controller.resetWriteMemo()
      state.controller.reassertHardware()
    }
    state.contrast.resetWriteMemo()
    state.contrast.restoreToHardware()
    state.volume.resetWriteMemo()
    state.volume.restoreToHardware()
  }

  private static func capabilitiesRunner(
    for entry: CheckupDisplayEntry, writer: any DDCWriting, capabilities: String?,
    restoreControls: @escaping @Sendable @MainActor () -> Void
  ) -> any CheckupCapabilitiesRunning {
    guard entry.panelClass == .readsDDC, let capabilities else { return NoCapabilitiesRunner() }
    return ControlRestoringCapabilitiesRunner(
      base: CheckupLiveCapabilitiesRunner(writer: writer, capabilities: capabilities),
      restore: restoreControls)
  }

  /// For a display with no parsed EDID. Nothing here is presented as reported
  /// by the panel; the absent EOTF flags read as "does not advertise HDR".
  private static func unreadIdentity(for entry: CheckupDisplayEntry) -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(
      identityKey: entry.identityKey, vendorID: 0, modelID: 0, serial: nil,
      manufactureWeek: nil, manufactureYear: nil,
      nativePixelWidth: entry.pixelWidth, nativePixelHeight: entry.pixelHeight,
      maxRefreshHz: nil, supportsPQEOTF: false, supportsHDRGammaEOTF: false,
      productName: entry.name)
  }
}

/// HDR writes stop for good once the display ID stops naming the panel the run
/// picked: a dock cycle can hand the ID to another panel mid-settle, and the
/// leg's restore would land there. Reads pass through.
///
/// `@unchecked Sendable`: `gone` is behind `lock`; the rest is immutable.
final class IdentityCheckedHDRToggling: HDRToggling, @unchecked Sendable {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "checkup")
  private let base: any HDRToggling
  private let isPresent: @Sendable () -> Bool
  private let lock = NSLock()
  private var gone = false

  init(base: any HDRToggling, isPresent: @escaping @Sendable () -> Bool) {
    self.base = base
    self.isPresent = isPresent
  }

  /// Latches: a display that returns with the same ID has been through a
  /// replug the run did not watch.
  private func stillPresent() -> Bool {
    lock.withLock {
      if !gone, !isPresent() { gone = true }
      return !gone
    }
  }

  func supportsHDR(displayID: CGDirectDisplayID) async -> Bool {
    await base.supportsHDR(displayID: displayID)
  }

  func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool {
    await base.isHDREnabled(displayID: displayID)
  }

  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool {
    await base.measuredHDREnabled(displayID: displayID)
  }

  func observedHDREnabled(displayID: CGDirectDisplayID) async -> Bool? {
    await base.observedHDREnabled(displayID: displayID)
  }

  @discardableResult
  func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
    guard stillPresent() else {
      Self.log.info("checkup HDR write skipped: display \(displayID, privacy: .public) is no longer the panel the run picked")
      return false
    }
    return await base.setHDR(displayID: displayID, enabled: enabled)
  }

  func displaysReconfigured() async {
    await base.displaysReconfigured()
  }
}
