import CandelaKit
import SwiftUI

/// One external display's Advanced sub-page (spec §6): the settings most
/// displays never need, plus the escape hatches promoted out of
/// `defaults write`.
///
/// `@MainActor` because a `View`'s properties other than `body` are nonisolated
/// under complete concurrency, and these read main-actor types
/// (`DisplayPrefWriter`, the display's controllers).
@MainActor
struct AdvancedPage: View {
  let state: AppModel.DisplayState
  /// The sub-page display switcher's menu and its callback. Navigation
  /// state belongs to `SettingsRootView`; this page only reports the choice.
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var confirmingRestore = false

  /// The traffic block as the caption renders it, one update behind
  /// `trafficBlock`: the engine changes the block outside any transaction, so
  /// this mirror is what animates the explanation in and out. Only the caption
  /// reads it, so the greying stays instant.
  @State private var shownTrafficBlock: DDCTrafficBlock?

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  /// The gates this page's sections hang off (`disableCombinedBrightness`,
  /// `startupAction`) are app-level; the startup control lives on the
  /// Protection pane.
  private var appPrefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  /// The same test `DiagnosticsPage` uses, so the two sub-pages cannot disagree
  /// about which display is the built-in.
  private var isBuiltIn: Bool { model.builtIn?.id == state.id }

