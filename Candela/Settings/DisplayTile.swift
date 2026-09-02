import AppKit
import SwiftUI

/// What every tile on the map says, decided ONCE for the whole canvas and never
/// per tile. Asking per tile produced a map where three tiles read `Display 76 /
/// 1680 × 1050` and the fourth, 12 pt shorter, read only `Display 77`, which
/// reads as a rendering bug rather than a decision. So the level is the richest
/// one EVERY tile can carry, in the fonts the tiles actually draw with.
///
/// It runs out of room in this order: full size, one type size down, name only,
/// nothing. The name outranks the resolution because the tile's shape already
/// carries the resolution to scale. Nothing is truncated to fit: a width that
/// cannot hold `1680 × 1050` drops the line rather than drawing `16…50`.
///
/// VoiceOver is untouched. The canvas states the name and the resolution in the
/// tile's accessibility label unconditionally, so a dropped line is visual only.
struct TileLabelStyle: Equatable, Sendable {
  enum Detail: Sendable { case none, name, nameAndSize }

  let detail: Detail
  /// Point size of the name line. The resolution line is always
  /// `Self.secondarySize`; it is secondary at every level.
  let nameSize: Double
  /// Whether tiles that mirror others say so. Decided over the mirrored tiles
  /// ONLY: a tile with no slaves has no third line to omit, so counting it would
  /// let a display with nothing to say silence one that has something.
  let showsMirrored: Bool

  static let secondarySize: Double = 10
  static let horizontalPadding: Double = 3
  static let bottomPadding: Double = 2

  /// The one place a tile's label geometry is described: `fitting` and the view
  /// both read it, so a level is tested at the size it is drawn at.
  static func labelHeight(detail: Detail, nameSize: Double, mirrored: Bool) -> Double {
    switch detail {
    case .none: 0
    case .name: lineHeight(nameSize)
    case .nameAndSize:
      lineHeight(nameSize) + lineHeight(secondarySize)
        + (mirrored ? lineHeight(secondarySize) : 0)
    }
  }

  /// The band the menu-bar strip occupies plus the gap under it, reserved on
  /// EVERY tile rather than only the main one. Which display is main changes
  /// without the map resizing, so a band reserved only when `isMain` would let
  /// one button press push a name into the strip it was clearing.
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

  /// Measured SEMIBOLD, the weight a selected tile draws its name in: measuring
  /// the regular weight would let clicking a tile truncate a name that fitted a
  /// moment earlier.
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

