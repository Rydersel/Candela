import AppKit
import CandelaKit
import SwiftUI
import UniformTypeIdentifiers

/// The Diagnostics sub-page (spec §7): what this display is, how its brightness
/// is being driven, what it told us, what is unavailable and why, and what is
/// true right now — plus the two report actions.
///
/// It replaces `DisplayDiagnosticsSection`, whose five caption-headed
/// pseudo-groups are now real `Section` headers, and it leads with a
/// plain-English verdict so the answer to "is this working?" is the first thing
/// on the page rather than something to be assembled from six rows.
///
/// The feature is the HONESTY RULES (DT30), not the rows:
/// - every "unavailable" row states a REASON drawn from a typed value;
/// - an unanswered display is reported as UNANSWERED, never as unsupported;
/// - a write-only panel is NAMED, with the consequence stated plainly;
/// - we never claim what macOS hides, only what our own curation did;
/// - "not measured yet" (nil) is never rendered as "no answer" (empty);
/// - internal key names never reach copy (D25).
///
/// The SENTENCES those rules govern are not here (#127). Every value on the
/// right of a row comes from `DiagnosticsCopy` in CandelaKit, where each
/// distinction is pinned by a test, and every caption from
/// `DiagnosticsPageCopy` in this target. What is left in this file is which rows
/// exist, for which display, and which facts each one is handed: read a row's
/// wording in the copy enum, and read WHEN it is shown here.
///
/// It renders under the BUILT-IN display too (DT45), not only under externals —
/// and the rules above are what make that worth doing rather than merely
/// possible. "Why can't hardware control reach my laptop screen?" is a real
/// question this feature exists to answer, and it is answered here, once, in
/// the brightness section. Every row that describes a data cable, an EDID or a
/// DDC answer is OMITTED for the built-in rather than rendered against a fact
/// that will never arrive: `DisplayDiscovery` is external-only by construction,
/// so a "Connection: not enumerated yet" on the built-in would be a permanent
/// promise of an answer, which is exactly the shape DT30 rule (e) forbids.
///
/// `@MainActor` is load-bearing: a `View`'s stored and computed properties
/// other than `body` are nonisolated under complete concurrency, and this one
/// constructs and reads main-actor types.
///
/// The page WRITES NO PREF (DT31). Its two buttons touch the pasteboard and the
/// filesystem, and the one chevron row is navigation. D29 does not bind it, and
/// binds the moment a control that can disable a command is added.
@MainActor
struct DiagnosticsPage: View {
  let state: AppModel.DisplayState
  @Binding var path: [DisplaySubPage]
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var facts: DisplayHardwareFacts? { model.hardwareFacts[persistenceKey] }
  private var brightnessPath: BrightnessPath { state.controller.brightnessPath }

  /// Asked of the model's own slot rather than of the persistence key: the
  /// model is the thing that decides which display is the built-in, and a
  /// literal key compared here would be a second, driftable copy of that
  /// decision.
  private var isBuiltIn: Bool { model.builtIn?.id == state.id }