  /// The sub-page switcher, minus the built-in: this page has no built-in content,
  /// and `SubPageHeader` does not filter, so the filter happens here.
  ///
  /// The built-in's own entry stays when it IS the display being shown. A
  /// `Picker` whose selection matches no tag renders blank, and on the fallback
  /// page the switcher is the only way off it.
  private var switcherDisplays: [(key: String, name: String)] {
    guard !isBuiltIn, let builtInKey = model.builtIn?.display.persistenceKey
    else { return displays }
    return displays.filter { $0.key != builtInKey }
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so this is what
    // re-evaluates the page after any write.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SubPageHeader(
        title: DisplaySubPage.advanced.title,
        currentKey: persistenceKey,
        displays: switcherDisplays,
        onSwitch: onSwitch
      )
      // The switcher above and the debug sub-page hook can both land here with
      // the built-in selected, and every section below is about a DDC wire it
      // does not have. This guard is what makes `blockExplanation`'s
      // external-only claim true rather than asserted.
      if isBuiltIn {
        SettingsCardSection {
          SettingsCaption("This display has no hardware-control settings.")
        }
      } else {
        controlMethodSection
        commandTuningSection
        combinedDimmingSection
        readingValuesSection
        restoreSection
      }
    }
  }

  // MARK: - DDC traffic blocking

  /// Why no DDC command is reaching this display, if none is. Read from the
  /// engine's own path, so this page cannot disagree with Diagnostics or with
  /// the tuning grid's captions.
  private var trafficBlock: DDCTrafficBlock? {
    DisplayCardPolicy.ddcTrafficBlock(
      for: state.controller.brightnessPath,
      isWireUnresponsive: state.controller.isWireUnresponsive
    )
  }

  private var isBlocked: Bool { trafficBlock != nil }

  /// Stated ONCE, at the foot of Control Method, above the sections the block
  /// greys out. The copy lives on `SafetySentence` because the HDR half
  /// is also spoken in the hardware-control toggle's label, the one control a
  /// block greys BEFORE a VoiceOver user reaches this caption.
  ///
  /// `BrightnessPathPolicy.usesNative` has exactly one way to answer yes for an
  /// external: HDR is live, whoever engaged it.
  private func blockExplanation(_ block: DDCTrafficBlock) -> SettingsCaption {
    SettingsCaption(verbatim: SafetySentence.trafficBlockExplanation(block))
  }

  // MARK: - Control Method

  @ViewBuilder private var controlMethodSection: some View {
    SettingsCardSection(title: "Control Method") {
      // A safety row (accessibility contract 3): under live HDR this toggle
      // greys BEFORE the explanation at the foot of the section, so a VoiceOver
      // user would otherwise hear "dimmed" with no reason. The sentence rides in
      // the label and is never repeated as a caption; the block explanation
      // states it once.
      SettingRow(
        safety: .hdrBlock(trafficBlock),
        label: "Use hardware (DDC) control",
        caption: SettingsCaption("Turn off if hardware control misbehaves; brightness dims in software instead.")
      ) { label in
        Toggle(label, isOn: Binding(
          get: { !prefs.forceSoftware },
          set: { useDDC in
            // Unmute BEFORE persisting the disabling value.
            // `toggleMute` guards on `isAvailable`, which `forceSoftware`
            // clears, so turning DDC control off on a 0x8D-muted display strands
            // it muted with no route back from inside the app.
            if !useDDC, state.volume.isMuted {
              _ = state.volume.toggleMute()
            }
            writer.write(.forceSw) { $0.forceSoftware = !useDDC }
          }
        ))
        // Gated ONLY by live HDR, never by `.hardwareControlOff`, which IS this
        // toggle being off. Greying it there would be exactly the forbidden shape: the
        // recovery control disabled in the state it recovers from, with no other
        // route back inside the app.
        .themedSwitch()
        .disabled(trafficBlock == .macOSDrivesBrightness)
        .prefIdentifier(.forceSw, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      SettingRow("Use if another app keeps taking the color profile back, or on virtual displays.") {
        Toggle("Dim with a screen overlay", isOn: Binding(
          get: { prefs.avoidGamma },
          set: { overlay in
            // `.reapplyDimming` reaches `reapplyAfterPrefChange()`, which
            // TEARS DOWN the abandoned backend before re-applying. Without that,
            // the shade and the gamma table both stay engaged and the display
            // sits at roughly their product until a topology change.
            writer.write(.avoidGamma) { $0.avoidGamma = overlay }
          }
        ))
        .themedSwitch()
        .prefIdentifier(.avoidGamma, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      // Candela's OWN volume/mute HUD pills only. The monitor's built-in OSD is
      // not ours to suppress, so "on-screen display" never appears here.
      SettingRow("Turn off if macOS already shows its own volume indicator for this display.") {
        Toggle("Show the volume indicator", isOn: Binding(
          get: { !prefs.hideOsd },
          set: { shown in writer.write(.hideOsd) { $0.hideOsd = !shown } }
        ))
        .themedSwitch()
        .prefIdentifier(.hideOsd, persistenceKey: persistenceKey)
      }
      // The hooks hang on the row above, which always renders: on the caption
      // they would exist only while it does, so nothing would watch for it to
      // arrive. Un-animated on appear, or opening the page under live HDR would
      // fade the explanation in as though HDR had just engaged.
      .onAppear { shownTrafficBlock = trafficBlock }
      .onChange(of: trafficBlock) { _, block in
        withAnimation(Motion.notice(reduceMotion: reduceMotion)) { shownTrafficBlock = block }
      }

      if let shownTrafficBlock {
        // A `Group`'s modifier reaches each child, so the hairline and the
        // sentence arrive and leave together, never as the card's first row.
        Group {
          SettingsCardDivider()
            .padding(.top, 6)
          blockExplanation(shownTrafficBlock)
            .padding(.top, 6)
        }
        .transition(.opacity)
      }
    }
  }

  // MARK: - Command Tuning

  private var commandTuningSection: some View {
    SettingsCardSection(title: "Command Tuning") {
      CommandTuningGrid(state: state, writer: writer)
      SettingsCardDivider()
        .padding(.vertical, 6)
      vcpOverrides
    }
    // The whole section greys together, and the one explanation for it is
    // rendered above, in Control Method.
    .disabled(isBlocked)
  }

  /// The promoted per-command decisions. NOT a `DisclosureGroup`: a
  /// disclosure toggles from its chevron glyph and never from its label text
  /// (measured), so it would hide these fields from most people who look at it.
  @ViewBuilder private var vcpOverrides: some View {
    Text("VCP Overrides")
      .font(.callout.weight(.semibold))
      // Off the environment rather than `isBlocked`, so the sub-header cannot
      // disagree with what greyed the section.
      .settingsText(SettingsTheme.titleColor)
      .settingsHeading()
    SettingsCaption("For a display that puts a control somewhere non-standard, or responds unevenly across its range.")
      .padding(.top, 2)
    ForEach(DDCCommand.allCases, id: \.self) { command in
      // One hairline per command, so the curve and the control code below it
      // read as that command's pair rather than as loose rows.
      SettingsCardDivider()
        .padding(.vertical, 8)
      ThemedChoiceRow(
        label: "\(DDCCommandCopy.title(command)) response curve",
        selection: curveBinding(command)
      ) {
        // The engine's fine 1–9 range stays a `defaults write` key. 0
        // (unset) and 5 are both linear in `DimmingMath.curveMultiplier`, so a
        // display carrying the fork's explicit 5 reads as Linear and is NOT
        // rewritten unless the user picks something else.
        Text("Linear").tag(0)
        Text("Favor low brightness").tag(3)
        Text("Favor high brightness").tag(7)
        // A hand-set fine value keeps its own item; snapping it to a listed one
        // would rewrite a `defaults write` the moment the page rendered.
        if let custom = customCurveIndex(command) {
          Text(verbatim: "Custom (\(custom))").tag(custom)
        }
      }
      // Belt, per control: one left live under a traffic block would take a
      // write that reaches nothing.
      .disabled(isBlocked)
      .prefIdentifier(.curveDDC, command: command, persistenceKey: persistenceKey)

      LabeledContent("\(DDCCommandCopy.title(command)) control code") {
        // Empty title plus explicit prompt: a TITLE of "Standard" wrapped
        // inside the 100 pt frame ("Stan-/dard"), a PROMPT lays out single-line.
        // Leaving the box applies the code, like the tuning grid's fields.
        CommitOnBlurField(
          stored: { storedRemapText(command) },
          commit: { commitRemap(command, $0) },
          prompt: Text("Standard"),
          // Not a `SettingRow` caption: the sub-group's one caption covers
          // every control, and repeating it per field would read as separate
          // settings.
          fieldHint: Text("Hex control codes this display uses instead of the standard one."),
          width: 100
        )
        .settingsEditableContent()
        // Keyed to the display, for the reason the tuning grid's fields are:
        // the switcher can carry this page onto another display mid-edit.
        .id(persistenceKey)
        .disabled(isBlocked)
        .prefIdentifier(.remapDDC, command: command, persistenceKey: persistenceKey)
      }
    }
  }

  // MARK: - Combined Dimming

  /// The per-display handoff point greys with the other sections: it is
  /// reachable only from `.combined` and `.softwareOnly`, and both blocked
  /// states route elsewhere (`.hardwareControlOff` to `.software`,
  /// `.macOSDrivesBrightness` to `.native`), so a live control there would be
  /// the "looks functional while `ddcTrafficBlock` voids it" case the greying
  /// rule forbids.
  ///
  /// The enabler in the other branch does NOT grey. It writes an app-level
  /// pref that applies to every display, and one display's blocked wire is no
  /// reason to withhold a global switch.
  @ViewBuilder private var combinedDimmingSection: some View {
    SettingsCardSection(title: "Combined Dimming") {
      if appPrefs.combinedBrightness {
        SettingRow("Where dimming hands off from the display's hardware to software.") {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
              // `ThemedSlider` carries no value labels, so the ends are
              // composed beside it. They name a DIRECTION, never a number.
              Text("Earlier")
                .settingsText(SettingsTheme.faintColor)
                .accessibilityHidden(true)
              ThemedSlider(
                value: crossoverBinding,
                range: crossoverRange,
                // The engine's integer detents, which is also the grid a
                // keyboard or VoiceOver step lands on.
                step: 1,
                // The stored integer never renders, in the readout OR to
                // VoiceOver, which would otherwise announce the raw position.
                accessibilityValueText: crossoverDescription
              )
              .accessibilityLabel(Text("Hand off"))
              .prefIdentifier(.combinedSwitchingPoint, persistenceKey: persistenceKey)
              Text("Later")
                .settingsText(SettingsTheme.faintColor)
                .accessibilityHidden(true)
            }
            HStack {
              Text(verbatim: crossoverDescription)
                .settingsText(SettingsTheme.bodyColor)
              Spacer()
              Button("Reset") {
                writer.write(.combinedSwitchingPoint) { $0.combinedSwitchingPoint = 0 }
              }
              .buttonStyle(SettingsSecondaryButtonStyle())
              .accessibilityLabel("Reset")
              .accessibilityIdentifier("action.resetCrossover.\(persistenceKey)")
              .disabled(prefs.combinedSwitchingPoint == 0 || isBlocked)
            }
          }
          .disabled(isBlocked) // belt, as on the VCP fields
        }
      } else {
        // The effective state read-only, with an inline enabler here,
        // never a disabled control whose enabler lives on another page.
        LabeledContent("Combined dimming", value: "Off")
        SettingsCardDivider()
        SettingRow("A global setting: applies to every display.") {
          Button("Turn On Dim Past the Display's Minimum") {
            // No persistence key: `.disableCombinedBrightness` carries
            // `.reapplyDimming` and the seam scopes that by key, so passing one
            // would skip the re-apply on every other display this global pref
            // just changed.
            appPrefs.combinedBrightness = true
            actions.prefDidChange(.disableCombinedBrightness)
          }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel("Turn On Dim Past the Display's Minimum")
          .prefIdentifier(.disableCombinedBrightness)
        }
      }
    }
    // The handoff branch only. The enabler branch stays live under a block.
    .disabled(isBlocked && appPrefs.combinedBrightness)
  }

  /// The engine's own range, never a literal pair: `DisplayPrefs` clamps writes
  /// to it, so wider bounds would offer positions that silently snap back.
  private var crossoverRange: ClosedRange<Double> {
    Double(DimmingMath.switchingPointRange.lowerBound)
      ... Double(DimmingMath.switchingPointRange.upperBound)
  }

  /// Written straight through, no drag draft: `step: 1` plus the repeat guard
  /// runs the `reapplyAfterPrefChange()` pass once per detent, while the handle is still under the
  /// pointer. A draft committed on `onEditingChanged` would leave the pref and
  /// the handle disagreeing for keyboard and VoiceOver adjustments, which report
  /// no editing session.
  private var crossoverBinding: Binding<Double> {
    Binding(
      get: { Double(prefs.combinedSwitchingPoint) },
      set: { raw in
        let point = Int(raw.rounded())
        guard point != prefs.combinedSwitchingPoint else { return }
        writer.write(.combinedSwitchingPoint) { $0.combinedSwitchingPoint = point }
      }
    )
  }

  /// The handoff position in words: "Default" at the centre, a direction and a
  /// distance either side, never the stored number.
  private var crossoverDescription: String {
    let point = prefs.combinedSwitchingPoint
    if point == 0 { return "Default" }
    return point < 0 ? "Earlier by \(-point)" : "Later by \(point)"
  }

  // MARK: - Reading Values From the Display

  @ViewBuilder private var readingValuesSection: some View {
    SettingsCardSection(title: "Reading Values From the Display") {
      if readbackNeverAnswered {
        // State the verdict, don't offer escalation. Retrying a panel
        // that has proved it never answers is not a decision worth presenting.
        SettingsCaption(verbatim: "This display has never answered a read. Values are tracked as last written.")
      } else if appPrefs.startupAction == .read {
        SettingRow("How many times to ask before giving up.") {
          ThemedChoiceRow(label: "Retries", selection: Binding(
            get: { prefs.pollingMode },
            set: { mode in writer.write(.pollingMode) { $0.pollingMode = mode } }
          )) {
            Text("None").tag(PollingMode.none)
            Text("Minimal").tag(PollingMode.minimal)
            Text("Normal").tag(PollingMode.normal)
            Text("Heavy").tag(PollingMode.heavy)
            Text("Custom").tag(PollingMode.custom)
          }
          // Belt, per control, same reason as the VCP fields above.
          .disabled(isBlocked)
          .prefIdentifier(.pollingMode, persistenceKey: persistenceKey)
        }
        // Safe mode suppresses the startup readback, so a retry policy
        // shown as live would describe behavior that is not happening.
        // `appPrefs` ignores the safe-mode flag on purpose: the picker shows the
        // PERSISTED choice, which is right for a setting.
        if model.isSafeMode {
          SettingsCaption("Safe Mode is on for this session, so nothing is read from the display at startup.")
        }
        if prefs.pollingMode == .custom {
          // Never the card's first row: the retries row above it always renders
          // in this branch.
          SettingsCardDivider()
          Stepper(value: Binding(
            get: { prefs.pollingCount },
            set: { count in writer.write(.pollingCount) { $0.pollingCount = count } }
          ), in: 0...99) {
            Text(verbatim: "Attempts: \(prefs.pollingCount)")
              .foregroundStyle(SettingsTheme.titleColor)
          }
          .padding(.vertical, 6)
          .disabled(isBlocked)
          .prefIdentifier(.pollingCount, persistenceKey: persistenceKey)
        }
      } else {
        // The same read-only-with-an-inline-enabler shape as Combined Dimming
        // above, and ungreyed for the same reason: `startupAction` is app-level,
        // so this display's blocked wire is no reason to withhold it.
        LabeledContent("Startup readback", value: "Off")
        SettingsCardDivider()
        SettingRow("A global setting: applies to every display.") {
          Button("Ask the Display at Startup") {
            appPrefs.startupAction = .read
            actions.prefDidChange(.startupAction)
          }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel("Ask the Display at Startup")
          .prefIdentifier(.startupAction)
        }
      }
    }
    // The retries branch only. The enabler branch stays live under a block, and
    // so does the never-answered verdict: greying a statement of fact says the
    // fact is unavailable rather than that a control is.
    .disabled(isBlocked && !readbackNeverAnswered && appPrefs.startupAction == .read)
  }

  /// NOT `DDCReadEvidence.worst(...)`: worst-wins folds a display whose
  /// brightness answered but whose volume came back all zeros to `.allZeros`,
  /// which would make "has never answered a read" false. One `.answered`
  /// anywhere disqualifies it.
  private var readbackNeverAnswered: Bool {
    let evidence = [
      state.controller.readEvidence,
      state.volume.readEvidence,
      state.contrast.readEvidence,
    ]
    guard !evidence.contains(.answered) else { return false }
    return evidence.contains { proves in
      switch proves {
      case .allZeros, .noReply: true
      case .notAttempted, .answered: false
      }
    }
  }

  // MARK: - Restore

  private var restoreSection: some View {
    SettingsCardSection {
      // The destructive ROLE stays on the alert's confirm button, not on the
      // button that only opens the alert. The style reads `isEnabled` itself.
      // Never disabled by `isBlocked`: under `.hardwareControlOff` this button
      // is the scoped way back out.
      Button("Restore Advanced Defaults…") { confirmingRestore = true }
        .buttonStyle(SettingsDangerButtonStyle())
        .accessibilityLabel("Restore Advanced Defaults…")
        .accessibilityIdentifier("action.restoreAdvanced.\(persistenceKey)")
        .alert("Restore this display's advanced settings?", isPresented: $confirmingRestore) {
          Button("Restore", role: .destructive) { restoreAdvancedDefaults() }
          // Cancel takes Return: without the explicit shortcut the destructive
          // button holds the primary role.
          Button("Cancel", role: .cancel) {}
            .keyboardShortcut(.defaultAction)
        } message: {
          // Names the scope in plain terms, including the unmute.
          Text("This turns hardware control and the volume indicator back on for \(state.display.name), switches software dimming back from a screen overlay to the color profile, clears its command tuning, control codes and response curves, and returns the dimming handoff and readback retries to their defaults. A display left muted in hardware is unmuted too, unless it is in HDR mode. Nothing else about this display changes.")
        }
    }
  }

  /// Scoped repair: every pref this page can write and nothing else.
  /// `enableMuteUnmute` stays untouched, because the strategy the display was
  /// muted under has to STILL be in force for the unmute to send the right value.
  ///
  /// ORDER: clear the availability prefs FIRST, in the batch, and
  /// unmute SECOND. The other order is a silent no-op: `toggleMute` returns
  /// unchanged while `isAvailable` is false, and the user believes they unmuted.
  private func restoreAdvancedDefaults() {
    writer.writeAll([
      .forceSw, .avoidGamma, .hideOsd, .combinedSwitchingPoint,
      .pollingMode, .pollingCount,
      .unavailableDDC, .minDDCOverride, .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC,
    ]) { prefs in
      prefs.forceSoftware = false
      prefs.avoidGamma = false
      prefs.hideOsd = false
      prefs.combinedSwitchingPoint = 0
      prefs.pollingMode = .normal
      prefs.pollingCount = 0
      // ONE shared definition of "untouched", from CandelaKit, pinned by
      // `theFactoryTuningIsWhatAnUntouchedDisplayReports`.
      for command in DDCCommand.allCases {
        prefs.setTuning(.unset, for: command)
      }
    }
    // By here the only block left is live HDR, where the monitor locks its DDC
    // registers. An unmute would report success, change nothing, clear the
    // persisted `muted` flag and so retire the hub's stranded-mute recovery.
    // Leaving the display honestly muted keeps that recovery reachable.
    if state.volume.isMuted, trafficBlock != .macOSDrivesBrightness {
      _ = state.volume.toggleMute()
    }
    // The control-code boxes empty themselves: each one watches the text its
    // stored codes render to, and the batch above just cleared them.
  }

  // MARK: - Response curve

  private func curveBinding(_ command: DDCCommand) -> Binding<Int> {
    Binding(
      get: { displayedCurveIndex(command) },
      set: { index in
        var tuning = prefs.tuning(for: command)
        guard tuning.curveIndex != index else { return }
        tuning.curveIndex = index
        writer.write(.curveDDC) { $0.setTuning(tuning, for: command) }
      }
    )
  }

  /// The stored index, with the fork's explicit linear (5) folded onto unset (0)
  /// so the picker has a selection to match. Folding in the GETTER means nothing
  /// is written until the user chooses.
  private func displayedCurveIndex(_ command: DDCCommand) -> Int {
    let stored = prefs.tuning(for: command).curveIndex
    return stored == 5 ? 0 : stored
  }

  /// The extra menu item a hand-set fine value needs, or nil when the stored
  /// value is one the picker already offers.
  private func customCurveIndex(_ command: DDCCommand) -> Int? {
    let displayed = displayedCurveIndex(command)
    return [0, 3, 7].contains(displayed) ? nil : displayed
  }

  // MARK: - Control-code remap

  /// Rendered from the PARSED codes, never the raw string on disk:
  /// `DisplayPrefs.parseRemapCodes` drops empty, zero and non-hex tokens, so the
  /// field shows what actually survived.
  private func storedRemapText(_ command: DDCCommand) -> String {
    prefs.tuning(for: command).remapCodes
      .map { String(format: "%02x", $0) }
      .joined(separator: ", ")
  }

  /// Return and focus loss both arrive here, so the two routes cannot disagree
  /// about the same typed text. Codes that parse to what is already stored write
  /// nothing; a re-write would fan out to a pointless `reapplyAfterPrefChange()`.
  private func commitRemap(_ command: DDCCommand, _ text: String) {
    var tuning = prefs.tuning(for: command)
    let codes = DisplayPrefs.parseRemapCodes(text)
    guard codes != tuning.remapCodes else { return }
    tuning.remapCodes = codes
    writer.write(.remapDDC) { $0.setTuning(tuning, for: command) }
  }
}