  /// Richest first. A step DOWN in type size is tried before a line is dropped:
  /// it buys little height but about 8% of width, and width is what a tall,
  /// narrow display runs out of first.
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

/// One display on the arrangement map, drawn to scale as a lit object.
///
/// It carries NO geometry of its own: the canvas sizes and positions it and
/// hands it the `TileLabelStyle` every other tile is using, so there is nothing
/// to keep in sync across a SwiftUI diff.
///
/// Aspect ratio is never asserted here. The frame the canvas gives this view IS
/// `width × height` from `CanvasTransform`, and the glass is drawn to that frame
/// exactly: the map's whole claim is that abutting displays touch, and a face
/// inset inside its own rect would put a gap between two displays the layout
/// says are adjacent.
///
/// The face is the flow's glyph, never a second drawing of one. Colour is
/// never the only signal: an invalid drop also draws a 2 pt border and a
/// sentence under the canvas, a virtual display says so in its name and its
/// accessibility value, and the main display's menu-bar strip is a shape.
///
/// `@MainActor` because a `View`'s computed properties other than `body` are
/// nonisolated under complete concurrency, and the virtual-display tint is read
/// from the main-actor registry rather than copied.
@MainActor
struct DisplayTile: View {
  let name: String
  let pointSize: String
  let mirroredCount: Int
  let isMain: Bool
  /// Selection is a choice, and the one "Use as Main Display" acts on. Drawn as
  /// a state of the tile, the glass lit and the name semibold, so it cannot be
  /// read as the ring the keyboard leaves behind it.
  let isSelected: Bool
  /// Focus is where the keyboard is, not a choice: Space promotes a focused tile
  /// to the selection. Drawn as the system's own keyboard ring and changing
  /// nothing else about the tile, because that is what the platform's focus
  /// indicator means. Sharing one tint ring with selection put a tile that read
  /// as "selected" beside a greyed-out "Use as Main Display".
  ///
  /// Both are drawn when both are true: suppressing the ring on a selected tile
  /// made Tab appear to lose the keyboard as soon as it reached the selection.
  ///
  /// Drawn HERE rather than by AppKit's focus effect. MEASURED 2026-08-05: the
  /// system ring keeps the geometry it was drawn with, so after an arrangement
  /// change rescaled the map it stayed at the tile's previous size, ending 58 px
  /// short of the tile it was supposed to be hugging. Drawn as part of the tile
  /// it has no geometry of its own to go stale.
  let isFocused: Bool
  let isInvalid: Bool
  let isDragging: Bool
  /// A display that exists in software only: one of Candela's own slots, or a
  /// foreign synthetic display (Sidecar, AirPlay, a dummy). Drawn in the Virtual
  /// Displays pane's purple, never as the ONLY signal: the name says what it is,
  /// and the canvas appends "virtual display" to the accessibility value.
  var isVirtual: Bool = false
  /// The built-in display, which is drawn as a laptop everywhere it is depicted:
  /// screen over a deck, the way the machine actually closes.
  var isBuiltIn: Bool = false
  /// The map's decision, not this tile's. See `TileLabelStyle`.
  let labels: TileLabelStyle

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        glass(in: proxy.size)

        // Red is a border rather than a tint on the glass, so it reads at the
        // tile's edge where the overlap it is reporting actually is.
        if isInvalid {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.red, lineWidth: 2)
        }

        // INSET: adjacent displays share an edge, and a ring drawn on it would
        // sit half over the neighbour.
        if isFocused {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            .padding(1.5)
        }

