import CandelaKit
import SwiftUI

/// Display names for the DDC commands, in ONE place: the grid's row labels, its
/// accessibility labels and the Advanced page's VCP Overrides group all name the
/// same things. Never `DDCCommand.rawValue`: those raws are shipped on-disk
/// schema that reads as English by coincidence.
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

  /// Split out so a test can pin the exact wording.
  static func enabledSwitchLabel(_ command: DDCCommand) -> String {
    "\(name(command)) enabled"
  }

  static func invertSwitchLabel(_ command: DDCCommand) -> String {
    "Invert \(name(command))"
  }
}

/// Per-command DDC tuning for one display: Enabled / Min / Max / Invert for
/// brightness, volume and contrast. The response curve and the hex
/// control-code remap live in the Advanced page's VCP Overrides sub-group
/// below, and that page owns the section header and its traffic-block
/// explanation, so neither is drawn here.
///
/// Every edit is a read-modify-write of ONE command's tuning; the modify half is
/// `DDCOverrideValidation.committed` in CandelaKit, under test. The fork rewrote
/// all 18 keys and forced brightness to 100% on any single edit (QUIRK 7); here
/// nothing writes brightness at all, and the pref propagation seam re-applies the SAME
/// published value through `reapplyAfterPrefChange()`, which is what
/// makes an override take effect without waiting for the next slider drag.
///
/// `@MainActor`: it stores a `@MainActor` `DisplayPrefWriter` and reads it from
/// computed properties that are nonisolated on a plain `View`.
@MainActor
struct CommandTuningGrid: View {
  let state: AppModel.DisplayState
  let writer: DisplayPrefWriter

  /// Carries the `DDCCommand` itself, not its raw string: a raw-string target
  /// needed a `?? .brightness` fallback, so a mis-key silently wrote against
  /// BRIGHTNESS. Eliminated at compile time, so it needs no test.
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

  /// A hard 60 pt clipped three digits plus the caret once the font grew (a11y
  /// contract 10). The base stays 60, so default-size columns are unchanged.
  @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 60

  @Environment(\.settingsAccent) private var lighting

  private var prefs: DisplayPrefs { writer.prefs }

  /// Why no DDC command is reaching this display, if none is, read from the
  /// ENGINE'S OWN PATH, the same one Diagnostics renders. Computing it here from
  /// `prefs.forceSoftware` missed live HDR (DDC is dead outright there) and
  /// contradicted the Diagnostics row, so one page gave two answers.
  ///
  /// Disable, don't hide. The recovery control the mute-strand rule requires
  /// for this state lives on the hub and is never disabled; the Advanced
  /// page's DDC toggle, the other way out, is gated only by live HDR for the same reason.
  private var trafficBlock: DDCTrafficBlock? {
    DisplayCardPolicy.ddcTrafficBlock(
      for: state.controller.brightnessPath,
      isWireUnresponsive: state.controller.isWireUnresponsive
    )
  }

