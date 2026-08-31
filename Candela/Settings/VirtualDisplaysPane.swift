import CandelaKit
import CoreGraphics
import SwiftUI

/// The virtual display slots (VD2). A virtual display never gets a menu bar row
/// or a per-display destination: it has no DDC and no brightness, and macOS
/// handles its arrangement and scaling once it exists.
///
/// Every write goes through `SettingsActions` with a `PrefName` case (D27).
/// Only the `virtualSlotConfigured` write converges live displays (VD14),
/// scoped to the written slot so one slot's Create never applies another slot's
/// pending edits (VD17). Field edits are inert until Create or Apply.
@MainActor
struct VirtualDisplaysPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.settingsAccent) private var lighting
  /// Which slot the controls below describe. Nil until something is added or
  /// clicked; the effective selection falls back to the first added slot.
  @State private var selectedSlot: Int?

  /// The selected slot's create failure as RENDERED, mirroring
  /// `AppModel.virtualSlotIssues` one update behind. A keyed `.animation` never
  /// faded the sentence symmetrically (measured 2026-08-17: nothing in either
  /// direction on a wrapping `Group`, fade IN then SNAP out on a container
  /// inside the row). The mirror puts arrival and departure in one transaction.
  ///
  /// It carries the SLOT it is about, and the row renders nothing unless the two
  /// agree. Without the slot a switch shows the previous slot's failure until
  /// the sync lands.
  @State private var shownIssue: ShownIssue?

  private struct ShownIssue: Equatable {
    var slot: Int
    var failure: VirtualDisplayFailure?
  }

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  /// Slots the user has ADDED. These have tiles whether or not a display is
  /// currently running.
  private var definedSlots: [Int] {
    VirtualDisplayIdentity.userSlotRange.filter { prefs.virtualSlot($0).defined }
  }

  private func effectiveSelection(in defined: [Int]) -> Int? {
    if let selectedSlot, defined.contains(selectedSlot) { return selectedSlot }
    return defined.first
  }

  /// The page's opening sentence. Absent when the feature is unavailable, since
  /// describing a capability this Mac does not have is the wrong thing to read
  /// first.
  private static let capabilitySentence =
    "A virtual display behaves like a connected display: windows move to it, it appears in arrangement, and it can be shared or recorded."

  var body: some View {
    let _ = model.prefsRevision
    let defined = definedSlots
    let available = model.virtualDisplays.isAvailable
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Virtual Displays",
        subtitle: available ? Self.capabilitySentence : nil)
      if available {
        if model.isSafeMode { safeModeCard }
        selectorSection(defined: defined)
        if let slot = effectiveSelection(in: defined) {
          slotSection(slot)
            // Load-bearing: without it SwiftUI reuses ONE text field instance
            // across a slot change and an uncommitted draft commits into the
            // slot the user just switched TO. With it the old fields are
            // removed, and their on-disappear commit still holds the OLD
            // slot's closures.
            .id(slot)
        }
      } else {
        unavailableCard
      }
    }
  }

  private var safeModeCard: some View {
    SettingsCardSection {
      SettingsCaption(
        "Safe Mode session: displays marked to come back at launch were not recreated. Create still works here."
      )
    }
  }

  private var unavailableCard: some View {
    // VD16: the class family resolved to nothing on this macOS, so every entry
    // point is inert and the pane says why rather than showing dead controls.
    // No kicker, or the page header's title is said twice.
    SettingsCardSection {
      SettingsCaption("Virtual displays are unavailable on this version of macOS.")
    }
  }

  // MARK: - Slot selector

  /// One tile per ADDED display, in the arrangement map's visual language. A
  /// ghosted Add tile follows while free slots remain and stands alone at hero
  /// size when nothing has been added. Real buttons, so keyboard and VoiceOver
  /// reach every tile.
  private func selectorSection(defined: [Int]) -> some View {
    SettingsCardSection {
      VStack(spacing: 12) {
        HStack(alignment: .top, spacing: 14) {
          let selection = effectiveSelection(in: defined)
          ForEach(defined, id: \.self) { slot in
            slotTile(slot, isSelected: selection == slot)
          }
          if let free = VirtualDisplayIdentity.userSlotRange.first(where: { !defined.contains($0) }) {
            addTile(slot: free, isHero: defined.isEmpty)
          }
        }
        Text(verbatim: Self.capacityCaption(definedCount: defined.count))
          .font(.caption)
          .foregroundStyle(SettingsTheme.faintColor)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 6)
    }
  }

  /// Counts SLOTS, not running displays: a slot with a stopped display in it is
  /// still spent.
  static func capacityCaption(definedCount: Int) -> String {
    let cap = VirtualDisplayIdentity.userSlotRange.count
    let spelled = Self.spelled(cap)
    if definedCount == 0 {
      return "Nothing created yet; up to \(spelled) virtual displays can run at once."
    }
    if definedCount >= cap {
      return "All \(spelled) slots are in use; remove one to create a different display."
    }
    return "Up to \(spelled) virtual displays can run at once."
  }

  /// A small count as a word, the way the rest of the window writes one. The
  /// digits are a fallback, so the sentence still reads if the slot range grows
  /// past the list.
  private static func spelled(_ count: Int) -> String {
    let words = ["zero", "one", "two", "three", "four", "five", "six"]
    return words.indices.contains(count) ? words[count] : String(count)
  }

  /// Adds the lowest free slot at the slot defaults, creates it immediately,
  /// and selects it.
  @ViewBuilder private func addTile(slot: Int, isHero: Bool) -> some View {
    Button {
      var definition = prefs.virtualSlot(slot)
      definition.defined = true
      definition.configured = true
      definition.uuid = UUID()
      prefs.setVirtualSlot(definition, slot: slot)
      selectedSlot = slot
      // The batch, never a representative name; the slot scopes the
      // convergence to this write (VD17).
      actions.prefsDidChange(
        [.virtualSlotDefined, .virtualSlotConfigured, .virtualSlotUUID], virtualSlot: slot
      )
    } label: {
      GhostDisplayTile(accent: lighting.accent, isHero: isHero)
        .frame(width: isHero ? 232 : 96, height: isHero ? 144 : 76)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Add a virtual display"))
    .accessibilityIdentifier("action.slotAdd.\(slot)")
  }

  /// Shared by the picture and VoiceOver so the two cannot disagree. The size
  /// is the ACHIEVED one, never the spec's claim.
  ///
  /// `achievedMode` is the host's verdict recorded at creation, not a live
  /// topology read: this process usually cannot read a display it created.
  private func tileStatus(_ slot: Int) -> (running: Bool, line: String) {
    let running = liveHandle(slot: slot) != nil
    if running, let achieved = model.virtualDisplays.achievedMode(slot: slot) {
      return (true, "\(String(achieved.width)) x \(String(achieved.height))")
    }
    return (running, running ? "Running" : "Not created")
  }

  @ViewBuilder private func slotTile(_ slot: Int, isSelected: Bool) -> some View {
    let definition = prefs.virtualSlot(slot)
    let status = tileStatus(slot)
    // The slot's configured shape, so the row previews what Create will make.
    // Uniform height keeps the row from jumping as definitions change.
    let height = 76.0
    let width = min(150, max(96, height * Double(definition.width) / Double(max(1, definition.height))))
    Button {
      selectedSlot = slot
    } label: {
      DisplayTile(
        name: definition.name,
        pointSize: status.line,
        mirroredCount: 0,
        isMain: false,
        isSelected: isSelected,
        isFocused: false,
        isInvalid: false,
        isDragging: false,
        isVirtual: status.running,
        labels: TileLabelStyle(detail: .nameAndSize, nameSize: 11, showsMirrored: false)
      )
      .frame(width: width, height: height)
      .contentShape(RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: "\(definition.name), \(status.running ? "running at \(status.line)" : "not created")"))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func liveHandle(slot: Int) -> VirtualDisplayHandle? {
    model.virtualDisplays.live().first { $0.slot == slot }
  }

  // MARK: - The selected slot

  @ViewBuilder
  private func slotSection(_ slot: Int) -> some View {
    let definition = prefs.virtualSlot(slot)
    let live = liveHandle(slot: slot)
    SettingsCardSection(title: "Display \(slot)") {
      statusRow(slot: slot, live: live)
      SettingsCardDivider()
      nameRow(slot: slot)
      SettingsCardDivider()
      sizeRows(slot: slot, definition: definition)
      SettingsCardDivider()
      SettingRow("The display is created again the next time \(AppInfo.productName) opens.") {
        Toggle("Come Back at Launch", isOn: binding(slot: slot,
                                                    name: .virtualSlotRecreateAtLaunch,
                                                    keyPath: \.recreateAtLaunch))
          .themedSwitch()
          .prefIdentifier(.virtualSlotRecreateAtLaunch, slot: slot)
      }
      SettingsCardDivider()
      actionRow(slot: slot, definition: definition, live: live)
    }
  }

  @ViewBuilder
  private func statusRow(slot: Int, live: VirtualDisplayHandle?) -> some View {
    let busy = model.virtualSlotBusy.contains(slot)
    VStack(alignment: .leading, spacing: 6) {
      // A branch swap around a `ProgressView`, not an insert, so this row is
      // left un-animated: fading a spinner into a sentence and back reads badly.
      HStack {
        Text("Status")
        Spacer()
        if busy {
          ProgressView().controlSize(.small)
          Text("Working").foregroundStyle(SettingsTheme.bodyColor)
        } else if live != nil, let achieved = model.virtualDisplays.achievedMode(slot: slot) {
          // ACHIEVED state, never the spec's claim: the Retina suffix appears
          // only when the 2x mode engaged. `String(_:)` verbatim, or
          // interpolation groups the digits (1,920 x 1,080).
          Text("Running at \(String(achieved.width)) x \(String(achieved.height))\(achieved.hiDPI ? " (Retina)" : "")")
            .foregroundStyle(SettingsTheme.bodyColor)
        } else if live != nil {
          Text("Running").foregroundStyle(SettingsTheme.bodyColor)
        } else {
          Text("Not created").foregroundStyle(SettingsTheme.bodyColor)
        }
      }
      if let shown = shownIssue, shown.slot == slot, let issue = shown.failure {
        // A create that fails must not look like a click that was ignored.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(verbatim: Self.sentence(for: issue))
        }
        .font(.callout)
        .foregroundStyle(SettingsTheme.dangerTint)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .foregroundStyle(SettingsTheme.titleColor)
    // The mirror hooks hang on the status row because it is always present.
    // Hooks on the sentence would exist only while the failure does, so nothing
    // would be watching for it to arrive. The appear sync is un-animated and
    // re-runs on a slot change, since `slotSection` carries the slot identity.
    .onAppear { shownIssue = ShownIssue(slot: slot, failure: visibleIssue(slot: slot)) }
    .onChange(of: visibleIssue(slot: slot)) { _, issue in
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) {
        shownIssue = ShownIssue(slot: slot, failure: issue)
      }
    }
  }

  /// What the mirror follows. No sentence while the slot is busy, so a failure
  /// arriving mid-work fades in when the work ends rather than under the
  /// spinner.
  private func visibleIssue(slot: Int) -> VirtualDisplayFailure? {
    guard !model.virtualSlotBusy.contains(slot) else { return nil }
    return model.virtualSlotIssues[slot]
  }

  private static func sentence(for failure: VirtualDisplayFailure) -> String {
    switch failure {
    case .classFamilyUnavailable:
      "Virtual displays are unavailable on this version of macOS."
    case .capExceeded:
      "This display slot is already in use."
    case .refused, .settingsRejected:
      "macOS did not accept this display's settings."
    case .identityInUse:
      "The previous display for this slot has not finished leaving; try again in a moment."
    case .neverAppearedOnline:
      "The display was created but never appeared."
    case .wouldBecomeMainDisplay:
      "Creating this display would have moved your main display, so it was undone."
    case .didNotDepart:
      "The display could not be removed; it will disappear when \(AppInfo.productName) quits."
    }
  }

  private func nameRow(slot: Int) -> some View {
    SettingRow("The name shows in System Settings and applies when the display is next created.") {
      HStack {
        Text("Name")
        Spacer()
        CommitOnBlurField(
          stored: { prefs.virtualSlot(slot).name },
          commit: { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            var updated = prefs.virtualSlot(slot)
            updated.name = trimmed
            prefs.setVirtualSlot(updated, slot: slot)
            actions.prefDidChange(.virtualSlotName)
          },
          fieldLabel: Text("Display \(slot) name"),
          width: 220
        )
        .prefIdentifier(.virtualSlotName, slot: slot)
      }
    }
  }

  /// The width and height fields below the picker are always present, so a
  /// custom size is typed directly and the picker reads "Custom" when the fields
  /// match no preset. Never unmount them on a preset choice: removing them
  /// mid-edit fires their on-disappear commit with a pre-choice draft and
  /// silently reverts the preset.
  private static let presets: [(label: String, width: Int, height: Int)] = [
    ("1920 x 1080", 1920, 1080),
    ("2560 x 1440", 2560, 1440),
    ("3440 x 1440", 3440, 1440),
    ("3840 x 2160 (4K)", 3840, 2160),
  ]

  /// The picker and both number fields are on screen at once, so the
  /// `virtualSlotWidth`/`virtualSlotHeight` identifiers go on the fields, which
  /// store an arbitrary size, and the picker carries none. Two elements
  /// answering to one identifier leave an accessibility walk picking whichever
  /// it meets first.
  @ViewBuilder
  private func sizeRows(slot: Int, definition: VirtualSlotDefinition) -> some View {
    let presetIndex = Self.presets.firstIndex {
      $0.width == definition.width && $0.height == definition.height
    }
    SettingRow("Size changes apply when the display is next created.") {
      ThemedChoiceRow(label: "Size", selection: Binding(
        get: { presetIndex ?? -1 },
        set: { newIndex in
          // Custom is a read-only state of the picker, not a choice: typing in
          // the fields below is what makes a size custom.
          guard newIndex >= 0 else { return }
          var updated = prefs.virtualSlot(slot)
          updated.width = Self.presets[newIndex].width
          updated.height = Self.presets[newIndex].height
          prefs.setVirtualSlot(updated, slot: slot)
          actions.prefsDidChange([.virtualSlotWidth, .virtualSlotHeight])
        }
      )) {
        ForEach(Self.presets.indices, id: \.self) { index in
          Text(Self.presets[index].label).tag(index)
        }
        Text("Custom").tag(-1)
      }
    }
    SettingsCardDivider()
    SettingRow {
      HStack {
        Text("Width and Height")
        Spacer()
        numberField(slot: slot, label: "Width", name: .virtualSlotWidth,
                    get: { $0.width }, set: { $0.width = $1 })
          .prefIdentifier(.virtualSlotWidth, slot: slot)
        Text("x").foregroundStyle(SettingsTheme.faintColor)
        numberField(slot: slot, label: "Height", name: .virtualSlotHeight,
                    get: { $0.height }, set: { $0.height = $1 })
          .prefIdentifier(.virtualSlotHeight, slot: slot)
      }
    }
    SettingsCardDivider()
    SettingRow("Text renders at double resolution when the display is next created.") {
      Toggle("Retina (HiDPI)", isOn: binding(slot: slot,
                                             name: .virtualSlotHiDPI, keyPath: \.hiDPI))
        .themedSwitch()
        .prefIdentifier(.virtualSlotHiDPI, slot: slot)
    }
  }

  private func numberField(
    slot: Int, label: String, name: PrefName,
    get: @escaping (VirtualSlotDefinition) -> Int,
    set: @escaping (inout VirtualSlotDefinition, Int) -> Void
  ) -> some View {
    CommitOnBlurField(
      stored: { String(get(prefs.virtualSlot(slot))) },
      commit: { text in
        // 320 floors the value at something a desktop fits on. The engine
        // still normalizes to even and clamps to the pixel ceiling on create.
        guard let value = Int(text), (320 ... 8192).contains(value) else { return }
        var updated = prefs.virtualSlot(slot)
        set(&updated, value)
        prefs.setVirtualSlot(updated, slot: slot)
        actions.prefDidChange(name)
      },
      fieldLabel: Text("Display \(slot) \(label.lowercased())"),
      width: 70
    )
  }

  @ViewBuilder
  private func actionRow(slot: Int, definition: VirtualSlotDefinition, live: VirtualDisplayHandle?) -> some View {
    let drifted = live.map { $0.spec != definition.spec.normalized } ?? false
    let busy = model.virtualSlotBusy.contains(slot)
    HStack(spacing: 8) {
      if live == nil {
        // A tile with no running display: the create failed (the status row
        // says why) or the last session ended without come-back-at-launch.
        // Create and Apply are the same write through the same path and never
        // appear together, so they share one identifier.
        Button("Create Display") { setConfigured(true, slot: slot) }
          .buttonStyle(SettingsPrimaryButtonStyle())
          .accessibilityIdentifier("action.slotApply.\(slot)")
      } else if drifted {
        // VD1/VD17: the apply path is destroy-and-recreate under the same
        // slot, so the button names that rather than acting on the field edit.
        Button("Apply and Recreate") { setConfigured(true, slot: slot) }
          .buttonStyle(SettingsPrimaryButtonStyle())
          .accessibilityIdentifier("action.slotApply.\(slot)")
      }
      Spacer(minLength: 16)
      Button("Remove Display") { remove(slot: slot) }
        .buttonStyle(SettingsDangerButtonStyle())
        .accessibilityIdentifier("action.slotRemove.\(slot)")
    }
    .padding(.vertical, 8)
    .disabled(busy)
  }

  private func setConfigured(_ configured: Bool, slot: Int) {
    var updated = prefs.virtualSlot(slot)
    updated.configured = configured
    var names: [PrefName] = [.virtualSlotConfigured]
    if configured, updated.uuid == nil {
      // VD9: minted once, on first configure; survives recreate and relaunch.
      updated.uuid = UUID()
      names.append(.virtualSlotUUID)
    }
    prefs.setVirtualSlot(updated, slot: slot)
    // The batch, never a representative name; the slot scopes the
    // convergence to this write (VD17).
    actions.prefsDidChange(names, virtualSlot: slot)
  }

  /// Unconfigure FIRST, so the convergence destroys the display from a snapshot
  /// that still described it (`syncVirtualDisplays` snapshots synchronously
  /// inside the fan-out). Only then clear the stored keys.
  private func remove(slot: Int) {
    var updated = prefs.virtualSlot(slot)
    updated.configured = false
    updated.defined = false
    prefs.setVirtualSlot(updated, slot: slot)
    actions.prefsDidChange([.virtualSlotConfigured, .virtualSlotDefined], virtualSlot: slot)
    prefs.clearVirtualSlot(slot)
    if selectedSlot == slot { selectedSlot = nil }
  }

  private func binding(
    slot: Int, name: PrefName,
    keyPath: WritableKeyPath<VirtualSlotDefinition, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { prefs.virtualSlot(slot)[keyPath: keyPath] },
      set: { newValue in
        var updated = prefs.virtualSlot(slot)
        updated[keyPath: keyPath] = newValue
        prefs.setVirtualSlot(updated, slot: slot)
        actions.prefDidChange(name)
      }
    )
  }
}

