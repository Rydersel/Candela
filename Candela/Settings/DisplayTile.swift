import SwiftUI

/// One display on the arrangement map, drawn to scale.
///
/// It carries **no geometry of its own** — the canvas sizes and positions it —
/// so it is a pure function of its appearance inputs and there is nothing to
/// keep in sync across a SwiftUI diff.
///
/// **Aspect ratio is never asserted here.** The frame the canvas gives this view
/// *is* `width × height` from `CanvasTransform`, so the tile's shape is the
/// display's shape by construction. An `.aspectRatio` modifier would be a
/// second, disagreeing opinion about a shape that is already correct.
///
/// Every colour is semantic (drag-canvas §7.2): `.fill.tertiary`, `.separator`,
/// `.tint`, and the one literal — red — that has a meaning no hierarchical grey
/// carries. Light and dark then both work without a second code path, which is
/// what `dark-mode.md` asks for. Red is never the *only* signal: an invalid drop
/// also draws a 2 pt border and puts a sentence under the canvas.
struct DisplayTile: View {
  let name: String
  let pointSize: String
  let mirroredCount: Int
  let isMain: Bool
  let isSelected: Bool
  /// Keyboard focus, drawn HERE rather than by AppKit's focus effect.
  ///
  /// **Measured 2026-08-05.** The system ring keeps the geometry it was drawn
  /// with: after an arrangement change rescales the map, the ring stayed at the
  /// tile's *previous* size — pinned in the pixels of `05-canvas-pending.png`,
  /// where the ring ended 58 px short of the tile it was supposed to be
  /// hugging. A ring pointing at a region that is not the tile is worse than no
  /// ring at all, and it fails for exactly the users the keyboard route exists
  /// for. Drawn as part of the tile it cannot go stale, because it has no
  /// geometry of its own to remember.
  let isFocused: Bool
  let isInvalid: Bool
  let isDragging: Bool

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        RoundedRectangle(cornerRadius: 5).fill(fill)
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(border, lineWidth: isSelected || isInvalid ? 2 : 1)

        // INSET, so it reads as a ring inside the tile rather than as a second
        // opinion about the tile's edge — adjacent displays share an edge, and
        // a ring drawn on it would sit half over the neighbour. Suppressed when
        // the tile is already selected: the selection border marks the same
        // tile, and two tint rings on one tile is noise, not information.
        if isFocused, !isSelected {
          RoundedRectangle(cornerRadius: 3)
            .strokeBorder(.tint, lineWidth: 2)
            .padding(2)
        }

        // The menu-bar strip: the platform's own signifier for "this is the main
        // display", and what people actually look for when they ask where their
        // menu bar went. **Drawn, never dragged** (AR9) — it is not a separate
        // gesture target, so there is no second drag semantic on this tile.
        if isMain {
          VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
              .fill(.primary.opacity(0.45))
              .frame(height: max(2, min(5, proxy.size.height * 0.06)))
              .padding(.horizontal, 3)
              .padding(.top, 3)
            Spacer(minLength: 0)
          }
        }

        // Progressive disclosure by tile HEIGHT (layout.md). A 1470×956 built-in
        // beside a 3440×1440 ultrawide can come out 40 pt tall, and three
        // stacked labels in 40 pt is a smudge rather than information.
        if proxy.size.height >= 34 {
          VStack(spacing: 1) {
            Text(verbatim: name).font(.caption).lineLimit(1).truncationMode(.middle)
            if proxy.size.height >= 52 {
              Text(verbatim: pointSize).font(.caption2).foregroundStyle(.secondary)
            }
            if mirroredCount > 0, proxy.size.height >= 68 {
              Text("Mirrored").font(.caption2).foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 4)
        }
      }
    }
    .opacity(isDragging ? 0.9 : 1)
    // The only elevation cue in the view, and it is on the one thing that is
    // genuinely lifted.
    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6, y: 2)
    // The tooltip is the escape hatch for a tile too short to show its own
    // labels — the name and size are then reachable without resizing anything.
    .help(Text(verbatim: "\(name) — \(pointSize)"))
  }

  private var fill: AnyShapeStyle {
    if isInvalid { return AnyShapeStyle(Color.red.opacity(0.16)) }
    if isSelected { return AnyShapeStyle(.tint.opacity(0.18)) }
    return AnyShapeStyle(.fill.tertiary)
  }

  private var border: AnyShapeStyle {
    if isInvalid { return AnyShapeStyle(Color.red) }
    if isSelected { return AnyShapeStyle(.tint) }
    return AnyShapeStyle(.separator)
  }
}
