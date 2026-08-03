import AppKit
import CandelaKit
import SwiftUI

/// Control-Center-style menu-bar panel: one titled section per display
/// (13 pt semibold secondary header above a full-width capsule slider), a
/// hairline separator, and a footer row with app-level actions. The built-in
/// panel, when present, gets the first section (built-in-first ordering lives
/// here in the view — `model.displays` stays external-only). Layout metrics
/// (280 pt width, 14 pt content insets) match the fork's MenuLayout.
struct PanelView: View {
  @Environment(AppModel.self) private var model

  /// At most one display's resolution list is open at a time, and it collapses
  /// when the menu closes so the panel never reopens taller than it needs.
  @State private var expandedResolution: CGDirectDisplayID?

  var body: some View {
    // Prefs are plain UserDefaults, not observable. Touching prefsRevision
    // here is what re-renders the panel after a settings pane (or a
    // drag-removal) writes a panel-visible pref — the M5 live-observation
    // contract from the T2 seam.
    let _ = model.prefsRevision
    let externals = Self.visibleDisplays(model)
    let showsBuiltIn = Self.showsBuiltIn(model)
    // One read per render, like every other panel pref; `prefsRevision`
    // (touched above) re-renders after the App menu pane writes them.
    let appPrefs = DisplayPrefs(persistenceKey: "app")
    let snapsToStops = appPrefs.enableSliderSnap
    let showsPercent = appPrefs.enableSliderPercent
    VStack(spacing: 0) {
      // Task 12 hand-off: the same predicate as the Keyboard pane's warning
      // row, never a bare `!isGranted` — an all-custom-shortcut rig needs no
      // grant, and the two surfaces must not disagree about that.
      if model.accessibility.isWarningWarranted {
        accessibilityBanner
        Divider()
      }
      VStack(alignment: .leading, spacing: 14) {
        if externals.isEmpty, !showsBuiltIn {
          emptyState
        }
        if showsBuiltIn, let builtIn = model.builtIn {
          // Name header only — no HDR badge/menu chrome: the built-in never
          // routes HDR (role .builtIn), and the section stays as quiet as
          // Control Center keeps its module headers. The slider drives the
          // native path, so Control Center's own slider follows live.
          let name = Self.title(for: builtIn.display)
          VStack(alignment: .leading, spacing: 8) {
            Text(name)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .accessibilityHidden(true) // the slider carries the display name
            DisplaySliderRow(
              controller: builtIn.controller, displayName: name,
              snapsToStops: snapsToStops, showsPercent: showsPercent
            )
          }
        }
        ForEach(externals) { state in
          let name = Self.title(for: state.display)
          VStack(alignment: .leading, spacing: 8) {
            DisplayHeaderRow(controller: state.controller, displayName: name)
            DisplaySliderRow(
              controller: state.controller, displayName: name,
              snapsToStops: snapsToStops, showsPercent: showsPercent
            )
            if showsVolumeSlider(for: state) {
              let volumeEnabled = model.volumeSliderEnabled(state)
              ValueSliderRow(
                controller: state.volume,
                systemImage: "speaker.wave.2.fill",
                // T5's friendly-name local — NOT `state.display.name`. A
                // renamed display must announce one name in every row of its
                // section, tooltips included.
                accessibilityLabel: "\(name) volume",
                // T6's non-defaulted options. They have no defaults on
                // `ValueSliderRow`; dropping them is a compile error, and
                // "fixing" that by giving them defaults silently disables
                // snapping and the percent readout on every volume slider.
                snapsToStops: snapsToStops,
                showsPercent: showsPercent,
                // Also what makes this row zero-free: `ValueSliderRow` derives
                // `snapsToZero: !mutesAtZero` from this glyph's presence, and a
                // muting row must never snap to 0 (D29 — a snapped-to-zero
                // volume hardware-mutes the display over VCP 0x8D). Dropping
                // the glyph re-arms that hazard with no compile error.
                mutedSystemImage: "speaker.slash.fill"
              )
              .disabled(!volumeEnabled)
              // The reason changed with the signal: this is the monitor
              // declining the feature, not macOS failing to find a speaker.
              .help(volumeEnabled ? "" : "\(name) reports no volume control over DDC")
            }
            if showsContrastSlider(for: state) {
              ValueSliderRow(
                controller: state.contrast,
                systemImage: "circle.lefthalf.filled",
                accessibilityLabel: "\(name) contrast",
                snapsToStops: snapsToStops,
                showsPercent: showsPercent
              )
            }
            PanelResolutionSection(
              displayID: state.id,
              displayName: name,
              coordinator: model.displayModes,
              expandedDisplayID: $expandedResolution
            )
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      footer
    }
    .frame(width: 280)
    // The menu can close without a mouse-exit event, and it takes the panel's
    // view hierarchy with it — the same signal the hover fixes below rely on.
    .onDisappear { expandedResolution = nil }
  }

  // MARK: - What the panel renders
  //
  // These three are `static` and non-private on purpose: StatusItemController
  // asks the SAME question to decide `.sliderOnly` menu-bar visibility (D5),
  // and a second copy of the rule there would drift.

  /// Externals the panel renders: per-display hide applied, then ascending
  /// order by friendly-or-hardware name (D7). One call, so the filter cannot
  /// be discarded by the sort the way the fork's is (D2 bug 1).
  ///
  /// `@MainActor` explicitly: `View` is not a globally-isolated protocol — only
  /// `body` is — so a bare `static func` here would be nonisolated and reading
  /// `AppModel.displays` from it is an isolation violation under
  /// `SWIFT_STRICT_CONCURRENCY: complete`.
  @MainActor
  static func visibleDisplays(_ model: AppModel) -> [AppModel.DisplayState] {
    DisplayOrdering.panelOrder(
      model.displays,
      isHidden: { DisplayPrefs(persistenceKey: $0.display.persistenceKey).hideDisplay },
      title: { title(for: $0.display) }
    )
  }

  /// The built-in section, behind the app-level toggle. This is Candela's
  /// working version of the fork's `hideAppleFromMenu`, whose filter had no
  /// runtime effect at all (D2 bug 1). `@MainActor` for the same reason as
  /// `visibleDisplays` — it reads `AppModel`.
  @MainActor
  static func showsBuiltIn(_ model: AppModel) -> Bool {
    model.builtIn != nil && !DisplayPrefs(persistenceKey: "app").hideBuiltInDisplay
  }

  /// The name every part of the panel shows for a display — header, slider
  /// accessibility label, and tooltips all go through this one call, so a
  /// rename in the Displays pane (T13) moves all of them together.
  static func title(for display: ExternalDisplay) -> String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: display.persistenceKey).friendlyName,
      hardwareName: display.name
    )
  }