/// The display that is not there yet: a dashed outline with a plus, accent
/// tinted so it reads as an invitation rather than an error.
///
/// It owns its hover state because the cue is INSIDE the drawing. A dashed
/// placeholder is the one tile here that reads as an empty-slot indicator, so
/// the affordance has to be the outline and glyph lifting, which no wrapper or
/// `ButtonStyle` can reach.
///
/// Scale is skipped under Reduce Motion and the shadow deepens either way, so a
/// non-moving cue is always there. The tint changes opacity on colours the tile
/// already draws, so it survives an unfocused window as a system accent would
/// not.
private struct GhostDisplayTile: View {
  var accent: Color
  var isHero: Bool

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      let bounds = proxy.size
      let standHeight = isHero ? bounds.height * 0.11 : 0
      let baseHeight = isHero ? 3.0 : 0
      let shape = RoundedRectangle(cornerRadius: isHero ? 12 : 6, style: .continuous)
      VStack(spacing: 0) {
        ZStack {
          shape.fill(accent.opacity(hovering ? 0.13 : 0.06))
          shape.strokeBorder(
            accent.opacity(hovering ? 0.75 : 0.4),
            style: StrokeStyle(lineWidth: 1, dash: [7, 6]))
          VStack(spacing: isHero ? 8 : 3) {
            Image(systemName: "plus")
              .font(.system(size: isHero ? 30 : 16, weight: .light))
            Text("Add Display")
              .font(.system(size: isHero ? 13 : 10))
          }
          .foregroundStyle(accent.opacity(hovering ? 1 : 0.8))
        }
        .frame(height: max(1, bounds.height - standHeight - baseHeight))
        if isHero {
          Rectangle()
            .fill(accent.opacity(hovering ? 0.34 : 0.24))
            .frame(width: 14, height: standHeight)
          Capsule()
            .fill(accent.opacity(hovering ? 0.3 : 0.2))
            .frame(width: bounds.width * 0.24, height: baseHeight)
        }
      }
    }
    // A render transform, so the row does not reflow around a hovered tile.
    .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
    .shadow(color: .black.opacity(hovering ? 0.28 : 0), radius: 8, y: 3)
    .onHover { hovering = $0 }
    .animation(SettingsTheme.hoverMotion, value: hovering)
  }
}
