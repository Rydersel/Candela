import SwiftUI

/// One feature area's sidebar row and content.
///
/// `content` is a closure returning `AnyView` rather than a generic parameter
/// because the descriptors live in a heterogeneous array. The type erasure is
/// paid once per navigation, not per row and not per frame.
@MainActor
struct SettingsPaneDescriptor: Identifiable {
  let id: PaneID
  let title: LocalizedStringKey
  let symbol: String
  let tint: Color
  let content: () -> AnyView
}

/// The ONLY place a settings pane is declared. Adding a feature area is one
/// `PaneID` case, one entry here, and one view file — the sidebar, the split
/// view and the selection logic are untouched.
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
    case .keyboard:
      SettingsPaneDescriptor(
        id: id, title: "Keyboard", symbol: "keyboard", tint: .indigo,
        content: { AnyView(KeyboardPane()) }
      )
    case .about:
      SettingsPaneDescriptor(
        id: id, title: "About", symbol: "info.circle", tint: .gray,
        content: { AnyView(AboutPane()) }
      )
    }
  }
}
