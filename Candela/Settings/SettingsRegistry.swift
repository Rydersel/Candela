import SwiftUI

/// One feature area's sidebar row and content.
///
/// `content` erases to `AnyView` because the descriptors live in one
/// heterogeneous array. The erasure costs one call per navigation, not per
/// frame.
@MainActor
struct SettingsPaneDescriptor: Identifiable {
  let id: PaneID
  /// Plain `String`, not `LocalizedStringKey`: the toolbar needs one, and
  /// there is no catalog.
  let title: String
  let symbol: String
  /// What the canvas, the sidebar row and every tint on the page read. A pair
  /// because the canvas lights from two sources.
  let accent: SettingsAccent
  let content: () -> AnyView
}

/// One group of sidebar rows, in render order.
///
/// No header plus `gapAbove` is a quiet break rather than a peer section:
/// the utility rows at the bottom get air, not a promotion.
struct SettingsSidebarSection: Identifiable {
  /// Drawn exactly as written. Nil draws no kicker.
  let header: String?
  /// Space above the first row, for a section with no header to supply it.
  let gapAbove: Bool
  let panes: [PaneID]

  /// Stable because the section list is static, and the first pane is unique
  /// to its section.
  var id: String { header ?? panes.first?.rawValue ?? "" }
}

/// The ONLY place a settings pane is declared. A new feature area is one
/// `PaneID` case, one descriptor, one line in a section, one view file; the
/// sidebar, the shell and the selection logic are untouched.
@MainActor
enum SettingsRegistry {
  /// The ONE source of sidebar render order; ⌘1 onward index the same
  /// flattened list. `PaneID.allCases` is deliberately not consulted: raw
  /// values are on-disk schema and can only be appended to, so order lives here
  /// where it costs nothing to change.
  static let sections: [SettingsSidebarSection] = [
    SettingsSidebarSection(header: nil, gapAbove: false, panes: [.general]),
    SettingsSidebarSection(
      header: "CARE", gapAbove: false, panes: [.health, .protection, .oledCare, .checkup]),
    SettingsSidebarSection(
      header: "CONTROLS", gapAbove: false,
      panes: [.menuBar, .keyboard, .arrangement, .virtualDisplays]),
    SettingsSidebarSection(header: nil, gapAbove: true, panes: [.about]),
  ]

  /// Nameable so a test can pin the order against the render-order list
  /// rather than a screenshot.
  static var paneOrder: [PaneID] { sections.flatMap(\.panes) }

  static var panes: [SettingsPaneDescriptor] {
    paneOrder.map(descriptor(for:))
  }

  /// Exhaustive by construction: a new `PaneID` case fails to compile here
  /// until it is given a row and a view.
  static func descriptor(for id: PaneID) -> SettingsPaneDescriptor {
    switch id {
    case .general:
      SettingsPaneDescriptor(
        id: id, title: "General", symbol: "gearshape",
        accent: SettingsAccent(
          accent: Color(red: 0.29, green: 0.67, blue: 0.64),
          secondary: Color(red: 0.25, green: 0.51, blue: 0.81)),
        content: { AnyView(GeneralPane()) }
      )
    case .menuBar:
      SettingsPaneDescriptor(
        id: id, title: "Menu Bar", symbol: "menubar.rectangle",
        accent: SettingsAccent(
          accent: Color(red: 0.30, green: 0.70, blue: 0.82),
          secondary: Color(red: 0.30, green: 0.41, blue: 0.84)),
        content: { AnyView(AppMenuPane()) }
      )
    case .arrangement:
      SettingsPaneDescriptor(
        id: id, title: "Arrangement", symbol: "rectangle.3.group",
        accent: SettingsAccent(
          accent: Color(red: 0.46, green: 0.54, blue: 0.89),
          secondary: Color(red: 0.30, green: 0.33, blue: 0.80)),
        content: { AnyView(ArrangementPane()) }
      )
    case .oledCare:
      SettingsPaneDescriptor(
        // NOT `display`: every per-display row draws that glyph, so this row
        // would differ from them by tint alone. `sun.min` reads as "reduce
        // luminance", which is what the pane is for.
        id: id, title: "OLED Care", symbol: "sun.min",
        accent: SettingsAccent(
          accent: Color(red: 0.91, green: 0.60, blue: 0.31),
          secondary: Color(red: 0.75, green: 0.35, blue: 0.52)),
        content: { AnyView(OledCarePane()) }
      )
    case .virtualDisplays:
      SettingsPaneDescriptor(
        // NOT `display` (every per-display row draws that glyph); the badge
        // reads as "add a display", which is what the pane does.
        id: id, title: "Virtual Displays", symbol: "rectangle.badge.plus",
        accent: SettingsAccent(
          accent: Color(red: 0.58, green: 0.43, blue: 0.89),
          secondary: Color(red: 0.30, green: 0.33, blue: 0.80)),
        content: { AnyView(VirtualDisplaysPane()) }
      )
    case .keyboard:
      SettingsPaneDescriptor(
        id: id, title: "Keyboard", symbol: "keyboard",
        accent: SettingsAccent(
          accent: Color(red: 0.38, green: 0.54, blue: 0.89),
          secondary: Color(red: 0.45, green: 0.34, blue: 0.81)),
        content: { AnyView(KeyboardPane()) }
      )
    // The CARE panes share one warm hue family so the section reads as one
    // identity, anchored on OLED Care's amber.
    case .health:
      SettingsPaneDescriptor(
        // A trace, not a heart: what this pane shows is a record over time.
        id: id, title: "Health", symbol: "waveform.path.ecg",
        accent: SettingsAccent(
          accent: Color(red: 0.93, green: 0.72, blue: 0.38),
          secondary: Color(red: 0.82, green: 0.50, blue: 0.30)),
        content: { AnyView(HealthPane()) }
      )
    case .protection:
      SettingsPaneDescriptor(
        id: id, title: "Protection", symbol: "shield",
        accent: SettingsAccent(
          accent: Color(red: 0.89, green: 0.52, blue: 0.34),
          secondary: Color(red: 0.72, green: 0.33, blue: 0.44)),
        content: { AnyView(ProtectionPane()) }
      )
    case .checkup:
      SettingsPaneDescriptor(
        id: id, title: "Checkup", symbol: "checkmark.seal",
        accent: SettingsAccent(
          accent: Color(red: 0.90, green: 0.67, blue: 0.45),
          secondary: Color(red: 0.78, green: 0.45, blue: 0.40)),
        content: { AnyView(CheckupPane()) }
      )
    case .about:
      SettingsPaneDescriptor(
        id: id, title: "About", symbol: "info.circle",
        accent: SettingsAccent(
          accent: Color(red: 0.63, green: 0.67, blue: 0.87),
          secondary: Color(red: 0.33, green: 0.38, blue: 0.74)),
        content: { AnyView(AboutPane()) }
      )
    }
  }
}
