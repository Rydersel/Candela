import AppKit
import SwiftUI

/// What every tile on the map says — decided ONCE for the whole canvas, never
/// per tile.
///
/// **The defect this type exists to prevent.** Disclosure used to be a per-tile
/// question ("is *this* tile 52 pt tall?"), which produced a map where three
/// tiles read `Display 76 / 1680 × 1050` and the fourth, 12 pt shorter, read
/// only `Display 77`. Two adjacent tiles disagreeing about what a tile carries
/// reads as a rendering bug, not as a decision. So the level is chosen for the
/// **map**: the richest level *every* tile can carry, in the fonts the tile will
/// actually draw with. Uniformity is then structural — one value reaches every
/// tile — rather than a threshold every caller has to get right.
///
/// The level is honest about running out of room in this order: full size →
/// one type size down → name only → nothing. The name outranks the resolution
/// when only one line fits, because the name is what every sentence in the pane
/// refers to and the tile's *shape* already carries the resolution to scale.
/// Nothing is ever truncated to fit: a width that cannot hold `1680 × 1050`
/// drops the line rather than drawing `16…50`.
///
/// **VoiceOver is untouched by any of this.** The canvas states the name and the
/// resolution in the tile's accessibility label unconditionally, and the tooltip
/// carries both as well, so a dropped line is a visual decision only.
struct TileLabelStyle: Equatable, Sendable {
  enum Detail: Sendable { case none, name, nameAndSize }

  let detail: Detail
  /// Point size of the name line. The resolution line is always
  /// `Self.secondarySize` — it is secondary at every level.
  let nameSize: Double
  /// Whether tiles that mirror others say so. Decided over the mirrored tiles
  /// **only**: a tile with no slaves has no third line to omit, so including it
  /// in the vote would let a display that says nothing about mirroring silence
  /// one that has something to say.
  let showsMirrored: Bool

  static let secondarySize: Double = 10
  static let horizontalPadding: Double = 3
  static let bottomPadding: Double = 2

  /// The one place a tile's label geometry is described. `fitting` and the view
  /// both read it, so the size a level is *tested* at is the size it is *drawn*
  /// at — there is no second opinion to drift.
  static func labelHeight(detail: Detail, nameSize: Double, mirrored: Bool) -> Double {
    switch detail {
    case .none: 0
    case .name: lineHeight(nameSize)
    case .nameAndSize:
      lineHeight(nameSize) + lineHeight(secondarySize)
        + (mirrored ? lineHeight(secondarySize) : 0)
    }
  }

  /// The band at the top of a tile that the menu-bar strip occupies, reserved on
  /// **every** tile rather than only on the main one. Which display is main
  /// changes without the map resizing, so a band reserved only when `isMain`
  /// would let one button press push a name into the strip it was clearing.
  static func stripBand(forHeight height: Double) -> Double {
    stripInset + stripHeight(forHeight: height)
  }

  static func stripHeight(forHeight height: Double) -> Double {
    max(2, min(5, height * 0.06))
  }

  static let stripInset: Double = 3

  private static func lineHeight(_ size: Double) -> Double {
    let font = NSFont.systemFont(ofSize: size)
    return (font.ascender - font.descender + font.leading).rounded(.up)
  }

  /// Measured **semibold**, which is the weight a SELECTED tile draws its name
  /// in. Measuring the regular weight would let clicking a tile truncate a name
  /// that fitted a moment earlier.
  private static func nameWidth(_ name: String, size: Double) -> Double {
    let font = NSFont.systemFont(ofSize: size, weight: .semibold)
    return (name as NSString).size(withAttributes: [.font: font]).width
  }

  private static func secondaryWidth(_ text: String) -> Double {
    let font = NSFont.systemFont(ofSize: secondarySize)
    return (text as NSString).size(withAttributes: [.font: font]).width
  }

  /// Everything the decision needs from one tile.
  struct Metrics {
    let size: CGSize
    let name: String
    let pointSize: String
    let isMirrored: Bool
  }

