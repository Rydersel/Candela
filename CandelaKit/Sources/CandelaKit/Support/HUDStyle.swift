/// How the on-screen indicator draws, app-level like its two position keys.
/// Raw values are shipped on-disk schema: add cases, never renumber.
///
/// The geometry each case names is pinned so the real indicator and the Menu
/// Bar pane's preview draw the same thing from one definition.
public enum HUDStyle: Int, Sendable, CaseIterable {
  /// The shipped look, styled after the native macOS pill: name label over an
  /// icon-flanked continuous bar.
  case system = 0
  /// The same pill chrome with the bar as 16 discrete segments.
  case segments = 1
  /// A smaller, name-less pill: icons and the bar only.
  case compact = 2
  /// The 200 pt box macOS drew from OS X through Sonoma, where macOS drew it.
  case classic = 3
  /// The same box at the screen's centre.
  case classicCentered = 4
  /// The small square macOS 15 drew: glyph over a thin bar.
  case sequoia = 5
  /// A tall capsule filling from the bottom.
  case vertical = 6
  /// A circular gauge, arc from twelve o'clock.
  case ring = 7
  /// The notch widens and drops; the value traces its outline.
  case islandDrop = 8
  /// The value traces the whole top edge of the screen around the notch; the
  /// information sits bare beside the notch.
  case islandEdge = 9
  /// Island (edge) with the information on glass capsules.
  case islandEdgeCapsules = 10

  /// Reading order for pickers. Consumed instead of raw order so a future case
  /// can slot in without renumbering raws.
  public static let pickerOrder: [HUDStyle] = [
    .system, .segments, .compact, .vertical, .ring,
    .classic, .classicCentered, .sequoia,
    .islandDrop, .islandEdge, .islandEdgeCapsules,
  ]

  /// nil: the two position pickers apply. Otherwise the style's one home.
  /// 140 pt is where macOS draws its own box, measured on a 1169 pt screen.
  public var fixedAnchor: HUDAnchor? {
    switch self {
    case .system, .segments, .compact, .vertical, .ring: nil
    case .classic, .sequoia: .bottomCenter(inset: 140)
    case .classicCentered: .center
    case .islandDrop, .islandEdge, .islandEdgeCapsules: .topCenter
    }
  }

  public var isIsland: Bool {
    switch self {
    case .islandDrop, .islandEdge, .islandEdgeCapsules: true
    default: false
    }
  }
}