  private var isInert: Bool { trafficBlock != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        // A visible header does not reach VoiceOver from inside a `Grid` cell,
        // so the per-control accessibility labels below stay (a11y contract 9).
        GridRow {
          Color.clear.frame(width: 1, height: 1)
          columnHeader("On")
          columnHeader("Min")
          columnHeader("Max")
          columnHeader("Invert")
        }
        // No row-level accessibility group: a modifier on a `GridRow`
        // distributes onto EACH CELL, so `.accessibilityElement(children:
        // .contain)` wrapped every cell in its own container named after the
        // command. The per-control labels below carry the command name, so a11y
        // contract 9's per-control clause holds; no spelling of the row-as-group
        // clause survives `GridRow`'s modifier distribution.
        ForEach(DDCCommand.allCases, id: \.self) { command in
          GridRow {
            Text(verbatim: DDCCommandCopy.title(command))
              .settingsText(SettingsTheme.titleColor)
            // NOT `themedSwitch()`: it draws the label at the leading edge and
            // spreads the row. Here the first column is the label, and the cell
            // has to BE the switch for the header to sit above it.
            switchCell(
              DDCCommandCopy.enabledSwitchLabel(command), isOn: enabledBinding(command)
            )
            .prefIdentifier(.unavailableDDC, command: command, persistenceKey: writer.persistenceKey)
            overrideField(.minimum(command))
            overrideField(.maximum(command))
            switchCell(
              DDCCommandCopy.invertSwitchLabel(command), isOn: invertBinding(command)
            )
            .prefIdentifier(.invertDDC, command: command, persistenceKey: writer.persistenceKey)
          }
        }
      }
      // Belt to the card-level disable `AdvancedPage` applies: the grid
      // is what a traffic block voids, so it states the condition itself.
      .disabled(isInert)
      captions
    }
    .padding(.vertical, 6)
  }

  // MARK: - Cells

  /// The label is the control's own, not an `.accessibilityLabel` over an empty
  /// one; `.labelsHidden()` hides it because the first column draws the name.
  /// This is not what fixes a refused press: measured 2026-08-27, the old shape
  /// published `AXPress` too and the switches were `AXEnabled=0` under the MAG's
  /// live HDR, so a refused press means the traffic block below.
  private func switchCell(_ label: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) { Text(verbatim: label) }
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      .tint(lighting.accent)
      // Without this the toggle spans the column and draws its switch at the
      // trailing edge, where no header can sit above it.
      .fixedSize()
  }

  /// `gridColumnAlignment` on a cell governs the whole COLUMN, so centering here
  /// puts header and control on one axis. The grid is `.leading`, which otherwise
  /// parks each header at the left edge of a wider column.
  private func columnHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.caption)
      .settingsText(SettingsTheme.faintColor)
      .gridColumnAlignment(.center)
  }

  /// A `String`, not a `LocalizedStringKey`: there is no overload for
  /// interpolating one `LocalizedStringKey` into another, so the labels above
  /// would not compile.
  private func rowName(_ command: DDCCommand) -> String { DDCCommandCopy.name(command) }

  /// `CommitOnBlurField` applies the number when the box loses focus: typing
  /// into one box and clicking the next always looked like it committed.
  private func overrideField(_ target: Target) -> some View {
    CommitOnBlurField(
      stored: { storedText(target) },
      commit: { commit(target, $0) },
      fieldLabel: Text(accessibilityLabel(for: target)),
      width: fieldWidth
    )
    // Keyed to the display: the display switcher can carry this page to another
    // display mid-typing, and a field that kept its text would commit one
    // display's number to another's pref.
    .id(state.display.persistenceKey)
    // The Target carries the field, so the name it composes cannot drift from
    // the name `commit` writes: both branch on the same `target.field`.
    .prefIdentifier(target.field == .minimum ? .minDDCOverride : .maxDDCOverride, command: target.command, persistenceKey: writer.persistenceKey)
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
        // `toggleMute` refuses once `isAvailable` is false, so
        // unmute BEFORE disabling the volume command.
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

  /// Return and focus loss both arrive here, so neither route validates more
  /// loosely than the other. ONE command's tuning in, the same tuning with ONE
  /// field changed out. `DDCOverrideValidation.committed` returns nil for
  /// garbage, for a refusal and for "already the stored value", and nil writes
  /// nothing: the field snaps back and a typo never fans out to a
  /// `reapplyAfterPrefChange()`. No loop over `DDCCommand.allCases` here; that
  /// shape is the fork's QUIRK 7, and `DDCOverrideApplicationTests` keeps it out.
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
    // `AdvancedPage` states the block's explanation once for the page.
    // What stays here is the silence, because the captions below describe
    // controls that are doing nothing.
    if trafficBlock == nil {
      SettingsCaption("Most displays need none of this. Use it when a display bottoms out or tops out early, or runs backwards. Leave a box empty to use the display's own range.")
      // Said before the click: Invert is the one column whose wrong setting
      // makes a shape nobody reads as "I set this wrong". It corrects hardware,
      // so on a display that does not run backwards the register turns around
      // while the software leg keeps running forwards, and the combined response
      // peaks at the switching point. `InvertCompositionTests` pins that shape.
      SettingsCaption("Invert is only for a display whose brightness runs backwards. On any other display it runs the slider the wrong way, and with combined dimming on the slider peaks in the middle and dims again above that.")
      brightnessLegCaption
      let ignored = ignoredMaxCommands
      if ignored.count == 1 {
        SettingsCaption("The maximum you set for \(rowName(ignored[0])) is not above its minimum, so \(AppInfo.productName) ignores it and uses the display's own maximum.")
      } else if ignored.count > 1 {
        SettingsCaption("The maximums you set for \(ignoredList(ignored)) are not above their minimums, so \(AppInfo.productName) ignores them and uses the display's own maximums.")
      }
    }
  }

  /// What turning the BRIGHTNESS command off actually did, in the Diagnostics
  /// section's words because it comes off the same value. Reading
  /// `unavailableDDC` instead always said "dims in software only", true on only
  /// one of the two paths that flag produces.
  @ViewBuilder private var brightnessLegCaption: some View {
    switch state.controller.brightnessPath {
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      SettingsCaption("With brightness off, this display dims in software only below \(SliderSnap.percentText(dimsBelow)). Above that, nothing moves.")
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      SettingsCaption("With brightness off, nothing is moving this display's brightness.")
    // Silent about the wire on purpose: this caption explains the Off switch
    // above it, and a display that stopped answering did not get there from
    // this control.
    case .softwareOnly(_, .ddcUnresponsive, _), .unavailable(.ddcUnresponsiveWithNoSoftwareLeg):
      EmptyView()
    case .native, .software, .hardware, .combined:
      EmptyView()
    }
  }

  /// Commands whose stored max override is silently inert.
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
