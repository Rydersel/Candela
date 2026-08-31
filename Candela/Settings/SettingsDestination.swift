import Foundation

/// Closed on purpose: `SettingsRegistry.descriptor(for:)` switches over this
/// exhaustively, so adding a case without a descriptor is a compile error
/// rather than a sidebar row that navigates nowhere. Same guarantee `PrefName`
/// gives the propagation seam.
enum PaneID: String, CaseIterable, Hashable {
  // This is NOT the sidebar's order (SC1). Render order comes from
  // `SettingsRegistry.sections`; `allCases` is only the id space.
  //
  // Raw values are the `CANDELA_DEBUG_SETTINGS` route ids: append, never
  // rename and never renumber. Position here says nothing about where a pane
  // draws.
  case general, menuBar, arrangement, oledCare, virtualDisplays, keyboard, about
  case health, protection, checkup
}

/// Displays are keyed by `persistenceKey`, never `CGDirectDisplayID`: the ID
/// changes across a replug, so a selection would not survive the reconnect.
enum SettingsDestination: Hashable {
  case pane(PaneID)
  case display(String)
}

/// A display destination's pushed sub-pages (SO1). Raw values are the
/// `CANDELA_DEBUG_SETTINGS` sub-page ids; user-visible names live in `title`,
/// shared by pushed pages, toolbar titles and VoiceOver so a rename cannot
/// fork them.
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

/// The OLED Care pane's pushed pages (OCR1), keyed by persistence key. All
/// elements of one presented path share one key: the switcher rewrites every
/// element.
///
/// Display Health is deliberately NOT a case (OCR-A1): it opens in its own
/// content-sized window, because a pushed page cannot resize the settings
/// window to a portrait display's map.
///
/// One case, still an enum because the pane's stack, its switcher and its
/// departure rule are all written against this type.
enum OledCarePage: Hashable {
  case display(String)

  var displayKey: String {
    switch self {
    case let .display(key): key
    }
  }

  func withDisplayKey(_ key: String) -> OledCarePage {
    switch self {
    case .display: .display(key)
    }
  }
}

/// The Keyboard pane's pushed pages (KMR11). No display key: neither page
/// depends on connected hardware, so a departure never pops them.
enum KeyboardPage: String, CaseIterable, Hashable {
  case modifiers = "mods"
  case targeting = "target"

  var title: String {
    switch self {
    case .modifiers: "Modifier Keys"
    case .targeting: "Targeting & Precision"
    }
  }
}

/// One wrapper so the window's single navigation stack can hold all three page
/// families with a typed, inspectable path.
enum SettingsPushedPage: Hashable {
  case display(DisplaySubPage)
  case oledCare(OledCarePage)
  case keyboard(KeyboardPage)
}
