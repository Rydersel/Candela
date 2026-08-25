import Foundation

/// Closed on purpose: `SettingsRegistry.descriptor(for:)` switches over this
/// exhaustively, so adding a case without a descriptor is a compile error
/// rather than a sidebar row that navigates nowhere. Same guarantee `PrefName`
/// gives the propagation seam.
enum PaneID: String, CaseIterable, Hashable {
  // This list is NO LONGER the sidebar's order (SC1). Render order comes from
  // `SettingsRegistry.sections`, which groups the panes under CARE and
  // CONTROLS; `allCases` is now only the id space, and a test pins that every
  // case appears in exactly one section.
  //
  // Raw values are shipped schema (the `CANDELA_DEBUG_SETTINGS` route ids, and
  // whatever else stores a pane id): append, never rename and never renumber.
  // The care panes are appended for that reason alone, and their position here
  // says nothing about where they draw.
  //
  // `updates` was a case until 2026-08-20, when its controls moved onto the
  // About page. Removing an id is the one edit this list otherwise forbids, and
  // it is safe here only because nothing stores a pane id on disk: the window's
  // selection is `@State`, seeded at General every time it opens. The one
  // reader of a raw value is the debug route, which names the retirement.
  case general, menuBar, arrangement, oledCare, virtualDisplays, keyboard, about
  case health, protection, checkup
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
/// schema, so a case's removal costs nothing stored.
///
/// Measurement & Data was the second case until SC5 retired the page; its
/// controls are the Health pane's now, which is a sidebar destination rather
/// than a push. One case left, kept as an enum because the pane's stack, its
/// switcher and its departure rule are all written against this type.
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
