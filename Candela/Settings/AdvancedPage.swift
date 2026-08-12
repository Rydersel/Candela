import CandelaKit
import SwiftUI

/// One external display's Advanced sub-page (spec §6): the settings most
/// displays never need, plus the escape hatches A1 promoted out of
/// `defaults write`.
///
/// Owns its own `Form` for the reason Task 13 measured on the hub — a grouped
/// `Form` only reliably sizes structure declared in its own builder — so the
/// navigation shell hands this view the header's inputs and nothing else.
///
/// `@MainActor` because a `View`'s stored and computed properties other than
/// `body` are nonisolated under complete concurrency, and these read
/// main-actor types (`DisplayPrefWriter`, the display's controllers).
@MainActor
struct AdvancedPage: View {
  let state: AppModel.DisplayState
  /// The sub-page display switcher's menu (SO23) and its callback. Navigation
  /// state belongs to `SettingsRootView`; this page only reports the choice.
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  @State private var confirmingRestore = false

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  /// The two gates this page's sections hang off (`disableCombinedBrightness`,
  /// `startupAction`) are app-level and live in General.
  private var appPrefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  /// The same test `DiagnosticsPage` uses, so the two sub-pages cannot disagree
  /// about which display is the built-in.
  private var isBuiltIn: Bool { model.builtIn?.id == state.id }