  /// Richest first. A step DOWN in type size is tried before a line is dropped —
  /// it buys little height (10 pt and 11 pt lines differ by one point) but ~8 %
  /// of width, and width is what a tall, narrow display runs out of first.
  private static let ladder: [(detail: Detail, nameSize: Double)] = [
    (.nameAndSize, 11), (.nameAndSize, secondarySize), (.name, 11), (.name, secondarySize),
  ]

  static func fitting(_ tiles: [Metrics]) -> TileLabelStyle {
    guard !tiles.isEmpty else {
      return TileLabelStyle(detail: .none, nameSize: 11, showsMirrored: false)
    }
    for step in ladder {
      let everyTileFits = tiles.allSatisfy {
        fits(step.detail, step.nameSize, $0, mirrored: false)
      }
      guard everyTileFits else { continue }
      let mirrored = tiles.filter(\.isMirrored)
      let showsMirrored = step.detail == .nameAndSize && !mirrored.isEmpty
        && mirrored.allSatisfy { fits(step.detail, step.nameSize, $0, mirrored: true) }
      return TileLabelStyle(
        detail: step.detail, nameSize: step.nameSize, showsMirrored: showsMirrored
      )
    }
    return TileLabelStyle(detail: .none, nameSize: 11, showsMirrored: false)
  }

  private static func fits(
    _ detail: Detail, _ nameSize: Double, _ tile: Metrics, mirrored: Bool
  ) -> Bool {
    let needed = stripBand(forHeight: tile.size.height)
      + labelHeight(detail: detail, nameSize: nameSize, mirrored: mirrored) + bottomPadding
    guard tile.size.height >= needed else { return false }

    var width = nameWidth(tile.name, size: nameSize)
    if detail == .nameAndSize { width = max(width, secondaryWidth(tile.pointSize)) }
    if mirrored { width = max(width, secondaryWidth(mirroredLabel)) }
    return tile.size.width >= width + 2 * horizontalPadding
  }

  static let mirroredLabel = "Mirrored"
}

/// One display on the arrangement map, drawn to scale.
///
/// It carries **no geometry of its own** — the canvas sizes and positions it,
/// and the canvas also hands it the `TileLabelStyle` every other tile is using —
/// so it is a pure function of its appearance inputs and there is nothing to
/// keep in sync across a SwiftUI diff.
///
/// **Aspect ratio is never asserted here.** The frame the canvas gives this view
/// *is* `width × height` from `CanvasTransform`, so the tile's shape is the
/// display's shape by construction. An `.aspectRatio` modifier would be a
/// second, disagreeing opinion about a shape that is already correct.
///
/// Every colour is semantic (drag-canvas §7.2): `.fill.tertiary`, `.separator`,
/// `.tint`, the system's own `keyboardFocusIndicatorColor`, and the one literal
/// — red — that has a meaning no hierarchical grey carries. Light and dark then
/// both work without a second code path, which is what `dark-mode.md` asks for.
/// Red is never the *only* signal: an invalid drop also draws a 2 pt border and
/// puts a sentence under the canvas.
struct DisplayTile: View {
  let name: String
  let pointSize: String
  let mirroredCount: Int
  let isMain: Bool
  /// **Selection is a choice**, and the one "Use as Main Display" acts on. Drawn
  /// as a *state of the tile* — tinted fill, tinted edge, semibold name — so it
  /// cannot be read as the ring the keyboard leaves behind it.
  let isSelected: Bool
  /// **Focus is where the keyboard is**, not a choice: Space promotes a focused
  /// tile to the selection. Drawn as the system's own keyboard ring
  /// (`keyboardFocusIndicatorColor`, the accent at 50 %) and changing nothing
  /// else about the tile, because that is what the platform's focus indicator
  /// means. The two states used to share one 2 pt tint ring, which put a tile
  /// that read as "selected" beside a greyed-out "Use as Main Display" — the
  /// pane looked broken at rest, and the honest reading was that focus had been
  /// drawn as selection.
  ///
  /// Both are drawn when both are true. Suppressing the ring on a selected tile
  /// made Tab appear to lose the keyboard as soon as it reached the selection.
  ///
  /// Drawn HERE rather than by AppKit's focus effect. **Measured 2026-08-05.**
  /// The system ring keeps the geometry it was drawn with: after an arrangement
  /// change rescaled the map, the ring stayed at the tile's *previous* size —
  /// pinned in the pixels of `05-canvas-pending.png`, where the ring ended 58 px
  /// short of the tile it was supposed to be hugging. A ring pointing at a
  /// region that is not the tile is worse than no ring at all, and it fails for
  /// exactly the users the keyboard route exists for. Drawn as part of the tile
  /// it cannot go stale, because it has no geometry of its own to remember.
  let isFocused: Bool
  let isInvalid: Bool
  let isDragging: Bool
  /// The map's decision, not this tile's. See `TileLabelStyle`.
  let labels: TileLabelStyle

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        RoundedRectangle(cornerRadius: 5).fill(fill)
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(border, lineWidth: isSelected || isInvalid ? 2 : 1)