        labelStack(in: proxy.size)
      }
    }
    .opacity(isDragging ? 0.9 : 1)
    // A shadow at rest is stage light, not an elevation claim; the dragged tile
    // is the one genuinely lifted, and it deepens.
    .shadow(color: .black.opacity(shadowDepth), radius: 10, y: 5)
    // The escape hatch when tiles are too small to say everything: the name and
    // the size stay reachable.
    .help(Text(verbatim: "\(name) (\(pointSize))"))
  }

  /// The face, drawn by the glyphs the guided setup flow and the display heroes
  /// already use. Aspect comes from the FRAME, not the display's mode: the
  /// frame is what `CanvasTransform` put there, so asking the glyph for that
  /// aspect makes the glass fill the rect instead of fitting inside it.
  @ViewBuilder private func glass(in size: CGSize) -> some View {
    // A layout pass before the canvas has sized anything hands this a zero, and
    // the glyphs divide by it.
    let aspect = max(0.01, Double(max(1, size.width) / max(1, size.height)))
    if isBuiltIn {
      let box = Self.laptopBox(fitting: size)
      LaptopGlyph(
        aspect: aspect, accent: faceAccent, lit: litLevel, faceOverlay: menuBarStrip(in: size)
      )
      .frame(width: box.width, height: box.height)
      // The box's extra height is all deck, and the deck hangs BELOW the glass.
      .offset(y: (box.height - size.height) / 2)
      // The second frame reports the TILE's size back to the stack, so the
      // overhang paints outside the tile without laying anything out around it.
      // Measured: without it the box's size became the ZStack's, pushing the
      // focus ring, the invalid border and the labels off their display.
      .frame(width: size.width, height: size.height)
    } else {
      DisplayGlyph(
        aspect: aspect, accent: faceAccent, lit: litLevel,
        faceOverlay: menuBarStrip(in: size), showsStand: false, showsReflection: false
      )
    }
  }

  /// The menu bar drawn on the main display's face: the platform's own signifier
  /// for "this is the main display". Drawn, never dragged, so there is no
  /// second drag semantic on this tile. Handed to the glyph as its face overlay,
  /// which clips it to the glass; the band it occupies is reserved on EVERY tile
  /// (`TileLabelStyle.stripBand`), so a name never lands under it.
  private func menuBarStrip(in size: CGSize) -> AnyView? {
    guard isMain else { return nil }
    return AnyView(
      VStack(spacing: 0) {
        Rectangle()
          .fill(Color.white.opacity(0.55))
          .frame(height: TileLabelStyle.stripHeight(forHeight: size.height))
        Spacer(minLength: 0)
      }
    )
  }

  /// The box that puts `LaptopGlyph`'s glass exactly on the tile's rect. That
  /// view fits its face inside the box it is given and hangs a deck under it, so
  /// a box the size of the rect would inset the glass; this inverts it.
  ///
  /// It mirrors three of `LaptopGlyph`'s numbers (the constants below) and
  /// depends on a fourth: that view's deck width, `min(bounds.width, faceWidth *
  /// 1.18)`, which the box may ignore only because `1 / 0.86` is 1.163 and the
  /// `min` therefore takes the box width. Raise the face share past `1 / 1.18`
  /// and the 1.18 starts to bind, and the deck stops widening with the glass.
  /// Change any of them there and this has to follow, or the built-in's glass
  /// stops meeting its neighbours.
  private static func laptopBox(fitting face: CGSize) -> CGSize {
    CGSize(
      width: face.width / laptopFaceWidthShare,
      height: max(face.height + laptopMinimumDeck, face.height / (1 - laptopDeckHeightShare))
    )
  }

  private static let laptopFaceWidthShare: Double = 0.86
  private static let laptopDeckHeightShare: Double = 0.075
  private static let laptopMinimumDeck: Double = 5

  /// Centred in the space BELOW the strip's band, never in the tile: the band is
  /// reserved on every tile, so the name clears the strip whichever display is
  /// main, and the height `TileLabelStyle.fitting` tested is the one this stack
  /// occupies.
  @ViewBuilder private func labelStack(in size: CGSize) -> some View {
    if labels.detail != .none {
      VStack(spacing: 0) {
        Color.clear.frame(height: TileLabelStyle.stripBand(forHeight: size.height))
        Spacer(minLength: 0)
        VStack(spacing: 0) {
          Text(verbatim: name)
            .font(.system(size: labels.nameSize, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(SettingsTheme.titleColor)
            .lineLimit(1)
            .truncationMode(.middle)
          if labels.detail == .nameAndSize {
            Text(verbatim: pointSize)
              .font(.system(size: TileLabelStyle.secondarySize))
              .foregroundStyle(SettingsTheme.bodyColor)
              .lineLimit(1)
            if labels.showsMirrored, mirroredCount > 0 {
              Text(verbatim: TileLabelStyle.mirroredLabel)
                .font(.system(size: TileLabelStyle.secondarySize))
                .foregroundStyle(SettingsTheme.bodyColor)
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

  /// What the glass is lit in. The selected tile takes the destination's own
  /// accent, so the map is lit by the same source as the canvas behind it; a
  /// virtual display takes the Virtual Displays pane's tint, read from the
  /// registry rather than copied, so the tile and its sidebar row agree.
  private var faceAccent: Color {
    if isInvalid { return .red }
    if isSelected { return lighting.accent }
    if isVirtual { return SettingsRegistry.descriptor(for: .virtualDisplays).accent.accent }
    return Color(white: 0.62)
  }

  /// Full brightness for the tile being acted on, a dim standby for the rest:
  /// selection reads from the light rather than from a halo.
  private var litLevel: Double { isSelected || isInvalid ? 1 : 0.42 }

  private var shadowDepth: Double {
    if isDragging { return 0.45 }
    return isSelected ? 0.4 : 0.25
  }
}
