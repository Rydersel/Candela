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
  let tint: Color
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
        id: id, title: "General", symbol: "gearshape", tint: .gray,
        content: { AnyView(GeneralPane()) }
      )
    case .menuBar:
      SettingsPaneDescriptor(
        id: id, title: "Menu Bar", symbol: "menubar.rectangle", tint: .blue,
        content: { AnyView(AppMenuPane()) }
      )
    case .arrangement:
      SettingsPaneDescriptor(
        id: id, title: "Arrangement", symbol: "rectangle.3.group", tint: .teal,
        content: { AnyView(ArrangementPane()) }
      )
    case .oledCare:
      SettingsPaneDescriptor(
        // NOT `display`: every per-display sidebar row already draws that
        // glyph, so this row would be distinguished from them by tint alone —
        // state by colour alone, which this repo does not do. `sun.min` reads
        // as "reduce luminance", which is what the pane is for.
        id: id, title: "OLED Care", symbol: "sun.min", tint: .orange,
        content: { AnyView(OledCarePane()) }
      )
    case .virtualDisplays:
      SettingsPaneDescriptor(
        // NOT `display` (every per-display row draws that glyph); the badge
        // reads as "add a display", which is what the pane does.
        id: id, title: "Virtual Displays", symbol: "rectangle.badge.plus", tint: .purple,
        content: { AnyView(VirtualDisplaysPane()) }
      )
    case .keyboard:
      SettingsPaneDescriptor(
        id: id, title: "Keyboard", symbol: "keyboard", tint: .indigo,
        content: { AnyView(KeyboardPane()) }
      )
    case .updates:
      SettingsPaneDescriptor(
        id: id, title: "Updates", symbol: "arrow.triangle.2.circlepath", tint: .green,
        content: { AnyView(UpdatesPane()) }
      )
    case .about:
      SettingsPaneDescriptor(
        id: id, title: "About", symbol: "info.circle", tint: .gray,
        content: { AnyView(AboutPane()) }
      )
    }
  }
}