  /// SO23's switcher, minus the built-in — this page has no built-in content at
  /// all, so offering it would push someone onto the empty fallback below
  /// rather than onto a comparison. `SubPageHeader` does not filter, and
  /// `switcherDisplays` includes the built-in, so the filter has to happen here.
  ///
  /// The built-in's own entry is kept when it IS the display being shown: a
  /// `Picker` whose selection matches no tag renders blank, and on the fallback
  /// page the switcher is the only way off it.
  private var switcherDisplays: [(key: String, name: String)] {
    guard !isBuiltIn, let builtInKey = model.builtIn?.display.persistenceKey
    else { return displays }
    return displays.filter { $0.key != builtInKey }
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so this is what
    // re-evaluates the page after any write — including the hub's Advanced
    // preview going the other way (SO3).
    let _ = model.prefsRevision
    Form {
      SubPageHeader(
        title: DisplaySubPage.advanced.title,
        currentKey: persistenceKey,
        displays: switcherDisplays,
        onSwitch: onSwitch
      )
      // `BuiltInDisplayPane` never pushes `.advanced`, but the switcher above
      // and the debug sub-page hook can both land here with the built-in
      // selected — and every section below is about a DDC wire the built-in
      // does not have. It used to render them anyway, greyed, under
      // "This display is in HDR mode…", which is a false sentence about a panel
      // that is constitutively native. This guard is what makes the
      // external-only claim in `blockExplanation` true rather than asserted.
      if isBuiltIn {
        Section {
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
    .formStyle(.grouped)
  }

  // MARK: - DDC traffic blocking (SO12)

  /// Why no DDC command is reaching this display, if none is — read from the
  /// ENGINE'S OWN path, so this page cannot disagree with Diagnostics or with
  /// the tuning grid's captions.
  private var trafficBlock: DDCTrafficBlock? {
    DisplayCardPolicy.ddcTrafficBlock(for: state.controller.brightnessPath)
  }

  private var isBlocked: Bool { trafficBlock != nil }

  /// Stated ONCE, at the foot of Control Method: the section above the three the
  /// block greys out (SO12). Both sentences are the two-sentence safety
  /// allowance SO15 grants the HDR block.
  ///
  /// The copy lives on `SafetySentence` because the HDR half is also spoken as
  /// part of the hardware-control toggle's label, which is the one control a
  /// block greys BEFORE a VoiceOver user reaches this caption. The `isBuiltIn`
  /// guard in `body` is what makes `.macOSDrivesBrightness` external-only here,
  /// and `BrightnessPathPolicy.usesNative` has exactly one way to answer yes for
  /// an external: HDR is live, whoever engaged it (#52).
  private func blockExplanation(_ block: DDCTrafficBlock) -> SettingsCaption {
    SettingsCaption(verbatim: SafetySentence.trafficBlockExplanation(block))
  }

  // MARK: - Control Method

  @ViewBuilder private var controlMethodSection: some View {
    Section {
      // A safety row (accessibility contract 3). Under live HDR this toggle is
      // the only control a block greys BEFORE the page's one explanation, which
      // sits at the foot of this section, so a VoiceOver user would otherwise
      // hear "dimmed" with no reason for it. The sentence is spoken as part of
      // the label and is NOT repeated as a caption here: SO12 states it once.
      SettingRow(
        safety: .hdrBlock(trafficBlock),
        label: "Use hardware (DDC) control",
        caption: SettingsCaption("Turn off if hardware control misbehaves; brightness dims in software instead.")
      ) { label in
        Toggle(label, isOn: Binding(
          get: { !prefs.forceSoftware },
          set: { useDDC in
            // D29 rule 1 — the THIRD mute-stranding path, and the only one that
            // was unrecoverable. `isAvailable` is
            // `!tuning.unavailableDDC && !prefs.forceSoftware`, and `toggleMute`
            // guards on it. Turning DDC control off while the display is
            // 0x8D-muted used to make the unmute refuse FOREVER: the key path is
            // gone, the menu bar drops the volume slider, `restoreToHardware` is
            // gated on the same flag, and both UI escape hatches are disabled in
            // exactly that state. Unmute BEFORE persisting the disabling value.
            if !useDDC, state.volume.isMuted {
              _ = state.volume.toggleMute()
            }
            writer.write(.forceSw) { $0.forceSoftware = !useDDC }
          }
        ))
        // SO12 greys the DDC-dependent controls — but this one is gated ONLY by
        // live HDR, never by `.hardwareControlOff`. `.hardwareControlOff` IS
        // this toggle being off (it is the only route to `BrightnessPath`'s
        // `.software`), so disabling it there would be D29 rule 3 exactly: the
        // control that recovers the state, disabled in the state it recovers
        // from, with no other route back inside the app.
        .disabled(trafficBlock == .macOSDrivesBrightness)
      }

      SettingRow("Use if another app keeps taking the color profile back, or on virtual displays.") {
        Toggle("Dim with a screen overlay", isOn: Binding(
          get: { prefs.avoidGamma },
          set: { overlay in
            // D28: the seam's `.reapplyDimming` reaches `reapplyAfterPrefChange()`,
            // which TEARS DOWN the abandoned backend before re-applying. Without
            // that teardown `applySoftware` writes the newly selected backend and
            // leaves the other one engaged — the shade at alpha 1 − 0.8^1.5 on top
            // of a gamma table still at 0.8 — so the display drops to roughly the
            // product of the two and stays there until a topology change.
            writer.write(.avoidGamma) { $0.avoidGamma = overlay }
          }
        ))
      }

      // Candela's OWN volume/mute HUD pills, and volume only — brightness and
      // contrast pills are unaffected, and the monitor's built-in OSD is not
      // ours to suppress, which is why "on-screen display" never appears here.
      SettingRow("Turn off if macOS already shows its own volume indicator for this display.") {
        Toggle("Show the volume indicator", isOn: Binding(
          get: { !prefs.hideOsd },
          set: { shown in writer.write(.hideOsd) { $0.hideOsd = !shown } }
        ))
      }

      if let trafficBlock {
        blockExplanation(trafficBlock)
      }
    } header: {
      Text("Control Method").settingsHeading()
    }
  }

  // MARK: - Command Tuning

  private var commandTuningSection: some View {
    Section {
      CommandTuningGrid(state: state, writer: writer)
      vcpOverrides
    } header: {
      Text("Command Tuning").settingsHeading()
    }
    // SO12: the whole section greys together, and the one explanation for it is
    // rendered above, in Control Method.
    .disabled(isBlocked)
  }

  /// SO13's promoted per-command decisions. A labeled sub-header, deliberately
  /// NOT a `DisclosureGroup`: a disclosure toggles only from its chevron glyph
  /// and never from its label text (measured), so fronting the only route to
  /// these fields with one hides them from most people who look straight at it.
  @ViewBuilder private var vcpOverrides: some View {
    Text("VCP Overrides")
      .font(.callout.weight(.semibold))
      .settingsHeading()
    SettingsCaption("For a display that puts a control somewhere non-standard, or responds unevenly across its range.")
    ForEach(DDCCommand.allCases, id: \.self) { command in
      Picker(
        "\(DDCCommandCopy.title(command)) response curve",
        selection: curveBinding(command)
      ) {
        // The engine's fine 1–9 range stays a `defaults write` key (SO13): only
        // the three decisions a person can make are offered here. 0 (unset) and
        // 5 are both linear in `DimmingMath.curveMultiplier`, so a display
        // carrying the fork's explicit 5 reads as Linear and is NOT rewritten
        // unless the user picks something else.
        Text("Linear").tag(0)
        Text("Favor low brightness").tag(3)
        Text("Favor high brightness").tag(7)
        // A hand-set fine value keeps its own item rather than being silently
        // snapped to one of the three above — the picker would otherwise rewrite
        // a `defaults write` the moment the page rendered.
        if let custom = customCurveIndex(command) {
          Text(verbatim: "Custom (\(custom))").tag(custom)
        }
      }
      // Belt, per control. The Section-level `.disabled` above is the
      // documented spelling, but a modifier on a `Section` inside a grouped
      // `Form` is the construct this repo has measured as unreliable — and the
      // grid beside these fields carries its own belt for the same reason. A
      // promoted control that stayed live under a traffic block would take a
      // write that reaches nothing (SO12).
      .disabled(isBlocked)

      LabeledContent("\(DDCCommandCopy.title(command)) control code") {
        // An empty title + explicit prompt, the audio-name field's shape: a
        // TITLE of "Standard" is treated as a label by the grouped `Form` and
        // rendered wrapped inside the 100 pt frame ("Stan-/dard", combined
        // pass D6); a PROMPT lays out as single-line placeholder text. The
        // border matches the tuning grid's fields one section up, and so does
        // the commit: leaving the box applies the code (#144).
        CommitOnBlurField(
          stored: { storedRemapText(command) },
          commit: { commitRemap(command, $0) },
          prompt: Text("Standard"),
          // Not a `SettingRow` caption: the sub-group's one caption covers all
          // six controls, and repeating it under three fields would read as
          // three separate settings.
          fieldHint: Text("Hex control codes this display uses instead of the standard one."),
          width: 100
        )
        // Keyed to the display, for the reason the tuning grid's fields are:
        // SO23's switcher can carry this page onto another display mid-edit.
        .id(persistenceKey)
        .disabled(isBlocked)
      }
    }
  }

  // MARK: - Combined Dimming

  /// SO12, as amended by the controller 2026-08-06: this section greys WITH the
  /// other three, and there is no carve-out why-line.
  ///
  /// The spec's original carve-out ("combined dimming works in software, so it
  /// stays available") rested on a premise that is false in both blocked
  /// states. `.hardwareControlOff` routes `BrightnessPath.software`, which
  /// covers the whole range and never consults the switching point at all;
  /// `.macOSDrivesBrightness` routes `.native`, which does no software dimming
  /// whatsoever. The handoff point is reachable only from `.combined` and
  /// `.softwareOnly`, and a traffic block excludes both — so a live control
  /// here would be the "looks functional while `ddcTrafficBlock` voids it" case
  /// SO12 exists to forbid, wearing SO12's own exemption.
  @ViewBuilder private var combinedDimmingSection: some View {
    Section {
      if appPrefs.combinedBrightness {
        SettingRow("Where dimming hands off from the display's hardware to software.") {
          VStack(alignment: .leading, spacing: 6) {
            Slider(
              value: crossoverBinding,
              in: crossoverRange,
              step: 1,
              label: { Text("Hand off") },
              minimumValueLabel: { Text("Earlier") },
              maximumValueLabel: { Text("Later") }
            )
            // SO13: the stored −8…+7 never renders, in the readout OR to
            // VoiceOver, which would otherwise announce the raw position.
            .accessibilityValue(Text(verbatim: crossoverDescription))
            HStack {
              Text(verbatim: crossoverDescription)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Reset") {
                writer.write(.combinedSwitchingPoint) { $0.combinedSwitchingPoint = 0 }
              }
              .disabled(prefs.combinedSwitchingPoint == 0 || isBlocked)
            }
          }
          .disabled(isBlocked) // belt, as on the VCP fields
        }
      } else {
        // SO11: the effective state read-only, with an inline enabler that does
        // the write here — never a disabled control whose enabler lives on
        // another page.
        LabeledContent("Combined dimming", value: "Off")
        SettingRow("A global setting: applies to every display.") {
          Button("Turn On Dim Past the Display's Minimum") {
            // No persistence key: `.disableCombinedBrightness` carries
            // `.reapplyDimming`, and the seam scopes that by key — passing this
            // display's key (or "app", which matches no display at all) would
            // skip the re-apply on every other display the global pref just
            // changed. General's own toggle passes nil for the same reason.
            appPrefs.combinedBrightness = true
            actions.prefDidChange(.disableCombinedBrightness)
          }
          .disabled(isBlocked)
        }
      }
    } header: {
      Text("Combined Dimming").settingsHeading()
    }
    .disabled(isBlocked)
  }

  /// The engine's own range, never a literal pair — `DisplayPrefs` clamps
  /// writes to it, so a slider with wider bounds would offer positions that
  /// silently snap back.
  private var crossoverRange: ClosedRange<Double> {
    Double(DimmingMath.switchingPointRange.lowerBound)
      ... Double(DimmingMath.switchingPointRange.upperBound)
  }

  /// Written straight through rather than through a drag draft: `step: 1`
  /// means the slider emits at most 16 distinct values across a full sweep, and
  /// the guard drops the repeats, so the D28 re-apply runs once per detent and
  /// the change is visible while the handle is still under the pointer. A draft
  /// committed on `onEditingChanged` would leave the pref and the handle
  /// disagreeing for any adjustment that does not report an editing session
  /// (keyboard and VoiceOver among them).
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

  /// The handoff position in words. "Default" at the centre, and a direction
  /// with a distance either side — never the stored number (SO13).
  private var crossoverDescription: String {
    let point = prefs.combinedSwitchingPoint
    if point == 0 { return "Default" }
    return point < 0 ? "Earlier by \(-point)" : "Later by \(point)"
  }

  // MARK: - Reading Values From the Display

  @ViewBuilder private var readingValuesSection: some View {
    Section {
      if readbackNeverAnswered {
        // SO25: state the verdict rather than offering escalation. Retrying a
        // panel that has already proved it never answers is not a decision
        // worth presenting as one.
        SettingsCaption(verbatim: "This display has never answered a read. Values are tracked as last written.")
      } else if appPrefs.startupAction == .read {
        SettingRow("How many times to ask before giving up.") {
          Picker("Retries", selection: Binding(
            get: { prefs.pollingMode },
            set: { mode in writer.write(.pollingMode) { $0.pollingMode = mode } }
          )) {
            Text("None").tag(PollingMode.none)
            Text("Minimal").tag(PollingMode.minimal)
            Text("Normal").tag(PollingMode.normal)
            Text("Heavy").tag(PollingMode.heavy)
            Text("Custom").tag(PollingMode.custom)
          }
          // Belt, per control — same reason as the VCP fields above.
          .disabled(isBlocked)
        }
        // D11: safe mode suppresses the startup readback outright, so a retry
        // policy shown as live here would describe behavior that is not
        // happening — the same defect the General pane's notice exists to
        // avoid. `appPrefs` is built without the safe-mode flag deliberately:
        // the picker shows the PERSISTED choice, which is right for a setting.
        if model.isSafeMode {
          SettingsCaption("Safe Mode is on for this session, so nothing is read from the display at startup.")
        }
        if prefs.pollingMode == .custom {
          Stepper(value: Binding(
            get: { prefs.pollingCount },
            set: { count in writer.write(.pollingCount) { $0.pollingCount = count } }
          ), in: 0...99) {
            Text(verbatim: "Attempts: \(prefs.pollingCount)")
          }
          .disabled(isBlocked)
        }
      } else {
        // SO11 again — the same shape as Combined Dimming above.
        LabeledContent("Startup readback", value: "Off")
        SettingRow("A global setting: applies to every display.") {
          Button("Ask the Display at Startup") {
            appPrefs.startupAction = .read
            actions.prefDidChange(.startupAction)
          }
          .disabled(isBlocked)
        }
      }
    } header: {
      Text("Reading Values From the Display").settingsHeading()
    }
    .disabled(isBlocked)
  }

  /// Deliberately NOT `DDCReadEvidence.worst(...)`, which the hub's chevron
  /// preview uses. Worst-wins is right for a one-word verdict, but the sentence
  /// this gates says "has NEVER answered a read" — and a display whose
  /// brightness answered while its volume came back all zeros folds to
  /// `.allZeros`, which would make that sentence false. So an `.answered`
  /// anywhere disqualifies it, and the exhaustive switch keeps a future
  /// evidence case from defaulting into either branch.
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
    Section {
      // Plain at rest (SO20); the destructive role lives on the alert.
      // Never disabled by `isBlocked`: under `.hardwareControlOff` this button
      // is the scoped way back out (D29 rule 3).
      Button("Restore Advanced Defaults…") { confirmingRestore = true }
        .alert("Restore this display's advanced settings?", isPresented: $confirmingRestore) {
          Button("Restore", role: .destructive) { restoreAdvancedDefaults() }
          Button("Cancel", role: .cancel) {}
        } message: {
          // SO20: names the scope in plain terms, including the unmute.
          Text("This turns hardware control and the volume indicator back on for \(state.display.name), switches software dimming back from a screen overlay to the color profile, clears its command tuning, control codes and response curves, and returns the dimming handoff and readback retries to their defaults. A display left muted in hardware is unmuted too, unless it is in HDR mode. Nothing else about this display changes.")
        }
    }
  }

  /// Scoped repair, proportional to this page (SO20) — every pref this page can
  /// write and nothing else. `enableMuteUnmute` is deliberately untouched: it
  /// lives on the hub, and the display was muted under whatever strategy is in
  /// force, which has to STILL be in force for the unmute below to send the
  /// right wire value.
  ///
  /// ORDER (D29 rule 2): the availability prefs are cleared FIRST, in the batch,
  /// and the unmute comes SECOND. The other order is a silent no-op —
  /// `toggleMute` returns unchanged while `isAvailable` is false, and the user
  /// is left believing they unmuted.
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
    // `brightnessPath` re-reads prefs, so by here the only block left is live
    // HDR — and under HDR the monitor locks its DDC registers. An unmute there
    // would report success, change nothing, and clear the persisted `muted`
    // flag, which ALSO retires the hub's stranded-mute recovery block. That is
    // the "reported a success that was not achieved" class again; leaving the
    // display honestly muted keeps the recovery reachable.
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

  /// Rendered from the PARSED codes, never from the raw string on disk: the
  /// engine drops empty, zero and non-hex tokens (`DisplayPrefs.parseRemapCodes`),
  /// so this is what actually survived — which is the field's whole contract.
  private func storedRemapText(_ command: DDCCommand) -> String {
    prefs.tuning(for: command).remapCodes
      .map { String(format: "%02x", $0) }
      .joined(separator: ", ")
  }

  /// Return and focus loss both arrive here, so the two routes cannot come to
  /// different conclusions about the same typed text (#144). Codes that parse
  /// to what is already stored write nothing: a re-write would fan out to a
  /// pointless `reapplyAfterPrefChange()`. Same rule as the tuning grid's
  /// override commits and the hub's name commit.
  private func commitRemap(_ command: DDCCommand, _ text: String) {
    var tuning = prefs.tuning(for: command)
    let codes = DisplayPrefs.parseRemapCodes(text)
    guard codes != tuning.remapCodes else { return }
    tuning.remapCodes = codes
    writer.write(.remapDDC) { $0.setTuning(tuning, for: command) }
  }
}
