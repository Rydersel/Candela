import CandelaKit
import CoreGraphics
import SwiftUI

/// The Protection pillar (SC6): the policies that guard a display's
/// configuration. The startup and wake restore choice, and under it a read-only
/// summary of what Remember-size promises on each display. The Remember control
/// itself stays on that display's page, so the pref keeps one write surface.
///
/// Nothing unbuilt is listed (SC6): a greyed row for a feature nobody can turn
/// on is a promise the app cannot keep.
///
/// `@MainActor`: a `View`'s non-`body` properties are nonisolated under complete
/// concurrency, and these read main-actor types.
@MainActor
struct ProtectionPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, and neither the
    // stored mode nor the remembering flag is published. Without this read the
    // startup caption never follows its own picker, and a size pinned on a
    // display's page never reaches the summary below.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Protection",
        subtitle:
          "A display does not always come back the way you left it. Protection holds the rules "
          + "that decide what \(AppInfo.productName) puts back at startup, at wake, and on reconnect."
      )
      startupSection
      rememberedSizesSection
    }
  }

  // MARK: - Startup

  private var startupSection: some View {
    SettingsCardSection(title: "Startup") {
      SettingRow(Self.startupCaption(for: prefs.startupAction)) {
        ThemedChoiceRow(label: "On startup and wake:", selection: Binding(
          get: { prefs.startupAction },
          set: { action in
            prefs.startupAction = action
            actions.prefDidChange(.startupAction)
          }
        )) {
          Text("Trust the last saved values (recommended)").tag(StartupAction.doNothing)
          Text("Re-send the last saved values to the display").tag(StartupAction.write)
          Text("Ask the display for its current values").tag(StartupAction.read)
        }
        .prefIdentifier(.startupAction)
      }
      // `startupCaption` is NOT repeated here: `SettingRow` above already draws
      // it beneath the picker.
      if prefs.startupAction == .read {
        // Row weight rather than a standalone caption: it qualifies
        // `startupCaption` above it, which `SettingRow` draws small and faint, so
        // a callout here would be the brighter of the two.
        SettingsCaption("Some displays never answer DDC reads; values then stay as last saved.")
          .text
          .font(.caption)
          .foregroundStyle(SettingsTheme.faintColor)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 6)
      }
      SettingsCardDivider()
      // The picker shows the PERSISTED choice even in a safe-mode session: this
      // pane's `DisplayPrefs` is built without the safe-mode flag, so it reports
      // what is on disk rather than the `.doNothing` the engine is running on.
      // Right for a settings control, but also a control describing behavior
      // that is not happening, so safe mode has to be visible right here (D11).
      //
      // Safe mode's scope must NEVER be written as "no DDC commands" in either
      // branch: sliders and keys still work and still send DDC.
      if model.isSafeMode {
        safeModeNotice
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Image(systemName: "shift")
          Text("Hold Shift while launching for Safe Mode: saved values aren't restored.")
        }
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .padding(.bottom, 2)
      }
    }
  }

  /// The active state D11 requires to be visible, as a notice inside the card
  /// rather than an always-on paragraph: the full scope is shown HERE, in the
  /// state it describes.
  ///
  /// The words are `SafeModeCopy`'s, and every surface that describes safe mode
  /// reads that one exhaustive list: the launch alert and the Diagnostics row
  /// once described a narrower feature than the app was running.
  private var safeModeNotice: some View {
    SettingsNotice {
      Text("Safe Mode is on for this session, so this setting is not in effect.")
        .font(.callout.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      SettingsCaption(verbatim: SafeModeCopy.generalPaneCaption(app: AppInfo.productName))
    }
    .padding(.top, 10)
    .padding(.bottom, 4)
  }

  /// Exhaustive, so a future `StartupAction` case is a compile error here rather
  /// than a silently missing caption.
  ///
  /// Static and nameable rather than computed over `prefs`, so the test bundle
  /// can assert the mapping without a window (AT10): a caption stuck on the wrong
  /// option describes a restore that will not happen.
  static func startupCaption(for action: StartupAction) -> LocalizedStringKey {
    switch action {
    case .write: "Useful when a display forgets its settings while asleep."
    case .read: "Reads brightness, contrast and volume back from the display. Not all hardware answers."
    case .doNothing: "Keeps using the values from last time, and sends them to the display the first time you change something."
    }
  }

  // MARK: - Remembered sizes

  /// One read-only row per display, showing what Remember-size promises there
  /// and pushing the page that owns the control (SC6, SO3). Read-only is the
  /// point: a pref with two write surfaces has two places to get it wrong.
  private var rememberedSizesSection: some View {
    SettingsCardSection(title: "Remembered Sizes") {
      let rows = Self.rememberedSizeRows(rememberedSizeInputs())
      if rows.isEmpty {
        // The sidebar's own phrase for this state, so the two surfaces agree.
        SettingsRowNote("No external displays connected")
      } else {
        ForEach(rows) { row in
          if row.id != rows.first?.id {
            SettingsCardDivider()
          }
          NavigationRow(title: row.name, value: row.value, spokenValue: row.spokenValue) {
            actions.reveal(.display(row.persistenceKey))
          }
        }
        // No divider above it: a qualifier with a rule of its own reads as one
        // more setting rather than as a note about the rows.
        SettingsRowNote("A remembered size is put back when that display reconnects. Turn remembering on or off on the display's own page.")
      }
    }
  }

  /// What each row is derived FROM, and the only place the pane touches the
  /// coordinator, so the derivation stays pure and the test bundle can drive it.
  ///
  /// The built-in comes first, the way the sidebar orders it, and it is included
  /// because it departs whenever the lid closes, which is exactly the reconnect
  /// this promise is about.
  private func rememberedSizeInputs() -> [RememberedSizeInput] {
    let coordinator = model.displayModes
    let states = [model.builtIn].compactMap { $0 } + model.displays
    return states.map { state in
      let displayPrefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
      return RememberedSizeInput(
        name: DisplayOrdering.title(
          friendlyName: displayPrefs.friendlyName, hardwareName: state.display.name),
        persistenceKey: state.display.persistenceKey,
        // The SAME derivation the control renders
        // (`RememberResolutionRow.pinnedRow`), never a second reading: a summary
        // that disagreed with the row it summarises is worse than none.
        pinned: RememberResolutionRow.pinnedRow(
          isRemembering: coordinator.isRemembering(state.id),
          stored: coordinator.storedDescriptor(for: state.id))
      )
    }
  }

  /// One display's inputs to the summary: name, page, and what its Remember row
  /// is showing.
  struct RememberedSizeInput: Equatable {
    let name: String
    let persistenceKey: String
    let pinned: RememberResolutionRow.PinnedRow
  }

  /// A summary row as drawn: the name, the promise as seen, and as spoken.
  struct RememberedSizeRow: Identifiable, Equatable {
    /// Not the persistence key alone: two identical panels share one key, and a
    /// `ForEach` over duplicate ids hands the old view instance to the other
    /// display's row. The ordinal that disambiguates the NAME does this too.
    let id: String
    let name: String
    let persistenceKey: String
    let value: String
    let spokenValue: String
  }

  /// The summary's whole derivation, pure so the test bundle reaches it (AT10).
  /// The numbering comes from `DisplayOrdering`, the sidebar's own helper, so a
  /// numbered name means the same display in both lists.
  static func rememberedSizeRows(_ inputs: [RememberedSizeInput]) -> [RememberedSizeRow] {
    let ordinals = DisplayOrdering.sharedIdentityOrdinals(keys: inputs.map(\.persistenceKey))
    return inputs.indices.map { index in
      let input = inputs[index]
      let ordinal = ordinals.indices.contains(index) ? ordinals[index] : nil
      let name = ordinal.map { "\(input.name) (\($0))" } ?? input.name
      return RememberedSizeRow(
        id: ordinal.map { "\(input.persistenceKey)#\($0)" } ?? input.persistenceKey,
        name: name,
        persistenceKey: input.persistenceKey,
        value: value(for: input.pinned),
        spokenValue: spokenValue(for: input.pinned)
      )
    }
  }

  /// The promise in the words the control uses. "Off" is not a hedge: the toggle
  /// is off, so nothing is restored and there is no pinned size to name.
  static func value(for pinned: RememberResolutionRow.PinnedRow) -> String {
    switch pinned {
    case .hidden: "Off"
    // The Remember row's own empty state: remembering is on, nothing to put
    // back yet.
    case .empty: "On, nothing pinned"
    case let .pinned(stored):
      "\(DisplayModeCopy.size(stored)) · \(DisplayModeCopy.refresh(stored.refreshHz))"
    }
  }

  /// The same answers as words. The flag states already are words; the pinned
  /// one is glyph-packed display text, and `ModeSpeech` is the one helper that
  /// turns a mode into something VoiceOver reads.
  static func spokenValue(for pinned: RememberResolutionRow.PinnedRow) -> String {
    switch pinned {
    case .hidden, .empty: value(for: pinned)
    case let .pinned(stored):
      ModeSpeech.spoken(
        logicalWidth: stored.logicalWidth, logicalHeight: stored.logicalHeight,
        refreshHz: stored.refreshHz)
    }
  }
}
