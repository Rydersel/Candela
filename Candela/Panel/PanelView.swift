import AppKit
import CandelaKit
import SwiftUI

/// Control-Center-style menu-bar panel, one section per display. Built-in-first
/// ordering lives here in the view; `model.displays` stays external-only.
struct PanelView: View {
  @Environment(AppModel.self) private var model

  /// One disclosure open at a time across the whole panel; more would push the
  /// footer off screen. Keyed by (display, section): keyed by display alone,
  /// opening one of a display's sections opens the other underneath it.
  @State private var expandedSection: PanelDisclosureID?

  /// The menu drops the view hierarchy on close, so onAppear re-fires on every
  /// open and the settle plays each time.
  @State private var hasEntered = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Prefs are plain UserDefaults, not observable. Touching prefsRevision is
    // what re-renders the panel after a pane writes a panel-visible pref.
    let _ = model.prefsRevision
    let externals = Self.visibleDisplays(model)
    let showsBuiltIn = Self.showsBuiltIn(model)
    let appPrefs = DisplayPrefs(persistenceKey: "app")
    let snapsToStops = appPrefs.enableSliderSnap
    let showsPercent = appPrefs.enableSliderPercent
    VStack(spacing: 0) {
      // Same predicate as the Keyboard pane's warning row, never a bare
      // `!isGranted`: an all-custom-shortcut rig needs no grant.
      if model.accessibility.isWarningWarranted {
        accessibilityBanner
        Divider()
      }
      VStack(alignment: .leading, spacing: 14) {
        if externals.isEmpty, !showsBuiltIn {
          emptyState
        }
        // Above the per-display sections so a disclosure below never crowds
        // the footer.
        let combined = CombinedBrightness.participants(
          builtIn: showsBuiltIn ? model.builtIn : nil, externals: externals,
          prefs: Self.standardPrefs)
        if CombinedBrightness.shows(participantCount: combined.count, appPrefs: appPrefs) {
          VStack(alignment: .leading, spacing: 8) {
            Text("All displays")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true) // the slider carries the name
            CombinedSliderRow(
              participants: combined, snapsToStops: snapsToStops, showsPercent: showsPercent)
          }
        }
        if showsBuiltIn, let builtIn = model.builtIn {
          // Name header only, no HDR chrome: the built-in never routes HDR
          // (role .builtIn). The slider drives the native path, so Control
          // Center's own slider follows live.
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
          let rowPrefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
          VStack(alignment: .leading, spacing: 8) {
            DisplayHeaderRow(
              controller: state.controller, displayName: name,
              // Asked of the engine that owns the pairing: a catalog refresh
              // inside an engage window answers "not engaged" with the mirror
              // already up.
              isShowingSynthesizedSize: model.synthesis.isEngaged(displayID: state.display.id),
              careLine: Self.careLine(for: state, model: model)
            )
            DisplaySliderRow(
              controller: state.controller, displayName: name,
              snapsToStops: snapsToStops, showsPercent: showsPercent
            )
            // Not greyed like the volume denial below; the slider still
            // dims in software. `staysLive` keeps the hover watcher off drags.
            .panelHoverReason(model.brightnessSliderCompactReason(state), staysLive: true)
            if Self.showsVolumeSlider(for: state, prefs: rowPrefs) {
              let volumeEnabled = model.volumeSliderEnabled(state)
              ValueSliderRow(
                controller: state.volume,
                systemImage: "speaker.wave.2.fill",
                // The friendly-name local, not `state.display.name`: a renamed
                // display announces one name in every row of its section.
                accessibilityLabel: "\(name) volume",
                // Non-defaulted on `ValueSliderRow` by design: giving them
                // defaults would silently disable snapping and the percent
                // readout on every volume slider.
                snapsToStops: snapsToStops,
                showsPercent: showsPercent,
                // `ValueSliderRow` derives `snapsToZero: !mutesAtZero` from
                // this glyph. Dropping it lets the row snap to 0, which
                // hardware-mutes the display over VCP 0x8D.
                mutedSystemImage: "speaker.slash.fill"
              )
              .disabled(!volumeEnabled)
              // The reason comes from the policy that decided, so it cannot
              // name a cause other than the one that applied. Hover, not
              // a tooltip: the panel delivers no tooltip anywhere.
              .panelHoverReason(model.volumeSliderCompactReason(state))
            }
            if Self.showsContrastSlider(for: state, prefs: rowPrefs) {
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
              expanded: $expandedSection
            )
            // Shares the expansion binding above: only one disclosure may be
            // open. On a single-display rig it must resolve to nothing rather
            // than draw nothing, or the VStack spacing reserves a gap for it.
            PanelMirroringSection(
              displayID: state.id,
              displayName: name,
              coordinator: model.mirroring,
              expanded: $expandedSection
            )
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      if Self.showsKeepAwake(appPrefs: appPrefs) {
        keepAwakeRow
        Divider()
      }
      footer
    }
    .frame(width: 280)
    // The offset draws outside layout, so the entrance reflows nothing; the
    // menu window clips the first frames.
    .opacity(hasEntered ? 1 : 0)
    .offset(y: hasEntered ? 0 : -6)
    .onAppear {
      withAnimation(Motion.entrance(reduceMotion: reduceMotion)) { hasEntered = true }
    }
    // The menu can close without a mouse-exit event and drops the view
    // hierarchy, so hasEntered re-arms here for the next open.
    .onDisappear {
      expandedSection = nil
      hasEntered = false
    }
  }

  // MARK: - What the panel renders
  //
  // Static and non-private because StatusItemController asks the same question
  // to decide `.sliderOnly` menu-bar visibility.

  /// Externals the panel renders: hide applied, then ascending by
  /// friendly-or-hardware name. One call, so the sort cannot discard the
  /// filter the way the fork's does.
  ///
  /// `@MainActor` explicitly: on `View` only `body` is isolated, so a bare
  /// `static func` would be nonisolated and could not read `AppModel.displays`
  /// under `SWIFT_STRICT_CONCURRENCY: complete`.
  @MainActor
  static func visibleDisplays(_ model: AppModel) -> [AppModel.DisplayState] {
    visibleDisplays(model.displays, prefs: standardPrefs)
  }

  /// The same derivation over plain inputs, so it can be asked what it renders
  /// without an `AppModel` or the app's own prefs domain.
  @MainActor
  static func visibleDisplays(
    _ states: [AppModel.DisplayState],
    prefs: (String) -> DisplayPrefs
  ) -> [AppModel.DisplayState] {
    DisplayOrdering.panelOrder(
      states,
      isHidden: { prefs($0.display.persistenceKey).hideDisplay },
      title: { title(for: $0.display, prefs: prefs) }
    )
  }

  /// The built-in section, behind the app-level toggle. Candela's working
  /// version of the fork's `hideAppleFromMenu`, whose filter never ran.
  /// `@MainActor` because it reads `AppModel`.
  @MainActor
  static func showsBuiltIn(_ model: AppModel) -> Bool {
    showsBuiltIn(hasBuiltIn: model.builtIn != nil, appPrefs: standardPrefs("app"))
  }

  static func showsBuiltIn(hasBuiltIn: Bool, appPrefs: DisplayPrefs) -> Bool {
    hasBuiltIn && !appPrefs.hideBuiltInDisplay
  }

  /// The one name source for a display, so a rename in the Displays pane moves
  /// the header and every accessibility label together.
  static func title(for display: ExternalDisplay) -> String {
    title(for: display, prefs: standardPrefs)
  }

  static func title(for display: ExternalDisplay, prefs: (String) -> DisplayPrefs) -> String {
    DisplayOrdering.title(
      friendlyName: prefs(display.persistenceKey).friendlyName,
      hardwareName: display.name
    )
  }

  /// The prefs the app runs on, so the seams above take a factory instead of
  /// reaching for `UserDefaults.standard` from inside a derivation.
  static func standardPrefs(_ persistenceKey: String) -> DisplayPrefs {
    DisplayPrefs(persistenceKey: persistenceKey)
  }

  /// Two empties: nothing attached is a hardware fact, everything hidden is
  /// undoable, so that branch says where to undo it.
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
  // Only externals get value rows: the built-in's volume/contrast controllers
  // are placeholders on a `NoopDDCWriter` that still reports `isAvailable`, so
  // rendering them would show a live-looking slider that does nothing.

  /// Volume slider per DDC display, unless hidden, disabled per command, or
  /// `forceSoftware`. The last two are `DDCValueController.isAvailable`, the
  /// same gate `setValue` self-gates on, so a visible slider is never a dead one.
  ///
  /// This removes the row. `AppModel.volumeSliderEnabled` greys it instead, for
  /// a monitor that denies volume; these conjuncts mean the control does not
  /// apply here at all.
  @MainActor
  static func showsVolumeSlider(for state: AppModel.DisplayState, prefs: DisplayPrefs) -> Bool {
    showsVolumeSlider(
      commandIsAvailable: state.volume.isAvailable, hideVolumeSlider: prefs.hideVolumeSlider)
  }

  static func showsVolumeSlider(commandIsAvailable: Bool, hideVolumeSlider: Bool) -> Bool {
    commandIsAvailable && !hideVolumeSlider
  }

  /// Contrast slider behind the app-level `showContrast` pref (default
  /// false, fork parity), never for a disabled or `forceSoftware` display.
  /// `showContrast` is unkeyed, so the display's own prefs object answers it.
  @MainActor
  static func showsContrastSlider(for state: AppModel.DisplayState, prefs: DisplayPrefs) -> Bool {
    showsContrastSlider(
      commandIsAvailable: state.contrast.isAvailable, showContrast: prefs.showContrast)
  }

  static func showsContrastSlider(commandIsAvailable: Bool, showContrast: Bool) -> Bool {
    showContrast && commandIsAvailable
  }

  /// Banner, not alert (spec §6). Shown only while the grant is missing and a
  /// key mode wants it; `AccessibilityPermission` observes for the app's
  /// lifetime, so a revoked grant brings this back with no relaunch.
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

  /// Holds a power assertion for the app rather than touching a display, so it
  /// sits outside the per-display stack.
  ///
  /// One line, and its height never changes with state: a caption that appeared
  /// while the toggle was on grew the panel inside the already-open `NSMenu` and
  /// clipped the footer off the bottom [MEASURED 2026-08-19].
  ///
  /// OLED care's idle dim, blackout and unfocused dim cannot engage while this
  /// is on, which Settings > Menu Bar states next to the hide switch.
  private var keepAwakeRow: some View {
    HStack(spacing: 0) {
      // Label leading, control trailing, like the Resolution and Mirroring
      // rows above it. A `Toggle` left to size itself centres label and switch
      // as one group, matching nothing else in the panel [MEASURED 2026-08-19].
      Label("Keep display awake", systemImage: "cup.and.saucer.fill")
        .font(.system(size: 12))
      Spacer(minLength: 8)
      Toggle("", isOn: Binding(
        get: { model.keepAwake.isOn },
        set: { model.keepAwake.setOn($0) }
      ))
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.mini)
      // `labelsHidden` detached the visible `Label` above, so without this the
      // switch announces as unnamed.
      .accessibilityLabel("Keep display awake")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  /// Presentation only: hiding the row does not release an assertion an earlier
  /// toggle took, so this asks nothing about `KeepAwake` itself.
  @MainActor
  static func showsKeepAwake(appPrefs: DisplayPrefs) -> Bool {
    !appPrefs.hideKeepAwake
  }

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

/// The panel's menu tracking session, so a control inside the panel can end it.
/// Set once at launch by `StatusItemController`.
///
/// Tracking holds the main run loop in event-tracking mode: a window cannot take
/// focus and queued main-actor work is starved until tracking ends.
@MainActor
enum PanelMenu {
  static weak var menu: NSMenu?

  static func endTracking() {
    menu?.cancelTracking()
  }
}

extension PanelView {
  // MARK: - The care line

  /// The caption under an external display's name, nil when there is nothing to
  /// say. The Menu Bar preview calls this too, so both surfaces derive one line.
  @MainActor
  static func careLine(for state: AppModel.DisplayState, model: AppModel) -> String? {
    careLine(
      persistenceKey: state.display.persistenceKey,
      prefs: standardPrefs(state.display.persistenceKey),
      care: model.oledCare, safeMode: model.isSafeMode)
  }

  /// Reads the summary only when enrolled and not in Safe Mode. That leaves an
  /// un-enrolled display's history unstated, as the Health pane does, and keeps
  /// a store decode out of this view body.
  @MainActor
  static func careLine(
    persistenceKey: String, prefs: DisplayPrefs, care: OledCareCoordinator, safeMode: Bool
  ) -> String? {
    let enrolled = prefs.oledCareEnrolled
    let hours = care.hoursTracker(for: persistenceKey).totalHours
    let summary = enrolled && !safeMode ? care.healthSummary(for: persistenceKey) : nil
    return PanelCareLine.text(
      enrolled: enrolled, hours: hours, summary: summary, safeMode: safeMode)
  }

  /// Why the panel's HDR button cannot act, or nil when it can.
  ///
  /// Only the ENGAGE direction is refused: with HDR live the button offers the
  /// exit, and greying that would be the forbidden shape: a recovery control
  /// unavailable in the state it recovers from.
  /// `BrightnessController.setHDRMode` enforces the same asymmetry.
  static func hdrRefusalReason(
    isShowingSynthesizedSize: Bool, isHDREngaged: Bool
  ) -> String? {
    guard isShowingSynthesizedSize, !isHDREngaged else { return nil }
    return SynthesisCopy.hdrBlockedBySynthesizedSize
  }
}

/// Section header for one display, all secondary-colored so the slider stays
/// the row's only emphasis.
private struct DisplayHeaderRow: View {
  let controller: BrightnessController
  let displayName: String
  let isShowingSynthesizedSize: Bool
  /// `PanelView.careLine`'s answer. Nil draws nothing, keeping the row one line tall.
  let careLine: String?

  @State private var isHovering = false

  /// Reads the state, not the `hdrMode` pref: the two diverge the moment HDR is
  /// toggled in System Settings, and the badge beside this button reads state,
  /// so a mode-sourced label put "HDR" next to "HDR Off".
  private var modeLabel: String {
    controller.isHDREngaged ? "HDR On" : "HDR Off"
  }

  /// Same source, so a click always moves away from what the label reports.
  /// Both directions ask `setHDRMode` to act on a mode it nominally already
  /// holds, which is what its state-aware guard is for.
  private var nextMode: HDRMode {
    controller.isHDREngaged ? .off : .alwaysOn
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
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
      if let careLine {
        Text(verbatim: careLine)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          // The name above is hidden from VoiceOver (the slider carries it), so
          // this line names its display and is read as one element.
          .accessibilityLabel(Text(verbatim: "\(displayName), \(careLine)"))
      }
    }
    // On the row, not the button: the caption draws in a leading-aligned column
    // under whatever it wraps, and the button's slot is a few characters wide.
    //
    // The row grows a line when a size engages, but that reconfiguration ends
    // menu tracking and rebuilds the panel, so it cannot clip the footer the way
    // a height change inside an open panel does.
    .panelHoverReason(refusalReason)
  }

  private var refusalReason: String? {
    PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: isShowingSynthesizedSize,
      isHDREngaged: controller.isHDREngaged
    )
  }

  /// A toggle, not a `Menu`: the panel is hosted in an `NSMenu` item and the
  /// enclosing menu owns event tracking, so a nested SwiftUI `Menu` never opens
  /// (measured on hardware). Plain buttons do work; the label names the mode.
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
    // Disable, don't hide, on non-HDR displays. `supportsHDR` is
    // observation-tracked, so the button enables when the async refresh lands.
    .disabled(!controller.supportsHDR || refusalReason != nil)
    // No `.help`: the panel delivers no tooltip at all, enabled controls
    // included. Menu tracking is the cause, not the greying next door.
    .accessibilityLabel("\(displayName) HDR mode")
    .accessibilityValue(modeLabel)
  }
}

/// Same hover/press feedback language as `FooterIconButtonStyle`, with text
/// metrics instead of a square icon frame.
private struct HDRModeButtonStyle: ButtonStyle {
  let isHovering: Bool
  // The style must read enablement itself, or a disabled button renders live
  // (hover fill, primary text) and silently does nothing.
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

// `DisplaySliderRow` and `ValueSliderRow` are shared with the settings hero, so
// the mute-strand rule's `snapsToZero` derivation exists in one place.

/// Footer action button: a symbol and a word on a rounded background that
/// appears on hover, with a distinct pressed state.
///
/// `power` means "shut down" on macOS, so on the quit button the word carries
/// the meaning and the symbol only balances the gear opposite it.
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
    // The menu can close without a trailing mouse-exit event (Escape, or
    // clicking the status item), leaving a stuck highlight on the next open.
    .onDisappear { isHovering = false }
  }
}

private struct FooterIconButtonStyle: ButtonStyle {
  let isHovering: Bool
  // Same enablement handling as HDRModeButtonStyle.
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
