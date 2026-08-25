import SwiftUI

/// One feature area's sidebar row and content.
///
/// `content` is a closure returning `AnyView` rather than a generic parameter
/// because the descriptors live in a heterogeneous array. The type erasure is
/// paid once per navigation, not per row and not per frame.
@MainActor
struct SettingsPaneDescriptor: Identifiable {
  let id: PaneID
  /// Plain `String`: the sidebar row and the toolbar title are the same
  /// words, and the toolbar needs a String (D25 — English only, no catalog).
  let title: String
  let symbol: String
  /// The destination's stage lighting: what its canvas, its sidebar row and
  /// everything its page tints read from. A pair rather than one colour
  /// because the canvas lights from two sources (SV8).
  let accent: SettingsAccent
  let content: () -> AnyView
}

/// One group of sidebar rows: the section's header, if it has one, and the
/// panes under it in render order.
///
/// A section with no header and `gapAbove` is a quiet break rather than a peer
/// section (SC1): the utility rows at the bottom get air, not a promotion.
struct SettingsSidebarSection: Identifiable {
  /// Drawn uppercase, exactly as written here. Nil means the rows start with
  /// no kicker over them.
  let header: String?
  /// Space above the first row, for a section that has no header to supply it.
  let gapAbove: Bool
  let panes: [PaneID]

  /// Stable across renders because the section list is static: the header when
  /// there is one, otherwise the first pane, which no other section can hold.
  var id: String { header ?? panes.first?.rawValue ?? "" }
}

/// The ONLY place a settings pane is declared. Adding a feature area is one
/// `PaneID` case, one entry here, one line in a section, and one view file.
/// The sidebar, the split view, the toolbar title and the selection logic are
/// untouched.
@MainActor
enum SettingsRegistry {
  /// The ONE source of sidebar render order (SC1). The sidebar draws these in
  /// order, then the displays; ⌘1–⌘9 index the same flattened list.
  ///
  /// CARE first because it is what this app is for, CONTROLS visibly under it
  /// because everyday adjustment is the commodity half. `PaneID.allCases` is
  /// deliberately NOT consulted: raw values are on-disk schema and can only be
  /// appended to, so order lives here where it costs nothing to change.
  static let sections: [SettingsSidebarSection] = [
    SettingsSidebarSection(header: nil, gapAbove: false, panes: [.general]),
    SettingsSidebarSection(
      header: "CARE", gapAbove: false, panes: [.health, .protection, .oledCare, .checkup]),
    SettingsSidebarSection(
      header: "CONTROLS", gapAbove: false,
      panes: [.menuBar, .keyboard, .arrangement, .virtualDisplays]),
    SettingsSidebarSection(header: nil, gapAbove: true, panes: [.about]),
  ]

  /// Sidebar render order, flattened. Nameable so a test can pin it against
  /// SC1's list rather than against a screenshot.
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
        // NOT `display`: every per-display sidebar row already draws that
        // glyph, so this row would be distinguished from them by tint alone —
        // state by colour alone, which this repo does not do. `sun.min` reads
        // as "reduce luminance", which is what the pane is for.
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
    // The CARE panes light from one warm hue family, so the section reads as
    // one identity (SC8). OLED Care's amber anchors it and is unchanged; these
    // three take neighbouring warm hues, each still distinct from the others at
    // a glance.
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
