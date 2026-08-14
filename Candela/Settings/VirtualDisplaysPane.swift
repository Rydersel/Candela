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
/// Only the `virtualSlotConfigured` write converges live displays (VD14);
/// field edits are inert until Create or Apply, and the captions say so
/// (VD17).
@MainActor
struct VirtualDisplaysPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  /// Which slot the controls below describe, chosen on the tile row the way
  /// the arrangement map chooses a display.
  @State private var selectedSlot = 1

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    let _ = model.prefsRevision
    Form {
      if model.virtualDisplays.isAvailable {
        introSection
        selectorSection
        slotSection(selectedSlot)
      } else {
        unavailableSection
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Slot selector

  /// The three slots as display tiles, the arrangement map's visual language:
  /// a running slot is a purple (virtual) tile carrying its achieved size, a
  /// not-created slot is an empty grey one. Clicking a tile selects the slot
  /// the controls below describe.
  private var selectorSection: some View {
    Section {
      HStack(spacing: 14) {
        ForEach(Array(VirtualDisplayIdentity.slotRange), id: \.self) { slot in
          slotTile(slot)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 6)
    }
  }

  @ViewBuilder private func slotTile(_ slot: Int) -> some View {
    let definition = prefs.virtualSlot(slot)
    let running = liveHandle(slot: slot) != nil
    let achieved = model.virtualDisplays.achievedMode(slot: slot)
    let status = achieved.map { "\(String($0.width)) x \(String($0.height))" } ?? "Not created"
    // The tile keeps the slot's configured shape so the row previews what
    // Create will make; a uniform height keeps the row from jumping as
    // definitions change.
    let height = 76.0
    let width = min(150, max(96, height * Double(definition.width) / Double(max(1, definition.height))))
    DisplayTile(
      name: definition.name,
      pointSize: status,
      mirroredCount: 0,
      isMain: false,
      isSelected: selectedSlot == slot,
      isFocused: false,
      isInvalid: false,
      isDragging: false,
      isVirtual: running,
      labels: TileLabelStyle(detail: .nameAndSize, nameSize: 11, showsMirrored: false)
    )
    .frame(width: width, height: height)
    .contentShape(RoundedRectangle(cornerRadius: 5))
    .onTapGesture { selectedSlot = slot }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(definition.name), \(running ? "running at \(status)" : "not created")"))
    .accessibilityAddTraits(selectedSlot == slot ? [.isButton, .isSelected] : [.isButton])
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
    Section("Virtual Displays") {
      // VD16: the class family resolved to nothing on this macOS, so every
      // entry point is inert and the pane says why instead of showing dead
      // controls.
      Text("Virtual displays are unavailable on this version of macOS.")
        .foregroundStyle(.secondary)
    }
  }

  private func liveHandle(slot: Int) -> VirtualDisplayHandle? {
    model.virtualDisplays.live().first { $0.slot == slot }
  }

  @ViewBuilder
  private func slotSection(_ slot: Int) -> some View {
    let definition = prefs.virtualSlot(slot)
    let live = liveHandle(slot: slot)
    Section("Display \(slot)") {
      statusRow(slot: slot, live: live)
      nameRow(slot: slot, definition: definition)
      sizeRows(slot: slot, definition: definition)
      SettingRow("The display is created again the next time \(AppInfo.productName) opens.") {
        Toggle("Come Back at Launch", isOn: binding(slot: slot, definition: definition,
                                                    name: .virtualSlotRecreateAtLaunch,
                                                    keyPath: \.recreateAtLaunch))
      }
      actionRow(slot: slot, definition: definition, live: live)
    }
  }

  private func statusRow(slot: Int, live: VirtualDisplayHandle?) -> some View {
    HStack {
      Text("Status")
      Spacer()
      if live != nil, let achieved = model.virtualDisplays.achievedMode(slot: slot) {
        // ACHIEVED state, read from the live topology, never the spec's
        // claim: the Retina suffix appears only when the 2x mode actually
        // engaged. `String(_:)` verbatim, or interpolation groups the digits
        // (1,920 x 1,080).
        Text("Running at \(String(achieved.width)) x \(String(achieved.height))\(achieved.hiDPI ? " (Retina)" : "")")
          .foregroundStyle(.secondary)
      } else if live != nil {
        Text("Running").foregroundStyle(.secondary)
      } else {
        Text("Not created").foregroundStyle(.secondary)
      }
    }
  }

  private func nameRow(slot: Int, definition: VirtualSlotDefinition) -> some View {
    SettingRow("The name shows in System Settings and in screen sharing lists.") {
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

  /// The preset list covers the common cases; Custom exposes the fields. A
  /// 4K preset is deliberately present so a slot can stand in for a 4K
  /// display during testing.
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
    if presetIndex == nil {
      SettingRow {
        HStack {
          Text("Width")
          Spacer()
          numberField(slot: slot, label: "Width", name: .virtualSlotWidth,
                      get: { $0.width }, set: { $0.width = $1 })
          Text("x").foregroundStyle(.secondary)
          numberField(slot: slot, label: "Height", name: .virtualSlotHeight,
                      get: { $0.height }, set: { $0.height = $1 })
        }
      }
    }
    SettingRow("A Retina display renders text at double resolution and halves the workspace per pixel.") {
      Toggle("Retina (HiDPI)", isOn: binding(slot: slot, definition: definition,
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
        // still normalizes to even on create.
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
    HStack(spacing: 8) {
      if live == nil {
        Button("Create Display") { setConfigured(true, slot: slot) }
      } else {
        if drifted {
          // VD1/VD17: the apply path is destroy-and-recreate under the same
          // slot, and the button says what will happen rather than doing it
          // on the field edit.
          Button("Apply and Recreate") { setConfigured(true, slot: slot) }
        }
        Button("Remove Display") { setConfigured(false, slot: slot) }
      }
    }
  }

  private func setConfigured(_ configured: Bool, slot: Int) {
    var updated = prefs.virtualSlot(slot)
    updated.configured = configured
    if configured, updated.uuid == nil {
      // VD9: minted once, on first configure; survives recreate and relaunch.
      updated.uuid = UUID()
    }
    prefs.setVirtualSlot(updated, slot: slot)
    actions.prefDidChange(.virtualSlotConfigured)
  }

  private func binding(
    slot: Int, definition: VirtualSlotDefinition, name: PrefName,
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
