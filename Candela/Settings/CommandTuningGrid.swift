import CandelaKit
import SwiftUI

// No call sites since Task 13 — the hub dropped the Tuning section. Kept
// deliberately: Task 15's Advanced sub-page re-homes this grid (with visible
// column headers as an addition), and its per-control accessibility labels are
// load-bearing.

/// Per-command DDC tuning for one display: Enabled / Min / Max / Invert, for
/// brightness, volume and contrast. D26 shrank the fork's six columns to these
/// four — the 9-step response curve and the hex control-code remap are cut from
/// the UI and remain `defaults write` keys with unchanged engine behavior.
///
/// Every edit is a read-modify-write of ONE command's tuning, and the
/// modify half is `DDCOverrideValidation.applied` in CandelaKit, under test.
/// The fork rewrote all 18 keys and forced brightness to 100% on any single
/// edit (chapter 2 QUIRK 7); here nothing writes brightness at all — the D20
/// seam re-applies the SAME published value through `reapplyAfterPrefChange()`
/// (D4/D28), which is also what makes an override take effect immediately
/// instead of on the user's next slider drag.
///
/// `@MainActor` for the same reason as `DisplayDetailView`: it stores a `@MainActor`
/// `DisplayPrefWriter` and reads it from computed properties that are
/// nonisolated on a plain `View` (lens-1 I3).
@MainActor
struct CommandTuningGrid: View {
  let state: AppModel.DisplayState
  let writer: DisplayPrefWriter

  /// Carries the `DDCCommand` itself, not its raw string: the previous shape
  /// forced a `DDCCommand(rawValue:) ?? .brightness` fallback, so a mis-keyed
  /// focus target would silently write against BRIGHTNESS (lens-4 M7). This is
  /// a compile-time elimination, which is why it needs no test.
  private enum FocusTarget: Hashable {
    case minimum(DDCCommand)
    case maximum(DDCCommand)

    var command: DDCCommand {
      switch self {
      case .minimum(let command), .maximum(let command): command
      }
    }

    var field: DDCOverrideValidation.Field {
      switch self {
      case .minimum: .minimum
      case .maximum: .maximum
      }
    }
  }

  /// Field text is only held locally WHILE FOCUSED; an unfocused field always
  /// renders from the stored pref, so an external write (or the reset button)
  /// shows up immediately instead of leaving stale text behind.
  @State private var drafts: [FocusTarget: String] = [:]
  @FocusState private var focus: FocusTarget?

  private var prefs: DisplayPrefs { writer.prefs }

  /// Why no DDC command is reaching this display, if none is — read from the
  /// ENGINE'S OWN PATH, the same one the Diagnostics section renders.
  ///
  /// It used to be `prefs.forceSoftware`, computed here, which made this the
  /// second and contradicting claim about the control path on a page that
  /// already had one. It was wrong in both directions: it missed live HDR (DDC
  /// is dead outright there, yet the grid presented itself as live), and the
  /// caption below it fired on the brightness command's `unavailableDDC`, so a
  /// display whose Diagnostics row read "Nothing is moving this display's
  /// brightness" was told three sections down that it "dims in software only".
  /// Both now come off `BrightnessPath`, so the page gives one answer.
  ///
  /// Disable, don't hide (panel §5.4). The mute recovery affordance that D29
  /// rule 3 requires for this state lives in
  /// `DisplayDetailView.recoverFromHardwareMute`, above the grid and never
  /// disabled.
  private var trafficBlock: DDCTrafficBlock? {
    DisplayCardPolicy.ddcTrafficBlock(for: state.controller.brightnessPath)
  }

