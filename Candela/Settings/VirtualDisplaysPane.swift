import CandelaKit
import CoreGraphics
import SwiftUI

/// Management for the three virtual display slots (VD2): creation is a
/// deliberate, occasional act, so it lives here and nowhere else. A virtual
/// display never gets a menu bar row or a per-display destination; it has no
/// DDC and no brightness, and macOS itself handles its arrangement and
/// scaling once it exists.
///
/// Every write goes through `SettingsActions` with a `PrefName` case (D27).
/// Only the `virtualSlotConfigured` write converges live displays (VD14),
/// scoped to the written slot so one slot's Create never applies another
/// slot's pending edits (VD17); field edits are inert until Create or Apply,
/// and the captions say so.
@MainActor
struct VirtualDisplaysPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Which slot the controls below describe, chosen on the tile row the way
  /// the arrangement map chooses a display. nil until something is added or
  /// clicked; the effective selection falls back to the first added slot.
  @State private var selectedSlot: Int?

  /// The selected slot's create failure as RENDERED, mirroring
  /// `AppModel.virtualSlotIssues` one update behind. The model writes that map
  /// from the convergence pass, and neither placement of a keyed `.animation`
  /// fades a `Form` row symmetrically (measured 2026-08-17): on a `Group`
  /// wrapping the conditional row it animates nothing in either direction, and on
  /// an always-present container inside the row the child fades IN and then SNAPS
  /// out. That snap-out asymmetry is why hanging the animation on the container
  /// is not enough; the mirror puts the sentence's arrival AND departure inside
  /// one transaction.
  ///
  /// It carries the SLOT it is about, and the row renders nothing unless the two
  /// agree: one value serves whichever slot is selected, and without the slot a
  /// switch would show the previous slot's failure until the sync landed.
  @State private var shownIssue: ShownIssue?

  private struct ShownIssue: Equatable {
    var slot: Int
    var failure: VirtualDisplayFailure?
  }

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  /// Slots the user has ADDED, in slot order: these have tiles whether or
  /// not a display is currently running.
  private var definedSlots: [Int] {
    VirtualDisplayIdentity.userSlotRange.filter { prefs.virtualSlot($0).defined }
  }

  private func effectiveSelection(in defined: [Int]) -> Int? {
    if let selectedSlot, defined.contains(selectedSlot) { return selectedSlot }
    return defined.first
  }

  var body: some View {
    let _ = model.prefsRevision
    let defined = definedSlots
    Form {
      if model.virtualDisplays.isAvailable {
        introSection
        selectorSection(defined: defined)
        if let slot = effectiveSelection(in: defined) {
          slotSection(slot)
            // Identity, not decoration: without it SwiftUI reuses ONE text
            // field instance across a slot change, and an uncommitted draft
            // then commits into the slot the user just switched TO. With it,
            // switching slots removes the old fields, whose on-disappear
            // commit still holds the OLD slot's closures, which is the
            // correct place for the draft to land.
            .id(slot)
        }
      } else {
        unavailableSection
      }
    }
    .formStyle(.grouped)
  }

  private var introSection: some View {
    Section {
      SettingRow(
        "A virtual display behaves like a connected display: windows move to it, it appears in arrangement, and it can be shared or recorded."
      ) {
        Text("Up to three virtual displays can run at once.")
      }
      if model.isSafeMode {
        SettingRow {
          Text("Safe Mode session: displays marked to come back at launch were not recreated. Create still works here.")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var unavailableSection: some View {
    // VD16: the class family resolved to nothing on this macOS, so every
    // entry point is inert and the pane says why instead of showing dead
    // controls. No section header: the pane's toolbar title already reads
    // "Virtual Displays", and repeating it is the duplicated-title defect.
    Section {
      Text("Virtual displays are unavailable on this version of macOS.")
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Slot selector

  /// One tile per ADDED display, the arrangement map's visual language: a
  /// running slot is a purple (virtual) tile carrying its achieved size, a
  /// stopped one an empty grey tile. A dashed Add tile follows while free
  /// slots remain. Real buttons, so the keyboard and VoiceOver can reach
  /// every tile the way the arrangement canvas's tiles can be reached.
  private func selectorSection(defined: [Int]) -> some View {
    Section {
      HStack(spacing: 14) {
        let selection = effectiveSelection(in: defined)
        ForEach(defined, id: \.self) { slot in
          slotTile(slot, isSelected: selection == slot)
        }
        if let free = VirtualDisplayIdentity.userSlotRange.first(where: { !defined.contains($0) }) {
          addTile(slot: free, isFirst: defined.isEmpty)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 6)
    }
  }

  /// Adds the lowest free slot: definition with the slot defaults, created
  /// immediately, and selected so its controls appear below.
  @ViewBuilder private func addTile(slot: Int, isFirst: Bool) -> some View {
    Button {
      var definition = prefs.virtualSlot(slot)
      definition.defined = true
      definition.configured = true
      definition.uuid = UUID()
      prefs.setVirtualSlot(definition, slot: slot)
      selectedSlot = slot
      // The batch, never a representative name, and the slot scopes the
      // convergence to this write (VD17).
      actions.prefsDidChange(
        [.virtualSlotDefined, .virtualSlotConfigured, .virtualSlotUUID], virtualSlot: slot
      )
    } label: {
      VStack(spacing: 4) {
        Image(systemName: "plus")
        Text("Add Display").font(.system(size: 10))
      }
      .foregroundStyle(.secondary)
      .frame(width: isFirst ? 135 : 96, height: 76)
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      )
      .contentShape(RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Add a virtual display"))
  }

  /// The tile's one-line status, shared by the picture and VoiceOver so the
  /// two can never disagree: achieved size while running (never the spec's
  /// claim), a bare "Running" when no verdict was recorded for the slot, and
  /// "Not created" otherwise.
  ///
  /// `achievedMode` is the host's RECORDED verdict from creation, not a read of
  /// the live topology: this process usually cannot read a display it created.
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
    // The tile keeps the slot's configured shape so the row previews what
    // Create will make; a uniform height keeps the row from jumping as
    // definitions change.
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
    Section("Display \(slot)") {
      statusRow(slot: slot, live: live)
      nameRow(slot: slot)
      sizeRows(slot: slot, definition: definition)
      SettingRow("The display is created again the next time \(AppInfo.productName) opens.") {
        Toggle("Come Back at Launch", isOn: binding(slot: slot,
                                                    name: .virtualSlotRecreateAtLaunch,
                                                    keyPath: \.recreateAtLaunch))
      }
      actionRow(slot: slot, definition: definition, live: live)
    }
  }

  @ViewBuilder
  private func statusRow(slot: Int, live: VirtualDisplayHandle?) -> some View {
    let busy = model.virtualSlotBusy.contains(slot)
    // The four states below are a branch swap around a `ProgressView`, not an
    // insert, so this row is left instant: fading a spinner into a sentence and
    // back is the one shape the house voice has no use for.
    HStack {
      Text("Status")
      Spacer()
      if busy {
        ProgressView().controlSize(.small)
        Text("Working").foregroundStyle(.secondary)
      } else if live != nil, let achieved = model.virtualDisplays.achievedMode(slot: slot) {
        // ACHIEVED state, never the spec's claim: the Retina suffix appears
        // only when the 2x mode actually engaged. From the host's verdict
        // recorded at creation rather than a live read, which this process
        // usually cannot perform on a display it created. `String(_:)`
        // verbatim, or interpolation groups the digits (1,920 x 1,080).
        Text("Running at \(String(achieved.width)) x \(String(achieved.height))\(achieved.hiDPI ? " (Retina)" : "")")
          .foregroundStyle(.secondary)
      } else if live != nil {
        Text("Running").foregroundStyle(.secondary)
      } else {
        Text("Not created").foregroundStyle(.secondary)
      }
    }
    // The failure row's mirror hooks hang on the status row, which is always
    // present and sits directly above it: hooks on the failure row itself would
    // only exist while the failure does, so nothing would be watching for it to
    // arrive. The appear sync is un-animated, and it re-runs on a slot change
    // because `slotSection` carries the slot as its identity.
    .onAppear { shownIssue = ShownIssue(slot: slot, failure: visibleIssue(slot: slot)) }
    .onChange(of: visibleIssue(slot: slot)) { _, issue in
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) {
        shownIssue = ShownIssue(slot: slot, failure: issue)
      }
    }
    if let shown = shownIssue, shown.slot == slot, let issue = shown.failure {
      // The last attempt's failure, in words: a create that fails must not
      // be indistinguishable from a click that was ignored.
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Image(systemName: "exclamationmark.triangle.fill")
        Text(verbatim: Self.sentence(for: issue))
      }
      .font(.callout)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
      .transition(.opacity)
    }
  }

  /// The failure this slot's status row should be showing, or nil: what the
  /// mirror follows. While the slot is busy there is no sentence, so a failure
  /// that arrives mid-work fades in when the work ends rather than under the
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
      }
    }
  }

  /// Common sizes; the width and height fields BELOW the picker are always
  /// present, so a custom size is typed directly and the picker simply reads
  /// "Custom" whenever the fields diverge from every preset. The fields are
  /// never unmounted by a preset choice: removing them mid-edit would fire
  /// their on-disappear commit with a pre-choice draft and silently revert
  /// the preset.
  private static let presets: [(label: String, width: Int, height: Int)] = [
    ("1920 x 1080", 1920, 1080),
    ("2560 x 1440", 2560, 1440),
    ("3440 x 1440", 3440, 1440),
    ("3840 x 2160 (4K)", 3840, 2160),
  ]

  @ViewBuilder
  private func sizeRows(slot: Int, definition: VirtualSlotDefinition) -> some View {
    let presetIndex = Self.presets.firstIndex {
      $0.width == definition.width && $0.height == definition.height
    }
    SettingRow("Size changes apply when the display is next created.") {
      Picker("Size", selection: Binding(
        get: { presetIndex ?? -1 },
        set: { newIndex in
          // The Custom tag is a read-only state of the picker, not a choice:
          // typing in the fields below is what makes a size custom.
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
    SettingRow {
      HStack {
        Text("Width and Height")
        Spacer()
        numberField(slot: slot, label: "Width", name: .virtualSlotWidth,
                    get: { $0.width }, set: { $0.width = $1 })
        Text("x").foregroundStyle(.secondary)
        numberField(slot: slot, label: "Height", name: .virtualSlotHeight,
                    get: { $0.height }, set: { $0.height = $1 })
      }
    }
    SettingRow("Text renders at double resolution when the display is next created.") {
      Toggle("Retina (HiDPI)", isOn: binding(slot: slot,
                                             name: .virtualSlotHiDPI, keyPath: \.hiDPI))
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
        // 320 floors the value at something a desktop fits on; the engine
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
        // A tile with no running display: either its create failed (the
        // status row says why) or the last session ended without
        // come-back-at-launch. Create tries again; Remove drops the tile.
        Button("Create Display") { setConfigured(true, slot: slot) }
      } else if drifted {
        // VD1/VD17: the apply path is destroy-and-recreate under the same
        // slot, and the button says what will happen rather than doing it
        // on the field edit.
        Button("Apply and Recreate") { setConfigured(true, slot: slot) }
      }
      Button("Remove Display") { remove(slot: slot) }
    }
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
    // The batch, never a representative name, and the slot scopes the
    // convergence to this write (VD17).
    actions.prefsDidChange(names, virtualSlot: slot)
  }

  /// Remove takes the tile with the display: unconfigure FIRST so the
  /// convergence destroys the display from a snapshot that still described
  /// it (`syncVirtualDisplays` snapshots synchronously inside the fan-out
  /// below), then clear every stored key so the slot is free for a future
  /// Add.
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
