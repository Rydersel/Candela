import CandelaKit
import SwiftUI

/// The modifier-combination legend, a reference page pushed from Keyboard
/// (KMR5): five rows, nothing here is a control, which is exactly the
/// hub-vs-subpage cut (SO2). Always reachable; when the brightness keys are
/// not watched it says the combinations are inactive rather than describing
/// behavior that is not happening (the D11 defect class).
///
/// `@MainActor` for the same reason as every pane: `AppModel` is main-actor
/// and a `View`'s computed properties are nonisolated under complete
/// concurrency checking.
@MainActor
struct KeyboardModifierKeysPage: View {
  @Environment(AppModel.self) private var model

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // The inactive note follows the mode picker on the root; prefs are plain
    // UserDefaults, so the revision bump is the only re-read.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SubPageHeader(
        title: KeyboardPage.modifiers.title,
        currentKey: "", displays: [], onSwitch: { _ in })

      SettingsCardSection {
        if !KeyModePolicy.watchesMediaKeys(prefs.keyboardBrightness) {
          inactiveNote
          SettingsCardDivider()
        }
        // Spoken labels preserved verbatim from the legend this page replaced
        // (SO16: the sentence IS the accessibility label).
        ModifierLegendRow(
          title: "Built-in display",
          modifiers: ["⌃"], suffix: "+ brightness key",
          spoken: "Control plus a brightness key adjusts the built-in display."
        )
        SettingsCardDivider()
        ModifierLegendRow(
          title: "All external displays",
          modifiers: ["⌃", "⌘"], suffix: "+ brightness key",
          spoken: "Control Command plus a brightness key adjusts every external display."
        )
        SettingsCardDivider()
        ModifierLegendRow(
          title: "Contrast",
          modifiers: ["⌃", "⌥", "⌘"], suffix: "+ brightness key",
          spoken: "Control Option Command plus a brightness key adjusts contrast."
        )
        SettingsCardDivider()
        ModifierLegendRow(
          title: "Open Displays settings",
          modifiers: ["⌥"], suffix: "+ brightness key",
          spoken: "Option with a brightness key opens Displays settings."
        )
        SettingsCardDivider()
        ModifierLegendRow(
          title: "Toggle mirroring",
          modifiers: ["⌘"], suffix: "+ brightness down",
          spoken: "Command with the brightness-down key switches mirroring on or off."
        )
      }

      // The scope, stated once for the page under the card the section footer
      // used to sit beneath: media-key handling only, the fine-step modifiers,
      // and the custom-shortcut exemption (KMR5).
      SettingsCaption("These combinations work while the keyboard's brightness keys are handled by \(AppInfo.productName). Holding Shift and Option with any adjustment makes a fine step. Custom shortcuts carry their own modifiers, and none of these rules apply to them.")
    }
  }

  /// Stays at the head of the legend rather than becoming a card of its own:
  /// it is a fact about the five rows under it, and a separate notice would
  /// float free of them.
  private var inactiveNote: some View {
    HStack(alignment: .top, spacing: 9) {
      // Symbol AND text; never state by colour alone.
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(SettingsTheme.faintColor)
      Text("These combinations are inactive because the keyboard's brightness keys are currently left to macOS.")
        .foregroundStyle(SettingsTheme.titleColor)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 6)
  }
}

/// One modifier combination and what it does, the glyphs rendered as keycap
/// chips matching the hero's vocabulary (KMR5).
///
/// ONE accessibility element (SO16 + contract 5's shape): the label is the
/// whole sentence the legend's caption used to say, so the glyphs are never
/// spelled out character by character and the combination is described in
/// words. At accessibility text sizes the combination drops onto its own line
/// rather than truncating (contract 10), the same `ViewThatFits` measurement
/// `NavigationRow` uses.
private struct ModifierLegendRow: View {
  let title: LocalizedStringKey
  let modifiers: [String]
  let suffix: String
  let spoken: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Text(title)
        Spacer(minLength: 16)
        // Only on this candidate: a wrapping combination would let the row
        // "fit" at any width and the fallback would never be reached.
        combination.lineLimit(1)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        combination
      }
    }
    .foregroundStyle(SettingsTheme.titleColor)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  /// Chips in the hero's keycap vocabulary at row scale: a flat face and a
  /// hairline edge, the same two whites the caps use.
  private var combination: some View {
    HStack(spacing: 4) {
      ForEach(modifiers, id: \.self) { glyph in
        Text(verbatim: glyph)
          .font(.callout)
          .frame(minWidth: 16)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.white.opacity(0.08))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.white.opacity(0.12), lineWidth: 1)
          )
      }
      Text(verbatim: suffix)
        .foregroundStyle(SettingsTheme.bodyColor)
    }
  }
}
