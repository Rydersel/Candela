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

  var body: some View {
    VStack(spacing: 0) {
      if !model.accessibilityGranted {
        accessibilityBanner
        Divider()
      }
      VStack(alignment: .leading, spacing: 14) {
        if model.displays.isEmpty, model.builtIn == nil {
          // Empty state only when there is nothing at all to control — a
          // present built-in section IS a controllable display.
          Text("No controllable displays")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        if let builtIn = model.builtIn {
          // Name header only — no HDR badge/menu chrome: the built-in never
          // routes HDR (role .builtIn), and the section stays as quiet as
          // Control Center keeps its module headers. The slider drives the
          // native path, so Control Center's own slider follows live.
          VStack(alignment: .leading, spacing: 8) {
            Text(builtIn.display.name)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .accessibilityHidden(true) // the slider carries the display name
            DisplaySliderRow(controller: builtIn.controller, displayName: builtIn.display.name)
          }
        }
        ForEach(model.displays) { state in
          VStack(alignment: .leading, spacing: 8) {
            DisplayHeaderRow(controller: state.controller, displayName: state.display.name)
            DisplaySliderRow(controller: state.controller, displayName: state.display.name)
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      footer
    }
    .frame(width: 280)
  }

  /// Visually quiet Accessibility banner (spec §6: banner, not alert):
  /// 13 pt secondary text with a small trailing link button, matching the
  /// panel's section typography so it reads as information, not alarm. Shown
  /// only while the grant is missing; clears live via observation when
  /// `AccessibilityPermission`'s polling notices the grant.
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

  private var footer: some View {
    HStack {
      Spacer()
      FooterIconButton(systemImage: "xmark.circle", help: "Quit Candela") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
  }
}

/// Section header for one display: name, an "HDR" state badge, and a trailing
/// borderless HDR-mode menu. Everything is secondary-colored — the slider is
/// the row's only emphasis, the way Control Center keeps section chrome quiet.
private struct DisplayHeaderRow: View {
  let controller: BrightnessController
  let displayName: String

  private var hdrEngaged: Bool {
    // `.alwaysOn` holds HDR by definition; boost only when it is actually
    // engaged. The engine's live-HDR flag is internal to CandelaKit, so
    // always-on is read from the mode alone.
    controller.hdrBoostActive || controller.hdrMode == .alwaysOn
  }

  private var modeLabel: String {
    switch controller.hdrMode {
    case .off: return "HDR Off"
    case .boost: return "HDR Boost"
    case .alwaysOn: return "HDR On"
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(displayName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityHidden(true)  // the slider carries the display name
      if hdrEngaged {
        Text("HDR")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary))
          .accessibilityLabel("HDR engaged")
      }
      Spacer(minLength: 4)
      hdrMenu
    }
  }

  private var hdrMenu: some View {
    Menu {
      Picker("HDR", selection: Binding(
        get: { controller.hdrMode },
        set: { mode in Task { await controller.setHDRMode(mode) } }
      )) {
        Text("Off").tag(HDRMode.off)
        Text("Boost").tag(HDRMode.boost)
        Text("On").tag(HDRMode.alwaysOn)
      }
      .pickerStyle(.inline)
    } label: {
      Text(modeLabel)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    // Disable, don't hide, on non-HDR displays (design guidance: keep
    // controls visible so people learn what the app supports). `supportsHDR`
    // is observation-tracked, so the menu enables live once the async
    // capability refresh lands.
    .disabled(!controller.supportsHDR)
    .help("HDR mode for \(displayName)")
    .accessibilityLabel("\(displayName) HDR mode")
  }
}

/// Bridges the controller (source of truth) to the slider's binding.
/// setBrightness is synchronous and coalesces hardware writes, so drag
/// streams are safe to feed directly.
private struct DisplaySliderRow: View {
  let controller: BrightnessController
  let displayName: String

  var body: some View {
    CandelaSlider(
      value: Binding(
        get: { controller.brightness },
        set: { controller.setBrightness($0) }
      ),
      accessibilityLabel: "\(displayName) brightness"
    )
  }
}

/// Footer action button: 22 pt secondary-colored SF Symbol that brightens and
/// gains a subtle rounded background on hover, with a distinct pressed state.
private struct FooterIconButton: View {
  let systemImage: String
  let help: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 22, height: 22)
    }
    .buttonStyle(FooterIconButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // The menu can close without a trailing mouse-exit event (e.g. Escape or
    // clicking the status item), which would leave a phantom hover highlight
    // on the next open. The menu item's view leaves the window on close, so
    // onDisappear fires and clears it.
    .onDisappear { isHovering = false }
    .help(help)
    .accessibilityLabel(help)
  }
}

private struct FooterIconButtonStyle: ButtonStyle {
  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    let background: AnyShapeStyle = if configuration.isPressed {
      AnyShapeStyle(.tertiary)
    } else if isHovering {
      AnyShapeStyle(.quaternary)
    } else {
      AnyShapeStyle(.clear)
    }
    return configuration.label
      .foregroundStyle(isHovering ? .primary : .secondary)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}