  private var isInert: Bool { trafficBlock != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Command tuning")
        .font(.callout.weight(.semibold))
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          Color.clear.frame(width: 1, height: 1)
          columnHeader("On")
          columnHeader("Min")
          columnHeader("Max")
          columnHeader("Invert")
        }
        ForEach(DDCCommand.allCases, id: \.self) { command in
          GridRow {
            Text(rowLabel(command))
            Toggle("", isOn: enabledBinding(command))
              .labelsHidden()
              .accessibilityLabel(Text("\(rowName(command)) enabled"))
            overrideField(.minimum(command))
            overrideField(.maximum(command))
            Toggle("", isOn: invertBinding(command))
              .labelsHidden()
              .accessibilityLabel(Text("Invert \(rowName(command))"))
          }
        }
      }
      .disabled(isInert)
      captions
    }
    .onChange(of: focus) { previous, current in
      if let previous { commit(previous) }
      if let current { drafts[current] = storedText(current) }
    }
  }

  // MARK: - Cells

  private func columnHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func rowLabel(_ command: DDCCommand) -> LocalizedStringKey {
    switch command {
    case .brightness: "Brightness"
    case .volume: "Volume"
    case .contrast: "Contrast"
    }
  }

  /// The `String` sibling of `rowLabel`. Interpolating a `LocalizedStringKey`
  /// INTO a `LocalizedStringKey` literal has no matching interpolation
  /// overload — the accessibility labels above would not compile (lens-1 M4) —
  /// and the same names are needed mid-sentence in the captions. Never
  /// `DDCCommand.rawValue`: those raws are shipped on-disk schema (D22) that
  /// happens to read as English by coincidence (lens-2 m-2).
  private func rowName(_ command: DDCCommand) -> String {
    switch command {
    case .brightness: "brightness"
    case .volume: "volume"
    case .contrast: "contrast"
    }
  }

  private func overrideField(_ target: FocusTarget) -> some View {
    TextField("", text: Binding(
      get: { focus == target ? (drafts[target] ?? storedText(target)) : storedText(target) },
      set: { drafts[target] = $0 }
    ))
    .focused($focus, equals: target)
    .onSubmit { commit(target) }
    .frame(width: 60)
    .accessibilityLabel(Text(accessibilityLabel(for: target)))
  }

  private func accessibilityLabel(for target: FocusTarget) -> String {
    switch target.field {
    case .minimum: "Minimum value for \(rowName(target.command))"
    case .maximum: "Maximum value for \(rowName(target.command))"
    }
  }

  // MARK: - Bindings

  private func enabledBinding(_ command: DDCCommand) -> Binding<Bool> {
    Binding(
      get: { !prefs.tuning(for: command).unavailableDDC },
      set: { enabled in
        // D29 rule 1, second of the three controls that can make the volume
        // command unavailable: `toggleMute` refuses once `isAvailable` is
        // false, so unmute BEFORE disabling it.
        if command == .volume, !enabled, state.volume.isMuted {
          _ = state.volume.toggleMute()
        }
        var tuning = prefs.tuning(for: command)
        tuning.unavailableDDC = !enabled
        writer.write(.unavailableDDC) { $0.setTuning(tuning, for: command) }
      }
    )
  }

  private func invertBinding(_ command: DDCCommand) -> Binding<Bool> {
    Binding(
      get: { prefs.tuning(for: command).invert },
      set: { invert in
        var tuning = prefs.tuning(for: command)
        tuning.invert = invert
        writer.write(.invertDDC) { $0.setTuning(tuning, for: command) }
      }
    )
  }

  // MARK: - Override commits

  private func storedText(_ target: FocusTarget) -> String {
    let tuning = prefs.tuning(for: target.command)
    return switch target.field {
    case .minimum: DDCOverrideValidation.text(for: tuning.minDDCOverride)
    case .maximum: DDCOverrideValidation.text(for: tuning.maxDDCOverride)
    }
  }

  private func commit(_ target: FocusTarget) {
    let command = target.command
    let current = prefs.tuning(for: command)
    let input = DDCOverrideValidation.classify(drafts[target] ?? storedText(target))
    // ONE command's tuning in, the same tuning with ONE field changed out.
    // `nil` means rejected: snap the field back and write nothing (fork parity
    // for Min, now applied to Max too). Note there is no loop over
    // `DDCCommand.allCases` anywhere in this function — that shape is the
    // fork's QUIRK 7, and `DDCOverrideApplicationTests` is what keeps it out.
    guard let tuning = DDCOverrideValidation.applied(input, to: current, field: target.field),
          // Return then blur commits the same field twice; the second commit
          // has nothing to say, and a re-write would fan out to a pointless
          // `reapplyAfterPrefChange()`. Same rule as
          // `DisplayDetailView.commitName`.
          tuning != current
    else {
      drafts[target] = storedText(target)
      return
    }
    let name: PrefName = target.field == .minimum ? .minDDCOverride : .maxDDCOverride
    writer.write(name) { $0.setTuning(tuning, for: command) }
    drafts[target] = storedText(target)
  }

  // MARK: - Captions

  @ViewBuilder private var captions: some View {
    if let trafficBlock {
      switch trafficBlock {
      // This grid renders only under an EXTERNAL display (`DisplayDetailView`),
      // and `BrightnessPathPolicy.usesNative` has exactly one way to answer yes
      // for an external: HDR is live, whoever engaged it (#52). So the sentence
      // can name HDR rather than shrugging at "macOS is doing it".
      case .macOSDrivesBrightness:
        SettingsCaption("This display is in HDR mode. macOS is setting its brightness directly and no hardware commands are reaching it, so these settings have no effect until HDR turns off.")
      case .hardwareControlOff:
        SettingsCaption("Hardware (DDC) control is off for this display, so these settings have no effect.")
      }
    } else {
      SettingsCaption("Most displays need none of this. Use it when a display bottoms out or tops out early, or runs backwards. Leave a box empty to use the display's own range.")
      brightnessLegCaption
      let ignored = ignoredMaxCommands
      if ignored.count == 1 {
        SettingsCaption("The maximum you set for \(rowName(ignored[0])) is not above its minimum, so \(AppInfo.productName) ignores it and uses the display's own maximum.")
      } else if ignored.count > 1 {
        SettingsCaption("The maximums you set for \(ignoredList(ignored)) are not above their minimums, so \(AppInfo.productName) ignores them and uses the display's own maximums.")
      }
    }
  }

  /// What turning the BRIGHTNESS command off actually did, in the same words
  /// the Diagnostics section uses, because it is derived from the same value.
  ///
  /// The old caption read `tuning(for: .brightness).unavailableDDC` and always
  /// said "dims in software only" — true on one of the two paths that flag can
  /// produce, and flatly contradicted by the Diagnostics row on the other.
  @ViewBuilder private var brightnessLegCaption: some View {
    switch state.controller.brightnessPath {
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      SettingsCaption("With brightness off, this display dims in software only below \(SliderSnap.percentText(dimsBelow)). Above that, nothing moves.")
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      SettingsCaption("With brightness off, nothing is moving this display's brightness.")
    case .native, .software, .hardware, .combined:
      EmptyView()
    }
  }

  /// Commands whose stored max override is silently inert — the rule the fork
  /// never surfaced.
  private var ignoredMaxCommands: [DDCCommand] {
    DDCCommand.allCases.filter { command in
      let tuning = prefs.tuning(for: command)
      return DDCOverrideValidation.warning(
        min: tuning.minDDCOverride, max: tuning.maxDDCOverride
      ) != nil
    }
  }

  private func ignoredList(_ commands: [DDCCommand]) -> String {
    let names = commands.map(rowName)
    guard let last = names.last, names.count > 1 else { return names.joined() }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }
}
