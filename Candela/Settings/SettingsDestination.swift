import Foundation

/// Closed on purpose: `SettingsRegistry.descriptor(for:)` switches over this
/// exhaustively, so adding a case without a descriptor is a compile error
/// rather than a sidebar row that navigates nowhere. Same guarantee `PrefName`
/// gives the propagation seam.
enum PaneID: String, CaseIterable, Hashable {
  // Order is the sidebar's order. `arrangement` sits after `menuBar` because it
  // is about the desktop rather than about the app, and before the input and
  // informational panes. `oledCare` follows it: it is also about the displays
  // themselves, and its per-display sections read as a continuation of the
  // arrangement pane's subject rather than of the app's own settings.
  // `virtualDisplays` follows `oledCare` for the same reason `oledCare`
  // follows `arrangement`: it is about the desktop's displays rather than
  // about the app, and it CREATES the things the arrangement pane places.
  case general, menuBar, arrangement, oledCare, virtualDisplays, keyboard, about
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

/// The OLED Care pane's pushed pages (OCR1), keyed by persistence key like
/// everything else that survives a replug. All elements of one presented path
/// share one key by construction: the switcher rewrites every element.
///
/// Display Health is deliberately NOT a case (OCR-A1, #185): it opens in its
/// own content-sized window, because a pushed page cannot resize the settings
/// window to a portrait display's map. Navigation-only state, not on-disk
/// schema, so the case's removal cost nothing stored.
enum OledCarePage: Hashable {
  case display(String)
  case measurement(String)

  var displayKey: String {
    switch self {
    case let .display(key), let .measurement(key): key
    }
  }

  func withDisplayKey(_ key: String) -> OledCarePage {
    switch self {
    case .display: .display(key)
    case .measurement: .measurement(key)
    }
  }
}

/// The Keyboard pane's pushed pages (KMR11). Raw values are the
/// `CANDELA_DEBUG_SETTINGS` sub-page ids, like `DisplaySubPage`'s. Unlike the
/// OLED pages these carry no display key: neither page depends on connected
/// hardware, so a departure never pops them.
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

/// The window's single navigation stack holds pages from three families: a
/// display destination's sub-pages, the OLED Care pane's (OCR1), and the
/// Keyboard pane's (KMR11). One wrapper type, so the stack's typed path stays
/// inspectable and the per-family storage in `SettingsRootView` stays typed.
enum SettingsPushedPage: Hashable {
  case display(DisplaySubPage)
  case oledCare(OledCarePage)
  case keyboard(KeyboardPage)
}