  /// Two different empties, said differently: "nothing is attached" is a fact
  /// about the hardware, "you hid everything" is a state the user can undo —
  /// and it must say where (design guidance: help people recover).
  private var emptyState: some View {
    VStack(spacing: 4) {
      if model.displays.isEmpty, model.builtIn == nil {
        Text("No controllable displays")
      } else {
        Text("Every display is hidden")
        Text("Show one again in Settings → Displays.")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
  }

  // MARK: - Slider visibility
  //
  // Only `model.displays` (external) ever gets value rows: the built-in slot's
  // volume/contrast controllers are inert placeholders on a `NoopDDCWriter`
  // whose `isAvailable` is nonetheless true (T10 concern 6), so rendering them
  // would show a live-looking slider that does nothing.
  //
  // Prefs are plain UserDefaults, not observable: the panel re-evaluates them
  // on every menu open (the M4 contract) and, since M5, whenever
  // `AppModel.prefsRevision` bumps — which the T2 seam does on every
  // panel-visible pref write.

  /// D2: volume slider per DDC display, unless hidden per display, disabled
  /// per command, or `forceSoftware` — all three fork conjuncts (fork
  /// MenuHandler: `!isSw + !unavailableDDC + !hideVolume`; review R5). The
  /// last two are exactly `DDCValueController.isAvailable`, and reusing it is
  /// deliberate: it is the same gate `setValue` self-gates on, so a visible
  /// slider can never be a silently dead one.
  ///
  /// Distinct from the volume-capability gate (`AppModel.volumeSliderEnabled`),
  /// which DISABLES the row instead of removing it: that display has a volume
  /// register the app is willing to write, and greying says "this monitor says
  /// it does not implement volume", while these conjuncts mean the control does
  /// not apply here at all.
  private func showsVolumeSlider(for state: AppModel.DisplayState) -> Bool {
    let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
    return state.volume.isAvailable && !prefs.hideVolumeSlider
  }

  /// D2: contrast slider behind the app-level `showContrast` pref (default
  /// false, fork parity), never for a disabled command, never for a
  /// `forceSoftware` display (fork stepContrast/menu: `!isSw()`, R5 — the
  /// latter two again via `isAvailable`).
  private func showsContrastSlider(for state: AppModel.DisplayState) -> Bool {
    let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
    return prefs.showContrast && state.contrast.isAvailable
  }

  /// Visually quiet Accessibility banner (spec §6: banner, not alert):
  /// 13 pt secondary text with a small trailing link button, matching the
  /// panel's section typography so it reads as information, not alarm. Shown
  /// only while the grant is missing AND a key mode actually wants it; appears
  /// and clears live via observation, in both directions, because
  /// `AccessibilityPermission` observes for the app's lifetime (D9) — a
  /// revoked grant (every ad-hoc re-sign) brings this back with no relaunch.
  private var accessibilityBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Text("Keyboard control needs Accessibility access")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button("Open Settings…") {
        AccessibilityPermission.openSystemSettings()
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
      .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  /// Both actions carry a word.
  ///
  /// The quit control used to be a bare `xmark.circle`, and an ✕ inside a
  /// popover means "dismiss this popover" everywhere else in macOS — so the
  /// one control that terminates the app wore the universal symbol for closing
  /// the transient window it lives in. With the menu bar icon hidden there is
  /// no Dock tile to relaunch from, which makes that misfire expensive.
  ///
  /// Settings stays at the bottom deliberately: the system's own Wi-Fi, Sound
  /// and Display menu-bar panels all end with a settings row, and diverging
  /// from that purely to differ from the fork would trade a real convention
  /// for a cosmetic distinction.
  private var footer: some View {
    HStack(spacing: 0) {
      FooterPillButton(systemImage: "gearshape", title: "Settings…") {
        SettingsOpener.open()
      }
      Spacer(minLength: 8)
      // Trailing, so the destructive action is furthest from where the pointer
      // rests after dragging a slider.
      FooterPillButton(systemImage: "power", title: "Quit") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 32)
  }
}

/// Section header for one display: name, an "HDR" state badge, and a trailing
/// HDR-mode toggle button. Everything is secondary-colored — the slider is
/// the row's only emphasis, the way Control Center keeps section chrome quiet.
///
/// Badge and button report two different things on purpose: the badge is
/// STATE (is HDR live right now, however it got there), the button is POLICY
/// (which mode the user picked). They disagree legitimately — externally
/// toggled HDR badges while the mode still reads "HDR Off".
private struct DisplayHeaderRow: View {
  let controller: BrightnessController
  let displayName: String

  @State private var isHovering = false

  private var modeLabel: String {
    switch controller.hdrMode {
    case .off: return "HDR Off"
    case .alwaysOn: return "HDR On"
    }
  }

  private var nextMode: HDRMode {
    controller.hdrMode == .off ? .alwaysOn : .off
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(displayName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityHidden(true)  // the slider carries the display name
      if controller.isHDREngaged {
        Text("HDR")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary))
          .accessibilityLabel("HDR engaged")
      }
      Spacer(minLength: 4)
      hdrModeButton
    }
  }

  /// Cycling control, not a menu: the panel is hosted in an `NSMenu` item, and
  /// a SwiftUI `Menu` inside that never opens — the enclosing menu owns event
  /// tracking, so the nested one is dead on arrival (hardware round 1). Plain
  /// buttons in the panel do work (the footer's quit button), so the mode
  /// toggles Off ↔ On on click. The label always names the CURRENT mode,
  /// matching the menu-bar guidance to keep control titles short and
  /// state-revealing; the tooltip carries the "toggles" affordance.
  private var hdrModeButton: some View {
    Button {
      Task { await controller.setHDRMode(nextMode) }
    } label: {
      Text(modeLabel)
        .font(.system(size: 12))
    }
    .buttonStyle(HDRModeButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // The menu can close without a mouse-exit event (Escape, or clicking the
    // status item), which would leave a phantom highlight on the next open.
    .onDisappear { isHovering = false }
    .fixedSize()
    // Disable, don't hide, on non-HDR displays (design guidance: keep
    // controls visible so people learn what the app supports). `supportsHDR`
    // is observation-tracked, so the button enables live once the async
    // capability refresh lands.
    .disabled(!controller.supportsHDR)
    .help("Toggle HDR for \(displayName)")
    .accessibilityLabel("\(displayName) HDR mode")
    .accessibilityValue(modeLabel)
  }
}

/// Same hover/press feedback language as `FooterIconButtonStyle`, with text
/// metrics instead of a square icon frame.
private struct HDRModeButtonStyle: ButtonStyle {
  let isHovering: Bool
  // Backlog #10: the style must read enablement itself — a disabled button
  // previously rendered live (hover fill, primary text) and just did nothing.
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let hovering = isHovering && isEnabled
    let background: AnyShapeStyle = if configuration.isPressed, isEnabled {
      AnyShapeStyle(.tertiary)
    } else if hovering {
      AnyShapeStyle(.quaternary)
    } else {
      AnyShapeStyle(.clear)
    }
    let foreground: HierarchicalShapeStyle = if !isEnabled {
      .quaternary
    } else if hovering {
      .primary
    } else {
      .secondary
    }
    return configuration.label
      .foregroundStyle(foreground)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

/// Bridges the controller (source of truth) to the slider's binding.
/// setBrightness is synchronous and coalesces hardware writes, so drag
/// streams are safe to feed directly.
private struct DisplaySliderRow: View {
  let controller: BrightnessController
  let displayName: String
  let snapsToStops: Bool
  let showsPercent: Bool

  var body: some View {
    CandelaSlider(
      value: Binding(
        get: { controller.brightness },
        set: { controller.setBrightness($0) }
      ),
      accessibilityLabel: "\(displayName) brightness",
      snapsToStops: snapsToStops,
      showsPercent: showsPercent
    )
  }
}

/// Volume/contrast row: the same capsule slider as brightness, one visual
/// language for every value in the section.
///
/// Muted volume renders as 0 with a slashed speaker — `isMuted` and a genuine
/// value of 0 are distinct states (T10 handoff) and the icon is what tells
/// them apart, since the knob sits at the leading edge either way. The stored
/// value survives being muted: dragging up from 0 unmutes and lands on the
/// dragged value through the controller's mute-companion logic.
private struct ValueSliderRow: View {
  let controller: DDCValueController
  let systemImage: String
  let accessibilityLabel: String
  let snapsToStops: Bool
  let showsPercent: Bool
  /// Substituted while muted; nil for commands that never mute (contrast).
  var mutedSystemImage: String?

  /// Volume is the command whose 0 means "mute". Having a muted glyph IS the
  /// definition of that here — contrast has none and never mutes.
  private var mutesAtZero: Bool { mutedSystemImage != nil }
  private var isMuted: Bool { controller.isMuted && mutesAtZero }

  var body: some View {
    CandelaSlider(
      value: Binding(
        get: { isMuted ? 0 : controller.value },
        set: { controller.setValue($0) }
      ),
      systemImage: isMuted ? (mutedSystemImage ?? systemImage) : systemImage,
      accessibilityLabel: isMuted ? "\(accessibilityLabel), muted" : accessibilityLabel,
      snapsToStops: snapsToStops,
      // D29: never let snapping pull a volume drag onto 0, which the engine
      // treats as a hardware mute (VCP 0x8D). Contrast keeps the 0 stop.
      snapsToZero: !mutesAtZero,
      showsPercent: showsPercent
    )
  }
}

/// Footer action button: a symbol and a word on a subtle rounded background
/// that appears on hover, with a distinct pressed state.
///
/// Replaced the icon-only `FooterIconButton` when the quit control gained a
/// label; nothing in the footer is icon-only any more, so that type is gone.
///
/// `power` means "shut down" on macOS, so on the quit button the WORD carries
/// the meaning and the symbol is only there to balance the gear opposite it.
private struct FooterPillButton: View {
  let systemImage: String
  let title: LocalizedStringKey
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .medium))
        Text(title)
          .font(.system(size: 12))
      }
      .padding(.horizontal, 8)
      .frame(height: 22)
    }
    .buttonStyle(FooterIconButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // Same phantom-hover fix as FooterIconButton: the menu can close without a
    // trailing mouse-exit event (Escape, or clicking the status item), which
    // would leave a stuck highlight on the next open.
    .onDisappear { isHovering = false }
  }
}

private struct FooterIconButtonStyle: ButtonStyle {
  let isHovering: Bool
  // Backlog #10, same treatment as HDRModeButtonStyle.
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let hovering = isHovering && isEnabled
    let background: AnyShapeStyle = if configuration.isPressed, isEnabled {
      AnyShapeStyle(.tertiary)
    } else if hovering {
      AnyShapeStyle(.quaternary)
    } else {
      AnyShapeStyle(.clear)
    }
    let foreground: HierarchicalShapeStyle = if !isEnabled {
      .quaternary
    } else if hovering {
      .primary
    } else {
      .secondary
    }
    return configuration.label
      .foregroundStyle(foreground)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}
