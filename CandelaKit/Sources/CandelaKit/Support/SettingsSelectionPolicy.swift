/// Where the settings sidebar should land after a display arrives or departs.
/// Three outcomes on purpose: a caller told only "keep or not" could never
/// distinguish "another display survives" from "none does".
public enum SettingsSelectionResolution: Equatable, Sendable {
  /// The selected display is still connected — do not move.
  case keep(String)
  /// The selected display left, but another survives — stay in display settings.
  case fallbackToSibling(String)
  /// No display remains; the caller falls back to a pane.
  case fallbackToPane
}

/// What the settings window's detail column is actually showing, right now.
///
/// ONE value, deliberately, and it is the whole point of the type: the window
/// title, the detail content, the navigation stack's path and the AppKit window
/// configurator each used to answer "which destination is on screen" for
/// themselves, from the same three inputs, with nothing making them agree.
/// #124 is what that costs when the answers diverge.
public enum SettingsDetailPresentation<Page: Equatable & Sendable>: Equatable, Sendable {
  /// A display destination, with the sub-pages that are actually presentable
  /// over it. Never a display the caller cannot render.
  case display(key: String, path: [Page])
  /// Not a display: either a pane is selected, or the selected display is not
  /// there and the caller shows its fallback pane. Nothing is pushed either
  /// way, because a pushed page belongs to a display.
  case pane

  /// The selected display, but only when the detail column can show it.
  public var displayKey: String? {
    guard case let .display(key, _) = self else { return nil }
    return key
  }

  /// What is pushed on screen, which is not the same as what is retained for
  /// later (SO23). The window configurator re-runs on this number.
  public var pathDepth: Int {
    guard case let .display(_, path) = self else { return 0 }
    return path.count
  }
}

/// Whether a selected display destination is still valid.
///
/// Lives in CandelaKit rather than the view because it is the only part of the
/// settings redesign that is a pure function, and therefore the only part with
/// an automated net — the app target has no test target by design.
public enum SettingsSelectionPolicy {
  /// Resolves where the selection belongs, or `nil` when no display was
  /// selected at all (a pane is showing) and the caller must do nothing.
  ///
  /// Keys are `DisplayPrefs` persistence keys, which survive a replug; display
  /// IDs do not, and selecting by ID would drop the user out of a pane every
  /// time a monitor renegotiated its link.
  ///
  /// The sibling is `connectedKeys.first`, so the caller owes this function
  /// **sidebar order** — built-in first, then externals in model order. Passing
  /// any other order still resolves, but lands somewhere other than the top
  /// surviving row.
  public static func resolveDestination(
    selectedDisplayKey: String?, connectedKeys: [String]
  ) -> SettingsSelectionResolution? {
    guard let selectedDisplayKey else { return nil }
    if connectedKeys.contains(selectedDisplayKey) { return .keep(selectedDisplayKey) }
    if let sibling = connectedKeys.first { return .fallbackToSibling(sibling) }
    return .fallbackToPane
  }

  /// Resolves what the detail column shows, in one answer that the title, the
  /// content, the pushed path and the window configurator all read.
  ///
  /// `retainedPath` is what the caller is HOLDING for that display (SO23), not
  /// what it may show. A display that is not in `connectedKeys` presents
  /// nothing pushed and falls back to a pane, which is the rule the three
  /// separate answers used to disagree about: the title said "General", the
  /// content rendered the General pane, and the navigation path went on
  /// presenting a sub-page for a display nothing could look up. The caller's
  /// retained storage is untouched by this: presenting nothing is not
  /// forgetting, so the display coming back presents the same path again.
  ///
  /// `selectedDisplayKey` is nil when a pane is selected. Keys are
  /// `DisplayPrefs` persistence keys, for `resolveDestination`'s reason.
  public static func present<Page: Equatable & Sendable>(
    selectedDisplayKey: String?, retainedPath: [Page], connectedKeys: [String]
  ) -> SettingsDetailPresentation<Page> {
    guard let selectedDisplayKey, connectedKeys.contains(selectedDisplayKey) else { return .pane }
    return .display(key: selectedDisplayKey, path: retainedPath)
  }

  /// The key to re-select when a remembered display returns while the window is
  /// open (SO9).
  ///
  /// `nil` unless the remembered display is among the arrivals AND the user is
  /// not already on a display destination — a returning monitor must never yank
  /// them off one they chose in the meantime.
  public static func restoration(
    lastDisplayKey: String?, arrivedKeys: [String], currentIsDisplay: Bool
  ) -> String? {
    guard let lastDisplayKey, !currentIsDisplay, arrivedKeys.contains(lastDisplayKey) else { return nil }
    return lastDisplayKey
  }
}
