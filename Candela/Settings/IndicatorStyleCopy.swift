import CandelaKit

/// The On-Screen Indicators rows' words, in one place so a test can read them
/// and a future style cannot ship with a blank row.
enum IndicatorStyleCopy {
  enum Kind { case brightness, volume }

  /// Reads as one sentence with the row label: "Indicator style: Classic".
  static func label(for style: HUDStyle) -> String {
    switch style {
    case .system: "Match macOS"
    case .segments: "Segmented"
    case .compact: "Compact"
    case .classic: "Classic"
    case .classicCentered: "Classic (centered)"
    case .sequoia: "Sequoia"
    case .vertical: "Vertical"
    case .ring: "Ring"
    case .islandDrop: "Island"
    case .islandEdge: "Island (edge)"
    case .islandEdgeCapsules: "Island (edge capsules)"
    }
  }

  static func positionRowsApply(to style: HUDStyle) -> Bool {
    style.fixedAnchor == nil
  }

  /// Each row's caption describes ITS OWN control: it is republished as the
  /// control's accessibility hint.
  static func positionCaption(for style: HUDStyle, kind: Kind) -> String {
    // Vertical's rows pick a side, not a corner.
    if style == .vertical {
      return switch kind {
      case .brightness: "Left or right picks the side; Vertical sits at its middle. Contrast uses this position too."
      case .volume:
        "Left or right picks the side; Vertical sits at its middle. Mute uses this position too. "
          + "The indicator appears on the display the keys act on."
      }
    }
    return switch style.fixedAnchor {
    case nil:
      switch kind {
      case .brightness: "Contrast uses this position too."
      case .volume: "Mute uses this position too. The indicator appears on the display the keys act on."
      }
    case .bottomCenter: "\(label(for: style)) sits where macOS put it."
    case .center: "This style sits at the center of the screen."
    case .topEdge: "The Island lives on the notch."
    // Exhaustiveness only: no style's fixed anchor is a chosen position or a side.
    case .position, .sideCenter: positionCaption(for: .system, kind: kind)
    }
  }
}