  var body: some View {
    // MANDATORY. `DisplayPrefs` is plain `UserDefaults` and is not observable;
    // `prefsRevision` is the ONLY invalidation signal, and this page reads
    // prefs in four of its five sections. Omitting it yields a silently stale
    // page.
    let _ = model.prefsRevision

    Form {
      SubPageHeader(
        title: DisplaySubPage.diagnostics.title,
        currentKey: persistenceKey,
        displays: displays,
        onSwitch: onSwitch
      )

      // Spec §7: one sentence, above everything. Composed from the same state
      // the "Last brightness command" and "Reading values back" rows below
      // render, so the summary cannot disagree with its own evidence.
      Section {
        Text(verbatim: verdictText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        thisDisplayRows
      } header: {
        Text("This Display").settingsHeading()
      }

      Section {
        brightnessRows
      } header: {
        Text("Brightness Control").settingsHeading()
      }

      // Every row in this section is about a DDC answer, and the built-in never
      // gives one — it has no wire and `probeVolumeCapabilities` walks
      // `model.displays`, which is external-only. Rendering it there would put
      // "Not asked yet" under a heading promising an answer that can never
      // arrive (DT30 rule (e)); the built-in's DDC story is already stated
      // once, in Brightness Control, where it is true.
      if !isBuiltIn {
        Section {
          reportedCapabilitiesRows
        } header: {
          Text("Reported Capabilities").settingsHeading()
        }
      }

      Section {
        availabilityRows
      } header: {
        Text("Availability").settingsHeading()
      }

      Section {
        rightNowRows
      } header: {
        Text("Right Now").settingsHeading()
      }

      actionsSection
    }
    .formStyle(.grouped)
  }

  // MARK: - Verdict

  private var verdictText: String {
    DiagnosticsCopy.verdict(
      isBuiltIn: isBuiltIn,
      path: brightnessPath,
      lastApplyFailed: state.controller.lastApplyFailed(),
      hasAppliedTarget: state.controller.lastAppliedTarget() != nil,
      evidence: readEvidence,
      app: AppInfo.productName
    )
  }

  // MARK: - This Display

  @ViewBuilder private var thisDisplayRows: some View {
    LabeledContent("Reported name") {
      Text(verbatim: state.display.name).foregroundStyle(.secondary)
    }

    if !DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName).isEmpty {
      LabeledContent("Your name for it") {
        Text(verbatim: DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName))
          .foregroundStyle(.secondary)
      }
    }

    // The cable-and-EDID rows. Omitted wholesale for the built-in panel — see
    // the type comment. The hub's identity block deliberately does NOT carry
    // "Connection" (T12); it lives here, where the rest of the cable's story is.
    if !isBuiltIn {
      SettingRow(DiagnosticsPageCopy.connection) {
        LabeledContent("Connection") {
          Text(verbatim: DiagnosticsCopy.connection(facts)).foregroundStyle(.secondary)
        }
      }

      LabeledContent("Manufacturer") {
        Text(verbatim: DiagnosticsCopy.manufacturer(facts)).foregroundStyle(.secondary)
      }

      LabeledContent("Serial number") {
        Text(verbatim: DiagnosticsCopy.serial(facts)).foregroundStyle(.secondary)
      }

      if let facts, facts.numericSerialNumber == nil, facts.alphanumericSerialNumber == nil {
        SettingsCaption(DiagnosticsPageCopy.noSerialNumber)
      }

      if let width = facts?.physicalWidthCm, let height = facts?.physicalHeightCm {
        LabeledContent("Display size") {
          Text(verbatim: DiagnosticsCopy.displaySize(widthCm: width, heightCm: height))
            .foregroundStyle(.secondary)
        }
      }
    }

    if let native = model.displayModes.catalogs[state.id], native.nativeKnown,
       let current = native.current {
      LabeledContent("Current mode") {
        Text(verbatim: DiagnosticsCopy.mode(current)).foregroundStyle(.secondary)
      }
    }

    resolutionSourceRows

