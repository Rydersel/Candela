import CandelaKit
import SwiftUI

/// Display names for the three DDC commands, in ONE place: the grid's row
/// labels, its accessibility labels and the Advanced page's VCP Overrides group
/// all name the same three things.
///
/// Never `DDCCommand.rawValue` — those raws are shipped on-disk schema (D22)
/// that happens to read as English by coincidence (lens-2 m-2).
enum DDCCommandCopy {
  /// Mid-sentence form, for accessibility labels and captions.
  static func name(_ command: DDCCommand) -> String {
    switch command {
    case .brightness: "brightness"
    case .volume: "volume"
    case .contrast: "contrast"
    }
  }

  /// Phrase-initial form, for a row label or a control label.
  static func title(_ command: DDCCommand) -> String {
    switch command {
    case .brightness: "Brightness"
    case .volume: "Volume"
    case .contrast: "Contrast"
    }
  }
}

/// Per-command DDC tuning for one display: Enabled / Min / Max / Invert, for
/// brightness, volume and contrast. D26 shrank the fork's six columns to these
/// four; A1 then promoted the response curve and the hex control-code remap
/// into the Advanced page's VCP Overrides sub-group, which renders directly
/// below this grid in the same section.
///
/// Rendered inside `AdvancedPage`'s Command Tuning section, which owns the
/// section header and the SO12 traffic-block explanation — so neither is drawn
/// here.
///
/// Every edit is a read-modify-write of ONE command's tuning, and the
/// modify half is `DDCOverrideValidation.committed` in CandelaKit, under test.
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
  /// target would silently write against BRIGHTNESS (lens-4 M7). This is a
  /// compile-time elimination, which is why it needs no test.
  private enum Target: Hashable {
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

  /// A hard 60 pt clipped the value at larger text sizes: three digits plus the
  /// caret do not fit a fixed box once the font grows (accessibility contract
  /// 10). The base stays 60 so the grid's columns are unchanged at the default
  /// size.
  @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 60

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
  /// rule 3 requires for this state lives on the hub
  /// (`DisplayHubView.recoverFromHardwareMute`) and is never disabled; the
  /// Advanced page's DDC toggle, which is the other way out, is gated only by
  /// live HDR for the same reason.
  private var trafficBlock: DDCTrafficBlock? {
    DisplayCardPolicy.ddcTrafficBlock(for: state.controller.brightnessPath)
  }

  private var isInert: Bool { trafficBlock != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        // Visible column headers are an ADDITION (spec §6). The per-control
        // accessibility labels below stay exactly as they were — a11y contract
        // 9 makes them load-bearing, and a visible header does not reach
        // VoiceOver from inside a `Grid` cell.
        GridRow {
          Color.clear.frame(width: 1, height: 1)
          columnHeader("On")
          columnHeader("Min")
          columnHeader("Max")
          columnHeader("Invert")
        }
        // No row-level accessibility group: a modifier applied to a `GridRow`
        // distributes onto EACH CELL, so the old `.accessibilityElement(
        // children: .contain)` + row label pair wrapped every cell in its own
        // container named after the command (the T15 concern, confirmed by the
        // combined pass's D5). The per-control labels below carry the command
        // name themselves, so a11y contract 9's per-control clause holds; the
        // row-as-group clause is traded away because no spelling of it
        // survives `GridRow`'s modifier distribution.
        ForEach(DDCCommand.allCases, id: \.self) { command in
          GridRow {
            Text(verbatim: DDCCommandCopy.title(command))
            Toggle("", isOn: enabledBinding(command))
              .labelsHidden()
              // Without it the toggle takes the column's full width and draws
              // its switch at the trailing edge, which no header placement can
              // sit above. Fixed size makes the cell the switch.
              .fixedSize()
              .accessibilityLabel(Text("\(rowName(command)) enabled"))
            overrideField(.minimum(command))
            overrideField(.maximum(command))
            Toggle("", isOn: invertBinding(command))
              .labelsHidden()
              .fixedSize()
              .accessibilityLabel(Text("Invert \(rowName(command))"))
          }
        }
      }
      // Belt to the section-level disable `AdvancedPage` applies (SO12): this
      // grid is the thing a traffic block actually voids, so it states the
      // condition itself rather than trusting its container.
      .disabled(isInert)
      captions
    }
  }

  // MARK: - Cells

  /// The `Grid` is built `.leading`, which put every header at the left edge of
  /// a column wider than the header itself: "On" sat left of its switch and
  /// "Min"/"Max" left of their fields. `gridColumnAlignment` set on a cell
  /// governs the whole COLUMN, so declaring it here centers header and control
  /// on one axis. The command-name column is not a header cell and keeps the
  /// grid's leading alignment.
  private func columnHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.center)
  }

  /// A `String`, not a `LocalizedStringKey`: interpolating a
  /// `LocalizedStringKey` INTO a `LocalizedStringKey` literal has no matching
  /// interpolation overload, so the accessibility labels above would not
  /// compile (lens-1 M4), and the same names are needed mid-sentence in the
  /// captions.
  private func rowName(_ command: DDCCommand) -> String { DDCCommandCopy.name(command) }

  /// The bezel, the width and the accessibility label are the same as they
  /// always were; what `CommitOnBlurField` adds is that leaving the box applies
  /// the number, which typing into one box and clicking the next always looked
  /// like it did (#144).
  private func overrideField(_ target: Target) -> some View {
    CommitOnBlurField(
      stored: { storedText(target) },
      commit: { commit(target, $0) },
      fieldLabel: Text(accessibilityLabel(for: target)),
      width: fieldWidth
    )
    // Keyed to the display: SO23's switcher can carry this page onto another
    // display while a box is being typed in, and a field that kept its text
    // across that would commit one display's number to another's pref. A new
    // identity per display also lets a pending edit commit to the display it
    // was typed for, on the way out.
    .id(state.display.persistenceKey)
  }

  private func accessibilityLabel(for target: Target) -> String {
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

  private func storedText(_ target: Target) -> String {
    let tuning = prefs.tuning(for: target.command)
    return switch target.field {
    case .minimum: DDCOverrideValidation.text(for: tuning.minDDCOverride)
    case .maximum: DDCOverrideValidation.text(for: tuning.maxDDCOverride)
    }
  }

  /// Return and focus loss both arrive here, so neither route can validate the
  /// text more loosely than the other (#144).
  ///
  /// ONE command's tuning in, the same tuning with ONE field changed out.
  /// `DDCOverrideValidation.committed` returns nil for both refusals, garbage
  /// and "that is already the stored value", and nil means write nothing at
  /// all: the field snaps itself back, and a typo never fans out to a
  /// `reapplyAfterPrefChange()`. Note there is no loop over
  /// `DDCCommand.allCases` anywhere in this function: that shape is the fork's
  /// QUIRK 7, and `DDCOverrideApplicationTests` is what keeps it out.
  private func commit(_ target: Target, _ text: String) {
    let command = target.command
    guard let tuning = DDCOverrideValidation.committed(
      text, to: prefs.tuning(for: command), field: target.field
    ) else { return }
    let name: PrefName = target.field == .minimum ? .minDDCOverride : .maxDDCOverride
    writer.write(name) { $0.setTuning(tuning, for: command) }
  }

  // MARK: - Captions

  @ViewBuilder private var captions: some View {
    // SO12: the block's explanation is stated ONCE for the page, by
    // `AdvancedPage` at the foot of Control Method — the section above the
    // first section a block greys out. It used to be repeated here, which is
    // the duplication SO12 exists to remove; what stays is the silence, because
    // the captions below describe controls that are not currently doing
    // anything.
    if trafficBlock == nil {
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
