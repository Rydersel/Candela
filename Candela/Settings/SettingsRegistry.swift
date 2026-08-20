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

/// The ONLY place a settings pane is declared. Adding a feature area is one
/// `PaneID` case, one entry here, and one view file — the sidebar, the split
/// view, the toolbar title and the selection logic are untouched.
@MainActor
enum SettingsRegistry {
  static var panes: [SettingsPaneDescriptor] {
    PaneID.allCases.map(descriptor(for:))
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
    case .updates:
      SettingsPaneDescriptor(
        id: id, title: "Updates", symbol: "arrow.triangle.2.circlepath",
        accent: SettingsAccent(
          accent: Color(red: 0.37, green: 0.76, blue: 0.50),
          secondary: Color(red: 0.22, green: 0.55, blue: 0.67)),
        content: { AnyView(UpdatesPane()) }
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