    identityKeysRow
  }

  /// Where this display's resolutions came from.
  ///
  /// DT30 rule (d): this describes OUR OWN enumeration, never a claim about
  /// what macOS is hiding. "Listed by macOS" is a count we made; "found beyond
  /// that list" is a count we made. Neither asserts why macOS omitted them.
  @ViewBuilder private var resolutionSourceRows: some View {
    if let catalog = model.displayModes.catalogs[state.id] {
      let publishedCount = catalog.all.count { $0.provenance == .coreGraphics }
      let revealedCount = catalog.all.count { $0.provenance == .coreGraphicsServices }

      LabeledContent("Resolutions listed by macOS") {
        Text(verbatim: "\(publishedCount)").foregroundStyle(.secondary)
      }

      LabeledContent("Additional resolutions found") {
        Text(verbatim: DiagnosticsCopy.additionalResolutions(
          revealed: revealedCount, revealsHiddenModes: model.displayModes.revealsHiddenModes))
          .foregroundStyle(.secondary)
      }

      wireTimingRow(withheld: catalog.withheldForWireTiming)
    }
  }

  /// #110. Silent when the guard is on and had nothing to withhold, which is
  /// the ordinary case on most panels.
  @ViewBuilder private func wireTimingRow(withheld: Int) -> some View {
    if !model.displayModes.guardsWireTiming {
      LabeledContent(DiagnosticsCopy.wireTimingCheckLabel) {
        Text(verbatim: "Off").foregroundStyle(.secondary)
      }
      .help(DiagnosticsCopy.wireTimingGuardOff)
    } else if withheld > 0 {
      LabeledContent(DiagnosticsCopy.wireTimingWithheldLabel) {
        Text(verbatim: "\(withheld)").foregroundStyle(.secondary)
      }
      .help(DiagnosticsCopy.wireTimingWithheld)
    }
  }

  /// The two keys this display's settings hang off. Split out of the section so
  /// the IOReg tooltip can be attached for externals and left off the built-in,
  /// whose IOReg facts are never read at all: a tooltip there would be
  /// reporting a lookup that never ran.
  @ViewBuilder private var identityKeysRow: some View {
    let caption = DiagnosticsPageCopy.identityKeys(keysMatch: displayKey == persistenceKey)
    let row = SettingRow(caption) {
      VStack(alignment: .leading, spacing: 2) {
        LabeledContent("Settings key") {
          Text(verbatim: persistenceKey).foregroundStyle(.secondary)
        }
        LabeledContent("Display key") {
          Text(verbatim: DiagnosticsCopy.displayKey(displayKey))
            .foregroundStyle(.secondary)
        }
      }
    }

    if isBuiltIn {
      row
    } else {
      row.help(DiagnosticsCopy.ioregPath(facts))
    }
  }

  private var displayKey: String? {
    model.displayModes.catalogs[state.id]?.display.identity.key
  }

  // MARK: - Brightness Control

  @ViewBuilder private var brightnessRows: some View {
    SettingRow(DiagnosticsPageCopy.brightnessPath(brightnessPath)) {
      LabeledContent("Brightness path") {
        Text(verbatim: DiagnosticsCopy.brightnessPath(brightnessPath)).foregroundStyle(.secondary)
      }
    }

    SettingRow(DiagnosticsPageCopy.nativeBrightness) {
      LabeledContent("Native brightness") {
        Text(verbatim: DiagnosticsCopy.nativeBrightness(
          isAvailable: DisplayServices.isAvailable, app: AppInfo.productName))
          .foregroundStyle(.secondary)
      }
    }

    if isBuiltIn {
      SettingRow(DiagnosticsPageCopy.builtInHardwareControl) {
        LabeledContent("Hardware control") {
          Text(verbatim: DiagnosticsCopy.builtInHardwareControl)
            .foregroundStyle(.secondary)
        }
      }
    }

    // Gamma interference is a fight over ONE backend, and the row is shown
    // only to a display actually using it.
    //
    // Two claims an earlier version of this row could not support. First, the
    // counter is only ever touched inside `checkBeforeApply`, which runs one
    // statement before a GAMMA apply — a display on the hardware, native or
    // overlay path is never looked at, so its permanent 0 rendered as "None
    // this session" asserted absence on the strength of a probe that never
    // ran. Omit rather than blank (DT45). Second, the window was wrong:
    // `resetCounter()` fires on EVERY display reconfiguration
    // (`StatusItemController`), so "this session" told a user who had watched
    // a conflict happen, then woken the Mac, that there had been none.
    if usesGammaLeg, let monitor = model.gammaInterference {
      SettingRow(DiagnosticsPageCopy.gammaConflicts) {
        LabeledContent("Color profile conflicts") {
          Text(verbatim: DiagnosticsCopy.gammaConflicts(monitor.interferenceCount(for: state.id)))
            .foregroundStyle(.secondary)
        }
      }
      if monitor.suspendedForSession {
        SettingsCaption(DiagnosticsPageCopy.gammaWatchSuspended)
      }
    }
  }

  /// Whether the gamma backend is the one carrying this display's software
  /// leg — the only configuration in which anything checks for a clobber.
  private var usesGammaLeg: Bool {
    switch brightnessPath {
    case .software(.gamma), .combined(_, .gamma), .softwareOnly(.gamma, _, _):
      true
    case .native, .hardware, .software, .combined, .softwareOnly, .unavailable:
      false
    }
  }

  // MARK: - Reported Capabilities

  private var capabilities: String? { model.capabilityString[persistenceKey] }

  /// nil means the description did not parse end to end (D24), which is a
  /// DIFFERENT answer from "the display listed no codes". A partially parsed
  /// list must never be shown as though it were the display's advertised list.
  private var advertisedCodes: Set<UInt8>? {
    capabilities.flatMap { CapabilityString.codes(in: $0) }
  }

  /// Whether the probe has run against this display since it was plugged in.
  /// ABSENT is not `.unknown`: an absent entry means nobody has asked yet.
  private var wasAsked: Bool { model.volumeSupport[persistenceKey] != nil }

  @ViewBuilder private var reportedCapabilitiesRows: some View {
    SettingRow(DiagnosticsPageCopy.capabilityAnswer(
      hasDescription: capabilities != nil,
      parsedACommandList: advertisedCodes != nil,
      wasAsked: wasAsked,
      isHDREngaged: state.controller.isHDREngaged
    )) {
      LabeledContent("Capability request") {
        Text(verbatim: DiagnosticsCopy.capabilityAnswer(
          hasDescription: capabilities != nil,
          parsedACommandList: advertisedCodes != nil,
          wasAsked: wasAsked,
          app: AppInfo.productName
        )).foregroundStyle(.secondary)
      }
    }
    .help(DiagnosticsPageCopy.capabilityRequestHelp)

    if let capabilities {
      LabeledContent("MCCS version") {
        Text(verbatim: CapabilityString.tag("mccs_ver", in: capabilities)
          ?? DiagnosticsCopy.notStated)
          .foregroundStyle(.secondary)
      }
      LabeledContent("Model") {
        Text(verbatim: CapabilityString.tag("model", in: capabilities)
          ?? DiagnosticsCopy.notStated)
          .foregroundStyle(.secondary)
      }
      LabeledContent("Display type") {
        Text(verbatim: CapabilityString.tag("type", in: capabilities)
          ?? DiagnosticsCopy.notStated)
          .foregroundStyle(.secondary)
      }

      SettingRow(DiagnosticsPageCopy.advertisedCommands) {
        LabeledContent("Advertised commands") {
          Text(verbatim: DiagnosticsCopy.advertisedCommands(
            advertisedCodes, app: AppInfo.productName)).foregroundStyle(.secondary)
        }
      }

      DisclosureGroup(DiagnosticsPageCopy.rawDescriptionDisclosure) {
        Text(verbatim: capabilities)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    SettingRow(DiagnosticsPageCopy.readEvidence(
      readEvidence,
      isSafeMode: model.isSafeMode,
      readsBackAtStartup: prefs.startupAction == .read
    )) {
      LabeledContent("Reading values back") {
        Text(verbatim: DiagnosticsCopy.readEvidence(readEvidence, app: AppInfo.productName))
          .foregroundStyle(.secondary)
      }
    }

    LabeledContent("Brightness scale") {
      // The brightness controller's OWN evidence, not the folded `readEvidence`:
      // the maximum comes from the brightness read alone, so a volume read that
      // answered must not be allowed to speak for it.
      Text(verbatim: DiagnosticsCopy.brightnessScale(
        didReadMax: state.controller.didReadMaxDDC,
        maxValue: state.controller.maxDDCValue,
        evidence: state.controller.readEvidence,
        app: AppInfo.productName
      )).foregroundStyle(.secondary)
    }
  }

  /// Worst evidence across this display's three controllers. One `allZeros` is
  /// never cancelled by a later `notAttempted`.
  private var readEvidence: DDCReadEvidence {
    DDCReadEvidence.worst([
      state.controller.readEvidence,
      state.volume.readEvidence,
      state.contrast.readEvidence,
    ])
  }

  // MARK: - Availability

  /// DT30 rule (a) is enforced in `DiagnosticsCopy`: no row here may read just
  /// "Unavailable" or "Not supported", every one names the thing that took the
  /// feature away, and every reason comes off a typed value rather than being
  /// composed from prefs at the point of display.
  ///
  /// Volume, contrast and mute are the DDC audio and picture commands, and the
  /// built-in has no wire to carry them: nothing in this app ever offers them
  /// for it. HDR is likewise external-only: `BrightnessController` builds the
  /// built-in slot with no HDR backend at all, so `supportsHDR` there is a
  /// hardwired false that would render as "this display reports no HDR modes"
  /// about a panel whose HDR macOS drives perfectly well. Both are omitted
  /// rather than answered wrongly.
  @ViewBuilder private var availabilityRows: some View {
    LabeledContent("Brightness") {
      Text(verbatim: DiagnosticsCopy.brightnessAvailability(brightnessPath))
        .foregroundStyle(.secondary)
    }

    if !isBuiltIn {
      LabeledContent("Volume") {
        Text(verbatim: DiagnosticsCopy.volumeAvailability(
          override: prefs.audioSinkOverride,
          isAvailable: state.volume.isAvailable,
          support: model.volumeSupport[persistenceKey],
          hasDescription: capabilities != nil,
          forceSoftware: prefs.forceSoftware,
          app: AppInfo.productName
        )).foregroundStyle(.secondary)
      }
      .help(DiagnosticsPageCopy.volumeHelp)

      LabeledContent("Contrast") {
        Text(verbatim: DiagnosticsCopy.contrastAvailability(
          isAvailable: state.contrast.isAvailable, forceSoftware: prefs.forceSoftware))
          .foregroundStyle(.secondary)
      }
      .help(DiagnosticsPageCopy.contrastHelp)

      LabeledContent("Mute") {
        Text(verbatim: DiagnosticsCopy.muteAvailability(
          muteEnabled: prefs.enableMuteUnmute,
          volumeAvailable: state.volume.isAvailable,
          forceSoftware: prefs.forceSoftware
        )).foregroundStyle(.secondary)
      }
      .help(DiagnosticsPageCopy.muteHelp)

      LabeledContent("HDR") {
        Text(verbatim: DiagnosticsCopy.hdrAvailability(
          displayServicesAvailable: DisplayServices.isAvailable,
          supportsHDR: state.controller.supportsHDR,
          app: AppInfo.productName
        )).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Right Now

  /// State, not settings. Everything here can be different a second from now,
  /// and every one of them has words — nothing in this section is carried by a
  /// colour or an icon alone.
  ///
  /// The HDR and sound-output rows are external-only for the same reasons as
  /// in Availability: the built-in has no HDR backend in this app and no volume
  /// command, so both would answer from a hardwired default rather than from
  /// anything observed.
  @ViewBuilder private var rightNowRows: some View {
    if !isBuiltIn {
      LabeledContent("HDR") {
        Text(verbatim: DiagnosticsCopy.hdrState(engaged: state.controller.isHDREngaged))
          .foregroundStyle(.secondary)
      }

      if state.controller.isHDREngaged, state.controller.hdrMode == .off {
        SettingsCaption(DiagnosticsPageCopy.hdrTurnedOnOutside)
      }
    }

    LabeledContent(DiagnosticsPageCopy.writeGateLabel(isBuiltIn: isBuiltIn)) {
      Text(verbatim: DiagnosticsCopy.writeGate(
        isSending: model.displayManager.isEpochCurrent(model.displayManager.currentEpoch())))
        .foregroundStyle(.secondary)
    }

    if model.isSafeMode {
      SettingRow(caption: SettingsCaption(verbatim: DiagnosticsPageCopy.safeMode)) {
        LabeledContent("Safe Mode") {
          Text(verbatim: DiagnosticsCopy.safeModeState).foregroundStyle(.secondary)
        }
      }
    }

    // The caption is attached whenever a family is missing, not only when they
    // all are. Partial states are ordinary now that volume and mute arm
    // separately, and a row that names two families out of three explains the
    // absent one to nobody.
    if model.lastArmedTapConfig != nil, !watchesEveryFamily {
      SettingRow(DiagnosticsPageCopy.watchedKeys) {
        LabeledContent("Keys being watched") {
          Text(verbatim: watchedKeysText).foregroundStyle(.secondary)
        }
        // The conditions are a list, so they render as one rather than as a
        // paragraph nobody finishes (SO15/SO16).
        ForEach(DiagnosticsPageCopy.keyWatchRequirements, id: \.title) { requirement in
          KeyRequirementRow(
            title: requirement.title, needs: requirement.needs, spoken: requirement.spoken
          )
        }
      }
    } else {
      LabeledContent("Keys being watched") {
        Text(verbatim: watchedKeysText).foregroundStyle(.secondary)
      }
    }

    if model.accessibility.isWarningWarranted {
      SettingsCaption(DiagnosticsPageCopy.accessibilityMissing)
    }

    if !isBuiltIn {
      LabeledContent("Sound output") {
        Text(verbatim: audioMatchText).foregroundStyle(.secondary)
      }
    }

    LabeledContent("Last brightness command") {
      Text(verbatim: DiagnosticsCopy.lastWrite(
        target: state.controller.lastAppliedTarget(),
        failed: state.controller.lastApplyFailed()
      )).foregroundStyle(.secondary)
    }

    if let report = model.displayModes.report(for: state.id) {
      LabeledContent("Last resolution problem") {
        Text(verbatim: DiagnosticsCopy.reapplyProblem(report.notice, app: AppInfo.productName))
          .foregroundStyle(.secondary)
      }
      .modifier(ReapplyDiagnostic(notice: report.notice))
    }

    LabeledContent("Mirroring") {
      Text(verbatim: DiagnosticsCopy.mirroring(
        isMirrorSlave: model.displayModes.catalogs[state.id]?.display.isMirrorSlave))
        .foregroundStyle(.secondary)
    }
  }

  /// Reads the LAST ARMED config, not a freshly computed one. The two differ
  /// exactly when a rearm failed — which is the case this row is for (B9).
  private var watchedKeysText: String {
    DiagnosticsCopy.watchedKeys(
      families: watchedKeyFamilies, tapRunning: model.lastArmedTapConfig != nil)
  }

  /// Whether the tap is watching everything it ever watches. False while any
  /// family is released, which is what the caption explains.
  private var watchesEveryFamily: Bool {
    guard let config = model.lastArmedTapConfig else { return false }
    return config.watchedKeys.isSuperset(
      of: [.brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .mute])
  }

  /// Split out so the row can tell "watching nothing" from "not running" and
  /// caption the first without recomputing the words.
  private var watchedKeyFamilies: [String] {
    guard let config = model.lastArmedTapConfig else { return [] }
    return DiagnosticsCopy.watchedKeyFamilies(
      brightness: config.watchedKeys.contains(.brightnessUp)
        || config.watchedKeys.contains(.brightnessDown),
      // Reported apart because they are ARMED apart: the two write different
      // registers, and a display can list one and deny the other.
      volume: config.watchedKeys.contains(.volumeUp)
        || config.watchedKeys.contains(.volumeDown),
      mute: config.watchedKeys.contains(.mute)
    )
  }

  private var audioMatchText: String {
    guard let device = model.audioDevices.defaultOutputDevice() else {
      return DiagnosticsCopy.noDefaultOutputDevice
    }
    return DiagnosticsCopy.audioMatch(
      deviceName: device.name,
      matches: AudioRoutingPolicy.displayMatchesDevice(
        deviceName: device.name,
        rawDisplayName: state.display.name,
        nameOverride: prefs.audioDeviceNameOverride
      )
    )
  }

  // MARK: - Actions

  @ViewBuilder private var actionsSection: some View {
    Section {
      SettingRow(DiagnosticsPageCopy.reportScope) {
        DiagnosticsReportActions()
      }

      // A link, not a setting — the page stays read-only in content (spec §7).
      // Offered only where there is something on the other end: the built-in's
      // destination has no Advanced sub-page, because it has no hardware
      // control to method.
      if !isBuiltIn {
        NavigationRow(
          title: DiagnosticsPageCopy.controlMethodTitle,
          value: DiagnosticsPageCopy.controlMethodValue
        ) {
          // Replaces the stack rather than pushing onto it, so Back from
          // Control Method returns to the display's own page. The user came
          // here for an answer and is being sent to the control that acts on
          // it; the diagnostics page is not a step they need to walk back
          // through.
          path = [.advanced]
        }
      }
    }
  }
}

/// One key family and what it needs before its keys are watched.
///
/// Same shape and same reasoning as the Keyboard pane's modifier legend: a
/// two-column row that narrows to two lines, read aloud as one sentence rather
/// than as two fragments. Not that type reused, because its columns are a
/// shortcut and a key combination, and these are a family and a condition.
private struct KeyRequirementRow: View {
  let title: String
  let needs: String
  /// The prose this row replaced, kept whole for VoiceOver (SO16). It carries
  /// the mode-dependent corners the visible half deliberately leaves out.
  let spoken: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        Text(verbatim: title)
        Spacer(minLength: 8)
        needsText.lineLimit(1)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
        needsText
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var needsText: some View {
    Text(verbatim: needs).foregroundStyle(.secondary)
  }
}

/// The Copy/Save pair and the transient confirmation, in one component because
/// they exist in two places: here and in About, which survives every display's
/// departure (spec §7). Two copies of a clipboard write and an `NSSavePanel` is
/// two things to keep in agreement.
@MainActor
struct DiagnosticsReportActions: View {
  @Environment(AppModel.self) private var model

  @State private var justCopied = false
  /// Cancelled and replaced on every copy, so a second click restarts the two
  /// seconds instead of letting the first click's timer clear the label early.
  @State private var confirmationTask: Task<Void, Never>?
  @State private var saveError: String?

  var body: some View {
    HStack(spacing: 8) {
      Button(DiagnosticsPageCopy.copyReport) { copyReport() }
        .accessibilityLabel(Text(DiagnosticsPageCopy.copyReport))
      Button(DiagnosticsPageCopy.saveReport) { saveReport() }
        .accessibilityLabel(Text(DiagnosticsPageCopy.saveReport))
      if justCopied {
        Text(DiagnosticsPageCopy.copied)
          .foregroundStyle(.secondary)
          .transition(.opacity)
          .accessibilityLabel(Text(DiagnosticsPageCopy.copiedAccessibly))
      }
    }
    .alert(
      DiagnosticsPageCopy.saveFailed,
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button(DiagnosticsPageCopy.acknowledge) { saveError = nil }
    } message: {
      Text(verbatim: saveError ?? "")
    }
  }

  private func copyReport() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(DiagnosticsReport.render(model.diagnosticsSnapshot()), forType: .string)
    withAnimation { justCopied = true }
    confirmationTask?.cancel()
    confirmationTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation { justCopied = false }
    }
  }

  /// The snapshot is taken AFTER the panel is dismissed, not before it opens:
  /// the file should describe the machine at the moment it was written, and a
  /// save panel can sit open for minutes across a replug.
  private func saveReport() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = DiagnosticsPageCopy.reportFileName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try DiagnosticsReport.render(model.diagnosticsSnapshot())
        .write(to: url, atomically: true, encoding: .utf8)
    } catch {
      // Silence here would look exactly like success. The report exists to be
      // handed to somebody, so a save that did not happen has to say so.
      saveError = error.localizedDescription
    }
  }
}
