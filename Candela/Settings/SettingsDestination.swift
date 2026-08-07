import Foundation

/// Closed on purpose: `SettingsRegistry.descriptor(for:)` switches over this
/// exhaustively, so adding a case without a descriptor is a compile error
/// rather than a sidebar row that navigates nowhere. Same guarantee `PrefName`
/// gives the propagation seam.
enum PaneID: String, CaseIterable, Hashable {
  // Order is the sidebar's order. `arrangement` sits after `menuBar` because it
  // is about the desktop rather than about the app, and before the input and
  // informational panes.
  case general, menuBar, arrangement, keyboard, about
}

/// The split view's selection type.
///
/// Displays are keyed by `persistenceKey`, never `CGDirectDisplayID`: the ID
/// changes across a replug while the persistence key does not, so a selection
/// survives the disconnect/reconnect cycle that removes the row.
enum SettingsDestination: Hashable {
  case pane(PaneID)
  case display(String)
}

/// A display destination's pushed sub-pages (SO1). Raw values are the
/// `CANDELA_DEBUG_SETTINGS` sub-page ids — user-visible names live in `title`,
/// which pushed pages, toolbar titles and VoiceOver all share so a rename
/// cannot fork them.
enum DisplaySubPage: String, CaseIterable, Hashable {
  case allModes, advanced, diagnostics

  var title: String {
    switch self {
    case .allModes: "All Sizes & Refresh Rates"
    case .advanced: "Advanced"
    case .diagnostics: "Diagnostics"
    }
  }
}