        // INSET, so it reads as a ring inside the tile rather than as a second
        // opinion about the tile's edge — adjacent displays share an edge, and
        // a ring drawn on it would sit half over the neighbour.
        if isFocused {
          RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            .padding(1.5)
        }

        // The menu-bar strip: the platform's own signifier for "this is the main
        // display", and what people actually look for when they ask where their
        // menu bar went. **Drawn, never dragged** (AR9) — it is not a separate
        // gesture target, so there is no second drag semantic on this tile.
        if isMain {
          VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
              .fill(.primary.opacity(0.45))
              .frame(height: TileLabelStyle.stripHeight(forHeight: proxy.size.height))
              .padding(.horizontal, 3)
              .padding(.top, TileLabelStyle.stripInset)
            Spacer(minLength: 0)
          }
        }

        labelStack(in: proxy.size)
      }
    }
    .opacity(isDragging ? 0.9 : 1)
    // The only elevation cue in the view, and it is on the one thing that is
    // genuinely lifted.
    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6, y: 2)
    // The escape hatch for a map whose tiles are too small to say everything —
    // the name and the size are then reachable without resizing anything.
    .help(Text(verbatim: "\(name) — \(pointSize)"))
  }

  /// Centred in the space BELOW the menu-bar strip's band, never in the tile:
  /// the band is reserved on every tile (`TileLabelStyle.stripBand`), so the
  /// name clears the strip whichever display is main, and the height
  /// `TileLabelStyle.fitting` tested is the height this stack occupies.
  @ViewBuilder private func labelStack(in size: CGSize) -> some View {
    if labels.detail != .none {
      VStack(spacing: 0) {
        Color.clear.frame(height: TileLabelStyle.stripBand(forHeight: size.height))
        Spacer(minLength: 0)
        VStack(spacing: 0) {
          Text(verbatim: name)
            .font(.system(size: labels.nameSize, weight: isSelected ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.middle)
          if labels.detail == .nameAndSize {
            Text(verbatim: pointSize)
              .font(.system(size: TileLabelStyle.secondarySize))
              .foregroundStyle(.secondary)
              .lineLimit(1)
            if labels.showsMirrored, mirroredCount > 0 {
              Text(verbatim: TileLabelStyle.mirroredLabel)
                .font(.system(size: TileLabelStyle.secondarySize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
        Spacer(minLength: 0)
        Color.clear.frame(height: TileLabelStyle.bottomPadding)
      }
      // Fills the tile so the two `Spacer`s can centre the text between the
      // reserved band and the bottom padding. Without it the stack sizes to its
      // content and the ZStack centres it over the strip instead.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, TileLabelStyle.horizontalPadding)
    }
  }

  private var fill: AnyShapeStyle {
    if isInvalid { return AnyShapeStyle(Color.red.opacity(0.16)) }
    if isSelected { return AnyShapeStyle(.tint.opacity(0.30)) }
    return AnyShapeStyle(.fill.tertiary)
  }

  private var border: AnyShapeStyle {
    if isInvalid { return AnyShapeStyle(Color.red) }
    if isSelected { return AnyShapeStyle(.tint) }
    return AnyShapeStyle(.separator)
  }
}
