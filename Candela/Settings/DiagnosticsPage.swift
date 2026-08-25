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

    SettingsPageScaffold {
      SubPageHeader(
        title: DisplaySubPage.diagnostics.title,
        currentKey: persistenceKey,
        displays: displays,
        onSwitch: onSwitch
      )

      // Spec §7: one sentence, above everything, on a card of its own so it
      // reads as the page's answer rather than as the first of forty rows.
      // Composed from the same state the "Last brightness command" and
      // "Reading values back" rows below render, so the summary cannot
      // disagree with its own evidence.
      SettingsCard {
        Text(verbatim: verdictText)
          .foregroundStyle(SettingsTheme.titleColor)
          .fixedSize(horizontal: false, vertical: true)
      }

      SettingsCardSection(title: "This Display") {
        thisDisplayRows
      }

      SettingsCardSection(title: "Brightness Control") {
        brightnessRows
      }

      // Every row in this section is about a DDC answer, and the built-in never
      // gives one — it has no wire and `probeVolumeCapabilities` walks
      // `model.displays`, which is external-only. Rendering it there would put
      // "Not asked yet" under a heading promising an answer that can never
      // arrive (DT30 rule (e)); the built-in's DDC story is already stated
      // once, in Brightness Control, where it is true.
      if !isBuiltIn {
        SettingsCardSection(title: "Reported Capabilities") {
          reportedCapabilitiesRows
        }
      }

      SettingsCardSection(title: "Availability") {
        availabilityRows
      }

      SettingsCardSection(title: "Right Now") {
        rightNowRows
      }

      actionsSection
    }
  }

  /// The right-hand half of a row, in the window's body weight. One helper for
  /// forty-odd rows, so the answers cannot end up styled forty different ways.
  private func valueText(_ value: String) -> some View {
    Text(verbatim: value).foregroundStyle(SettingsTheme.bodyColor)
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
      valueText(state.display.name)
    }

    if !DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName).isEmpty {
      SettingsCardDivider()
      LabeledContent("Your name for it") {
        valueText(DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName))
      }
    }

    // The cable-and-EDID rows. Omitted wholesale for the built-in panel — see
    // the type comment. The hub's identity block deliberately does NOT carry
    // "Connection" (T12); it lives here, where the rest of the cable's story is.
    if !isBuiltIn {
      SettingsCardDivider()
      SettingRow(DiagnosticsPageCopy.connection) {
        LabeledContent("Connection") {
          valueText(DiagnosticsCopy.connection(facts))
        }
      }

      SettingsCardDivider()
      LabeledContent("Manufacturer") {
        valueText(DiagnosticsCopy.manufacturer(facts))
      }

      SettingsCardDivider()
      LabeledContent("Serial number") {
        valueText(DiagnosticsCopy.serial(facts))
      }

      if let facts, facts.numericSerialNumber == nil, facts.alphanumericSerialNumber == nil {
        SettingsCaption(DiagnosticsPageCopy.noSerialNumber)
          .padding(.bottom, 6)
      }

      if let width = facts?.physicalWidthCm, let height = facts?.physicalHeightCm {
        SettingsCardDivider()
        LabeledContent("Display size") {
          valueText(DiagnosticsCopy.displaySize(widthCm: width, heightCm: height))
        }
      }
    }

    // `onScreen`, never the raw readback. While a size this app renders is
    // engaged the readback names the display's native geometry, and this row
    // would then contradict the "Synthesized size active" line further down the
    // same page and the mode line of the report pasted from it.
    if let native = model.displayModes.catalogs[state.id], native.nativeKnown,
       let onScreen = native.onScreen {
      SettingsCardDivider()
      LabeledContent("Current mode") {
        valueText(DiagnosticsCopy.mode(onScreen))
      }
    }

    resolutionSourceRows

    SettingsCardDivider()
    identityKeysRow
  }

  /// Where this display's resolutions came from.
  ///
  /// DT30 rule (d): this describes OUR OWN enumeration, never a claim about
  /// what macOS is hiding. "Listed by macOS" is a count we made; "found beyond
  /// that list" is a count we made. Neither asserts why macOS omitted them.
  @ViewBuilder private var resolutionSourceRows: some View {
    if let catalog = model.displayModes.catalogs[state.id] {
      // Two counts, two predicates, and they are not each other's complement.
      // "Listed by macOS" names ONE source explicitly; `isRevealed` switches
      // over the provenance, so a third source is a compile error there and a
      // silent miscount here.
      //
      // Synthesis was that third source, and it is counted separately below
      // rather than folded into either of these: `catalog.all` is the display's
      // OWN enumeration and holds no synthesized stop, so neither count is
      // wrong, and a synthesized size is not a resolution anyone found. It is
      // one this app renders.
      let publishedCount = catalog.all.count { $0.provenance == .coreGraphics }
      let revealedCount = catalog.all.count(where: \.isRevealed)

      SettingsCardDivider()
      LabeledContent("Resolutions listed by macOS") {
        valueText("\(publishedCount)")
      }

      SettingsCardDivider()
      LabeledContent("Additional resolutions found") {
        valueText(DiagnosticsCopy.additionalResolutions(
          revealed: revealedCount, revealsHiddenModes: model.displayModes.revealsHiddenModes))
      }

      wireTimingRow(withheld: catalog.withheldForWireTiming)
      synthesizedOfferRow(catalog)
    }
  }

  /// The third source (SS4/SS5), silent unless this display's opt-in is on: a
  /// count of 0 under an opt-in nobody turned on would read as a feature that
  /// looked and found nothing.
  ///
  /// A whole line rather than a label and a value, because it is a report line
  /// about what this app added rather than a property of the display, and the
  /// two facts it carries (that sizes are offered at all, and how many) only
  /// mean anything together. Secondary, like every value in this page's rows,
  /// so a line that is not a heading does not read as one.
  @ViewBuilder private func synthesizedOfferRow(
    _ catalog: DisplayModeCoordinator.Catalog
  ) -> some View {
    if model.synthesis.offersSyntheticSizes(displayID: state.id) {
      SettingsCardDivider()
      Text(verbatim: SynthesisCopy.diagnosticsOffered(catalog.syntheticStops.count))
        .foregroundStyle(SettingsTheme.bodyColor)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
    }
  }

  /// #110. Silent when the guard is on and had nothing to withhold, which is
  /// the ordinary case on most panels.
  @ViewBuilder private func wireTimingRow(withheld: Int) -> some View {
    if !model.displayModes.guardsWireTiming {
      SettingsCardDivider()
      LabeledContent(DiagnosticsCopy.wireTimingCheckLabel) {
        valueText("Off")
      }
      .help(DiagnosticsCopy.wireTimingGuardOff)
    } else if withheld > 0 {
      SettingsCardDivider()
      LabeledContent(DiagnosticsCopy.wireTimingWithheldLabel) {
        valueText("\(withheld)")
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
          valueText(persistenceKey)
        }
        LabeledContent("Display key") {
          valueText(DiagnosticsCopy.displayKey(displayKey))
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
        valueText(DiagnosticsCopy.brightnessPath(brightnessPath))
      }
    }

    SettingsCardDivider()

    SettingRow(DiagnosticsPageCopy.nativeBrightness) {
      LabeledContent("Native brightness") {
        valueText(DiagnosticsCopy.nativeBrightness(
          isAvailable: DisplayServices.isAvailable, app: AppInfo.productName))
      }
    }

    if isBuiltIn {
      SettingsCardDivider()
      SettingRow(DiagnosticsPageCopy.builtInHardwareControl) {
        LabeledContent("Hardware control") {
          valueText(DiagnosticsCopy.builtInHardwareControl)
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
      SettingsCardDivider()
      SettingRow(DiagnosticsPageCopy.gammaConflicts) {
        LabeledContent("Color profile conflicts") {
          valueText(DiagnosticsCopy.gammaConflicts(monitor.interferenceCount(for: state.id)))
        }
      }
      if monitor.suspendedForSession {
        SettingsCaption(DiagnosticsPageCopy.gammaWatchSuspended)
          .padding(.bottom, 6)
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
        valueText(DiagnosticsCopy.capabilityAnswer(
          hasDescription: capabilities != nil,
          parsedACommandList: advertisedCodes != nil,
          wasAsked: wasAsked,
          app: AppInfo.productName
        ))
      }
    }
    .help(DiagnosticsPageCopy.capabilityRequestHelp)

    if let capabilities {
      SettingsCardDivider()
      LabeledContent("MCCS version") {
        valueText(CapabilityString.tag("mccs_ver", in: capabilities)
          ?? DiagnosticsCopy.notStated)
      }
      SettingsCardDivider()
      LabeledContent("Model") {
        valueText(CapabilityString.tag("model", in: capabilities)
          ?? DiagnosticsCopy.notStated)
      }
      SettingsCardDivider()
      LabeledContent("Display type") {
        valueText(CapabilityString.tag("type", in: capabilities)
          ?? DiagnosticsCopy.notStated)
      }

      SettingsCardDivider()
      SettingRow(DiagnosticsPageCopy.advertisedCommands) {
        LabeledContent("Advertised commands") {
          valueText(DiagnosticsCopy.advertisedCommands(
            advertisedCodes, app: AppInfo.productName))
        }
      }

      SettingsCardDivider()
      DisclosureGroup(DiagnosticsPageCopy.rawDescriptionDisclosure) {
        Text(verbatim: capabilities)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(SettingsTheme.bodyColor)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 6)
    }

    SettingsCardDivider()

    SettingRow(DiagnosticsPageCopy.readEvidence(
      readEvidence,
      isSafeMode: model.isSafeMode,
      readsBackAtStartup: prefs.startupAction == .read
    )) {
      LabeledContent("Reading values back") {
        valueText(DiagnosticsCopy.readEvidence(readEvidence, app: AppInfo.productName))
      }
    }

    SettingsCardDivider()

    LabeledContent("Brightness scale") {
      // The brightness controller's OWN evidence, not the folded `readEvidence`:
      // the maximum comes from the brightness read alone, so a volume read that
      // answered must not be allowed to speak for it.
      valueText(DiagnosticsCopy.brightnessScale(
        didReadMax: state.controller.didReadMaxDDC,
        maxValue: state.controller.maxDDCValue,
        evidence: state.controller.readEvidence,
        app: AppInfo.productName
      ))
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
      valueText(DiagnosticsCopy.brightnessAvailability(brightnessPath))
    }

    if !isBuiltIn {
      SettingsCardDivider()
      LabeledContent("Volume") {
        valueText(DiagnosticsCopy.volumeAvailability(
          override: prefs.audioSinkOverride,
          isAvailable: state.volume.isAvailable,
          support: model.volumeSupport[persistenceKey],
          hasDescription: capabilities != nil,
          forceSoftware: prefs.forceSoftware,
          app: AppInfo.productName
        ))
      }
      .help(DiagnosticsPageCopy.volumeHelp)

      SettingsCardDivider()
      LabeledContent("Contrast") {
        valueText(DiagnosticsCopy.contrastAvailability(
          isAvailable: state.contrast.isAvailable, forceSoftware: prefs.forceSoftware))
      }
      .help(DiagnosticsPageCopy.contrastHelp)

      SettingsCardDivider()
      LabeledContent("Mute") {
        valueText(DiagnosticsCopy.muteAvailability(
          muteEnabled: prefs.enableMuteUnmute,
          volumeAvailable: state.volume.isAvailable,
          forceSoftware: prefs.forceSoftware,
          override: prefs.audioSinkOverride,
          muteSupport: model.muteSupport[persistenceKey] ?? .unknown
        ))
      }
      .help(DiagnosticsPageCopy.muteHelp)

      SettingsCardDivider()
      LabeledContent("HDR") {
        valueText(DiagnosticsCopy.hdrAvailability(
          displayServicesAvailable: DisplayServices.isAvailable,
          supportsHDR: state.controller.supportsHDR,
          app: AppInfo.productName
        ))
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
        valueText(DiagnosticsCopy.hdrState(engaged: state.controller.isHDREngaged))
      }

      if state.controller.isHDREngaged, state.controller.hdrMode == .off {
        SettingsCaption(DiagnosticsPageCopy.hdrTurnedOnOutside)
          .padding(.bottom, 6)
      }

      // Trailing rather than leading, so the built-in's card does not open on a
      // hairline: this block is the one that may be missing, not the row below.
      SettingsCardDivider()
    }

    LabeledContent(DiagnosticsPageCopy.writeGateLabel(isBuiltIn: isBuiltIn)) {
      valueText(DiagnosticsCopy.writeGate(
        isSending: model.displayManager.isEpochCurrent(model.displayManager.currentEpoch())))
    }

    if model.isSafeMode {
      SettingsCardDivider()
      SettingRow(caption: SettingsCaption(verbatim: DiagnosticsPageCopy.safeMode)) {
        LabeledContent("Safe Mode") {
          valueText(DiagnosticsCopy.safeModeState)
        }
      }
    }

    SettingsCardDivider()

    // The caption is attached whenever a family is missing, not only when they
    // all are. Partial states are ordinary now that volume and mute arm
    // separately, and a row that names two families out of three explains the
    // absent one to nobody.
    if model.lastArmedTapConfig != nil, !watchesEveryFamily {
      SettingRow(DiagnosticsPageCopy.watchedKeys) {
        LabeledContent("Keys being watched") {
          valueText(watchedKeysText)
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
        valueText(watchedKeysText)
      }
    }

    if model.accessibility.isWarningWarranted {
      SettingsCaption(DiagnosticsPageCopy.accessibilityMissing)
        .padding(.bottom, 6)
    }

    if !isBuiltIn {
      SettingsCardDivider()
      LabeledContent("Sound output") {
        valueText(audioMatchText)
      }
    }

    SettingsCardDivider()

    LabeledContent("Last brightness command") {
      valueText(DiagnosticsCopy.lastWrite(
        target: state.controller.lastAppliedTarget(),
        failed: state.controller.lastApplyFailed()
      ))
    }

    if let report = model.displayModes.report(for: state.id) {
      SettingsCardDivider()
      LabeledContent("Last resolution problem") {
        valueText(DiagnosticsCopy.reapplyProblem(report.notice, app: AppInfo.productName))
      }
      .modifier(ReapplyDiagnostic(notice: report.notice))
    }

    SettingsCardDivider()

    LabeledContent("Mirroring") {
      // SS7: a synthesis set is not user mirroring, and the CG flag says it is.
      // The pairing table is the authority (SS1), so it decides here and the
      // flag answers only when it is not a synthesis set. Without this the row
      // reads "Showing another display's contents" about a display that is
      // showing its own picture at a size this app renders.
      valueText(DiagnosticsCopy.mirroring(
        isMirrorSlave: model.displayModes.catalogs[state.id]?.display.isMirrorSlave,
        isSynthesized: model.synthesis.isEngaged(displayID: state.id)))
    }

    synthesizedActiveRow
  }

  /// The engaged pairing, from the ENGINE's own table (SS1) and never from a CG
  /// mirror flag or a mode readback: the engage tail re-times the slave, so a
  /// synthesis-engaged display reports its own native mode [MEASURED
  /// 2026-08-18]. "Current mode" above reads `Catalog.onScreen` for exactly
  /// that reason, so the two rows name the same size; this one adds the slot,
  /// which is what tells two engaged displays apart in a pasted report.
  ///
  /// Directly under Mirroring, which is where the same set shows up as a
  /// mirror. This line is what says whose mirror it is.
  @ViewBuilder private var synthesizedActiveRow: some View {
    if let pairing = model.synthesis.pairing(forPhysical: state.id) {
      SettingsCardDivider()
      Text(verbatim: SynthesisCopy.diagnosticsActive(
        width: pairing.size.logicalWidth,
        height: pairing.size.logicalHeight,
        slot: pairing.slot
      ))
      .foregroundStyle(SettingsTheme.bodyColor)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 6)
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
    SettingsCardSection {
      SettingRow(DiagnosticsPageCopy.reportScope) {
        DiagnosticsReportActions()
      }

      // A link, not a setting — the page stays read-only in content (spec §7).
      // Offered only where there is something on the other end: the built-in's
      // destination has no Advanced sub-page, because it has no hardware
      // control to method.
      if !isBuiltIn {
        SettingsCardDivider()
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
    Text(verbatim: needs).foregroundStyle(SettingsTheme.bodyColor)
  }
}

/// The Copy/Save pair and the transient confirmation, in one component because
/// they exist in two places: here and in About, which survives every display's
/// departure (spec §7). Two copies of a clipboard write and an `NSSavePanel` is
/// two things to keep in agreement.
@MainActor
struct DiagnosticsReportActions: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var justCopied = false
  /// Cancelled and replaced on every copy, so a second click restarts the two
  /// seconds instead of letting the first click's timer clear the label early.
  @State private var confirmationTask: Task<Void, Never>?
  @State private var saveError: String?

  var body: some View {
    HStack(spacing: 8) {
      // Copy takes the primary: pasting the report into a message is what a
      // person came to this page's foot to do, and saving a file is the
      // fallback for the report too long to paste.
      Button(DiagnosticsPageCopy.copyReport) { copyReport() }
        .buttonStyle(SettingsPrimaryButtonStyle())
        .accessibilityLabel(Text(DiagnosticsPageCopy.copyReport))
      Button(DiagnosticsPageCopy.saveReport) { saveReport() }
        .buttonStyle(SettingsSecondaryButtonStyle())
        .accessibilityLabel(Text(DiagnosticsPageCopy.saveReport))
      if justCopied {
        Text(DiagnosticsPageCopy.copied)
          .foregroundStyle(SettingsTheme.bodyColor)
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
    withAnimation(Motion.notice(reduceMotion: reduceMotion)) { justCopied = true }
    confirmationTask?.cancel()
    confirmationTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) { justCopied = false }
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
