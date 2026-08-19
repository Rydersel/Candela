import CandelaKit
import CoreGraphics
import SwiftUI

/// The drag-to-arrange mini-map (drag-canvas §5.2).
///
/// **Fixed size on purpose.** A `GeometryReader`-driven canvas would recompute
/// the transform as the settings window resizes, which is fine at rest and wrong
/// mid-drag: the map would rescale under the pointer. A fixed box also makes the
/// screenshot checks reproducible, which is the only way this view's appearance
/// gets verified at all.
///
/// Nothing here re-derives geometry. Every conversion between display space and
/// canvas space goes through `CanvasTransform`, every snap through
/// `ArrangementSnapper`, every validity question through `ArrangementRules`, and
/// the whole drag decision through `ArrangementDragPolicy` — the app target owns
/// the gesture plumbing and nothing else.
@MainActor
struct ArrangementCanvasView: View {
  /// The live layout, owned by `ArrangementCoordinator` and read from
  /// `CGDisplayBounds` over the ONLINE display list (AR1). Never mutated here.
  let arrangement: DisplayArrangement
  /// The user's name for a display, or "" when nothing can name it. Resolution
  /// belongs to the surface, so the canvas asks rather than deciding.
  let name: (CGDirectDisplayID) -> String
  /// Is this a software-only display: one of Candela's own, or a foreign
  /// synthetic one. Asked, not decided, for `name`'s reason; the tile draws
  /// virtual displays in the Virtual Displays pane's purple. Defaults to "no"
  /// so previews and callers without an opinion keep compiling.
  var isVirtual: (CGDirectDisplayID) -> Bool = { _ in false }
  /// Is this tile a synthesized size: a virtual display whose picture IS a
  /// physical panel's, standing in for it while the size is engaged (SS12).
  ///
  /// The tile is presented as that panel and nothing else: `name` resolves the
  /// panel's name, and here the two decorations that would give the arrangement
  /// away are dropped. It is not drawn as a virtual display, because the person
  /// looking at it is looking at their monitor; and it carries no mirror count,
  /// because the display it would be counting is the very panel the tile is
  /// already naming. It stays movable and keeps its own ID: the virtual display
  /// owns the desktop, so it is the member of the pair a layout can move (AR6).
  /// Asked, not decided, for `name`'s reason.
  var isSynthesisPair: (CGDirectDisplayID) -> Bool = { _ in false }
  @Binding var selection: CGDirectDisplayID?
  /// Called ONLY with a valid layout that differs from the current one. Starts
  /// the preview and its countdown.
  let onPropose: (DisplayArrangement) -> Void
  /// Called when a drop was refused (AR7), with every problem that refused it,
  /// so the pane can say what is wrong in words. Colour alone is never the
  /// signal — and a red border says "no" without saying why.
  let onRefuse: ([ArrangementProblem]) -> Void

  @State private var drag: TileDrag?
  @FocusState private var focused: CGDirectDisplayID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Sized to fit the DETAIL column at the settings window's minimum width, not
  /// at its ideal one: 720 pt of window, less a 190 pt sidebar, less the grouped
  /// `Form`'s own insets, leaves a little under 500 pt. A canvas wider than that
  /// is clipped by the form row at any window size the user is allowed to reach,
  /// and a map that loses its right-hand display is worse than a smaller map.
  static let canvasSize = CanvasSize(width: 480, height: 290)
  private static let spaceName = "candela.arrangement.canvas"
  private static let margin: Double = 14

  /// A canvas-space translation this view refuses to convert.
  ///
  /// `CanvasTransform.displayDistance` divides by a scale that can be ~0.05 and
  /// then calls `Int(_:)`, which **traps** on a non-finite or astronomically
  /// large value, and `ArrangementDragPolicy.propose` deliberately does not
  /// guard it — a policy cannot know what its caller's coordinate space means.
  /// This is not a claim about what `DragGesture` produces; it is a boundary
  /// this view can enforce and the policy cannot, at the cost of one comparison
  /// per frame. The bound is far outside any reachable drag: the canvas is
  /// 480 pt wide.
  private static let translationLimit: Double = 1_000_000

  /// Everything a drag needs, as ONE optional value — not three `@State`
  /// properties that have to be kept in agreement. SwiftUI diffs an optional
  /// cleanly, and "a drag is in progress" then cannot be true while the tile it
  /// is about is unknown.
  struct TileDrag: Equatable {
    let id: CGDirectDisplayID
    /// The layout as of drag START. `DragGesture`'s translation is measured from
    /// the same instant, so folding the policy's own output back in would apply
    /// the move again on every frame.
    let baseline: DisplayArrangement
    /// **FROZEN at drag start (AR2).** The transform is fitted to the layout's
    /// bounds, which the dragged tile changes — recomputing it here would
    /// rescale the whole map under the pointer on every frame.
    let transform: CanvasTransform
    var proposal: ArrangementProposal
  }

  // MARK: - Derived state

  /// Rendered, never mirrored: there is no copy of the layout to fall out of
  /// step with the proposal.
  private var displayed: DisplayArrangement { drag?.proposal.arrangement ?? arrangement }
  private var transform: CanvasTransform { drag?.transform ?? restingTransform }

  private var restingTransform: CanvasTransform {
    CanvasTransform.fitting(arrangement.bounds, in: Self.canvasSize, margin: Self.margin)
  }

  /// How much EVERY tile says, decided once from the tiles as they are about to
  /// be drawn. See `TileLabelStyle`: the alternative — each tile deciding from
  /// its own height — is what let one short tile drop its resolution beside
  /// three that kept theirs, which reads as a rendering bug rather than as a
  /// decision. Tile *sizes* do not change during a drag (only origins do), so
  /// this cannot flicker under the pointer.
  private var labelStyle: TileLabelStyle {
    TileLabelStyle.fitting(displayed.tiles.map { tile in
      let rect = transform.canvasRect(tile.rect)
      return TileLabelStyle.Metrics(
        size: CGSize(width: rect.width, height: rect.height),
        name: label(for: tile),
        pointSize: pointSize(tile),
        isMirrored: mirroredCount(tile) > 0
      )
    })
  }

  /// The snap guides for where the tile is, plus the landing guide for where it
  /// goes if it cannot stay there. Both come from the one proposal, so the edge
  /// drawn is always the edge the release commits to.
  private var guideLines: [SnapLine] {
    guard let drag else { return [] }
    return drag.proposal.lines + (drag.proposal.landing?.lines ?? [])
  }

  /// Every display NAMED in a problem, not just the dragged one (§3.5): moving
  /// the middle display of a row strands the far one, and the user has to see
  /// which displays they broke rather than only which one they are holding.
  ///
  /// A drop with a landing reddens nothing. The position under the pointer is
  /// not legal and the proposal says so, but the release is going to succeed:
  /// the guide names where the display goes. Red is reserved for the drop that
  /// really will spring back, or it stops meaning anything.
  private var invalidIDs: Set<CGDirectDisplayID> {
    guard let drag, !drag.proposal.isValid, drag.proposal.landing == nil else { return [] }
    return Set(drag.proposal.problems.flatMap { problem -> [CGDirectDisplayID] in
      switch problem {
      case let .overlap(lhs, rhs): [lhs, rhs]
      case let .disconnected(id): [id]
      }
    })
  }

  // MARK: - Body

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10)
        .fill(.quinary)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

      ForEach(displayed.tiles) { tile in
        tileView(tile)
      }

      ForEach(Array(guideLines.enumerated()), id: \.offset) { _, line in
        guide(line)
      }
    }
    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
    .coordinateSpace(.named(Self.spaceName))
    .contentShape(Rectangle())
    // A click on the background deselects. Without it the only way out of a
    // selection is to select something else, and "Use as Main Display" then has
    // no off state.
    .onTapGesture { selection = nil }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Display arrangement")
  }

  // MARK: - Tile

  @ViewBuilder private func tileView(_ tile: ArrangementTile) -> some View {
    let rect = transform.canvasRect(tile.rect)
    let isDragging = drag?.id == tile.id

    DisplayTile(
      name: label(for: tile),
      pointSize: pointSize(tile),
      mirroredCount: mirroredCount(tile),
      isMain: isMain(tile.id),
      isSelected: selection == tile.id,
      isFocused: focused == tile.id,
      isInvalid: invalidIDs.contains(tile.id),
      isDragging: isDragging,
      isVirtual: presentsAsVirtual(tile.id),
      labels: labelStyle
    )
    // ORDER IS LOAD-BEARING, and this is the top-ranked risk in the feature.
    // `.position` returns a view that fills the WHOLE parent and places its
    // child at a point, so anything attached AFTER it hit-tests the entire
    // canvas: every tile's drag gesture would cover the map and the topmost
    // `zIndex` would silently win everywhere. Symptom: dragging any empty area
    // moves one particular display. Interaction goes on the frame-sized view;
    // `.position`, `.animation` and `.zIndex` go outside it.
    .frame(width: rect.width, height: rect.height)
    .contentShape(RoundedRectangle(cornerRadius: 5))
    .focusable()
    .focused($focused, equals: tile.id)
    // `DisplayTile` draws the ring instead. See `DisplayTile.isFocused` for the
    // measurement: AppKit's ring keeps the geometry it was drawn with, and the
    // map rescales whenever the arrangement changes shape.
    .focusEffectDisabled()
    .onTapGesture { selection = tile.id }
    .gesture(dragGesture(tile))
    // Focus is not a choice, so it deliberately does NOT select — but without
    // this a keyboard-only user could focus a tile and still never reach "Use as
    // Main Display", which acts on the selection and would stay dead forever.
    // Tab to a tile, Space to choose it, Tab to the button. The VoiceOver custom
    // action covers the same ground for a rotor user; this covers the keyboard
    // user who is not running VoiceOver, and that was the gap.
    .onKeyPress(.space) {
      selection = tile.id
      return .handled
    }
    .onKeyPress(.leftArrow) { nudge(tile.id, .left) }
    .onKeyPress(.rightArrow) { nudge(tile.id, .right) }
    .onKeyPress(.upArrow) { nudge(tile.id, .up) }
    .onKeyPress(.downArrow) { nudge(tile.id, .down) }
    .contextMenu {
      Button("Use as Main Display") { onPropose(displayed.makingMain(tile.id)) }
        .disabled(displayed.mainDisplayID == tile.id)
    }
    .accessibilityElement(children: .ignore)
    // Name AND resolution, unconditionally — the label never follows what the
    // tile had room to draw. `TileLabelStyle` can drop a line from the picture;
    // it can take nothing away from here.
    .accessibilityLabel(Text(verbatim: accessibilityLabel(tile)))
    .accessibilityValue(Text(verbatim: accessibilityValue(tile)))
    .accessibilityHint("Use the arrow keys to move this display next to another one.")
    .accessibilityAddTraits(selection == tile.id ? [.isButton, .isSelected] : [.isButton])
    // The same action as the button and the context menu, reachable from the
    // rotor — AR9's whole argument is that setting the main display must not
    // depend on a pointer gesture.
    .accessibilityAction(named: Text("Use as Main Display")) {
      onPropose(displayed.makingMain(tile.id))
    }
    .position(x: rect.midX, y: rect.midY)
    // No implicit animation while dragging — the tile must track the pointer,
    // not lag behind it on a spring.
    .animation(isDragging ? nil : motion, value: rect.midX)
    .animation(isDragging ? nil : motion, value: rect.midY)
    .zIndex(isDragging ? 2 : (selection == tile.id ? 1 : 0))
  }

  /// Reduce Motion turns the spring-back and the settle off **entirely** — a
  /// `nil` animation, not a faster one.
  private var motion: Animation? { Motion.settle(reduceMotion: reduceMotion) }

  /// The user's name for a display, falling back to the name the topology
  /// carries. The fallback is load-bearing rather than defensive:
  /// `DisplayDiscovery` filters on a non-nil `IOAVService`, so a virtual,
  /// AirPlay or Sidecar display has no settings state to be renamed in and would
  /// otherwise draw a nameless tile.
  private func label(for tile: ArrangementTile) -> String {
    let friendly = name(tile.id)
    return friendly.isEmpty ? tile.name : friendly
  }

  /// A synthesis pair is drawn as the panel it is showing, so it is not one of
  /// the purple software displays (SS12).
  private func presentsAsVirtual(_ id: CGDirectDisplayID) -> Bool {
    isVirtual(id) && !isSynthesisPair(id)
  }

  /// The displays this tile is showing on OTHER screens. A synthesis pair has
  /// none: its one member without a tile is the panel the tile already names,
  /// and counting it would report the display as mirroring itself.
  private func mirroredCount(_ tile: ArrangementTile) -> Int {
    isSynthesisPair(tile.id) ? 0 : tile.mirroredIDs.count
  }

  /// The tile's resolution, in the ONE spelling the map and the tooltip share.
  private func pointSize(_ tile: ArrangementTile) -> String {
    "\(tile.rect.width) × \(tile.rect.height)"
  }

  private func accessibilityLabel(_ tile: ArrangementTile) -> String {
    "\(label(for: tile)), \(tile.rect.width) by \(tile.rect.height) points"
  }

  /// Mid-drag of the main tile the displayed layout has no tile at (0,0), a
  /// state the machine cannot be in: moving the main display never changes
  /// which display is main (the plan re-anchors on it). Fall back to the
  /// resting layout's main so the badge does not vanish under the pointer.
  private func isMain(_ id: CGDirectDisplayID) -> Bool {
    (displayed.mainDisplayID ?? arrangement.mainDisplayID) == id
  }

  private func accessibilityValue(_ tile: ArrangementTile) -> String {
    var parts = ["positioned at x \(tile.rect.x), y \(tile.rect.y)"]
    if isMain(tile.id) { parts.append("main display") }
    if presentsAsVirtual(tile.id) { parts.append("virtual display") }
    if mirroredCount(tile) > 0 { parts.append("mirrored to \(mirroredCount(tile)) more") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Dragging

  private func dragGesture(_ tile: ArrangementTile) -> some Gesture {
    // `.named`, never `.local`: a local space moves WITH the tile as it is
    // dragged, so the tile's own movement would feed back into the translation.
    // `.named` rather than `.global` too — global is stable but window-relative,
    // and naming the canvas keeps the guide geometry and the drop math in one
    // space.
    //
    // `minimumDistance: 2` so a click to select does not register as a
    // zero-distance drag.
    DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.spaceName))
      .onChanged { value in
        selection = tile.id
        let base = drag ?? TileDrag(
          id: tile.id,
          baseline: arrangement,
          transform: restingTransform,
          proposal: ArrangementProposal(
            arrangement: arrangement, baseline: arrangement,
            movedID: tile.id, lines: [], problems: []
          )
        )
        guard base.id == tile.id else { return }
        // §1.5 — ONE rounding. The gesture's own `translation` is handed
        // straight to the policy, which offsets the drag-start rect once.
        // Converting the grab point and the current point separately and
        // subtracting rounds twice, and the drift accumulates over a session.
        // The policy cannot protect against that: it never sees the pointer.
        guard let translation = canvasTranslation(value.translation) else { return }
        guard let proposal = ArrangementDragPolicy.propose(
          dragging: tile.id,
          by: translation,
          from: base.baseline,
          transform: base.transform
        ) else { return }
        drag = TileDrag(
          id: base.id, baseline: base.baseline, transform: base.transform, proposal: proposal
        )
      }
      .onEnded { _ in
        guard let finished = drag else { return }
        // **AR3.** The SAME proposal that was on screen. Nothing is recomputed
        // here, so a drop can only ever commit what the user was looking at.
        //
        // `commitment`, not `arrangement`: a drop into open space renders under
        // the pointer and lands on the edge its guide has been naming, so the
        // two differ for exactly that case and the landing is the one to apply.
        // Everything else is unchanged: an overlap has no landing and springs
        // back (AR7), and a no-op commits nothing rather than being refused by
        // the preview session with a message nobody could act on.
        if let commitment = finished.proposal.commitment {
          onPropose(commitment)
        } else if !finished.proposal.isValid {
          onRefuse(finished.proposal.problems)
        }
        // Cleared either way. On success the coordinator's preview replaces the
        // live layout; on refusal the tile animates home from wherever it was,
        // which is the honest report that the position was not legal. macOS
        // would silently "fix" it to somewhere of its own choosing instead.
        withAnimation(motion) { drag = nil }
      }
  }

  /// See `translationLimit`. `nil` means "do not convert this" — the frame is
  /// dropped and the tile stays where the last good frame put it.
  private func canvasTranslation(_ translation: CGSize) -> CanvasPoint? {
    guard translation.width.isFinite, translation.height.isFinite,
          abs(translation.width) < Self.translationLimit,
          abs(translation.height) < Self.translationLimit
    else { return nil }
    return CanvasPoint(x: translation.width, y: translation.height)
  }

  // MARK: - Keyboard (§7.3)

  /// The accessibility route to this view. `.ignored` on a no-op lets the key
  /// fall through to the scroll view rather than being swallowed by a tile that
  /// did nothing — a focused tile at the end of its walk must not eat every
  /// further press of that arrow.
  private func nudge(_ id: CGDirectDisplayID, _ direction: ArrangementDirection) -> KeyPress.Result {
    guard let moved = ArrangementDockPolicy.move(id, direction, in: displayed) else {
      return .ignored
    }
    onPropose(moved)
    return .handled
  }

  // MARK: - Snap guides

  @ViewBuilder private func guide(_ line: SnapLine) -> some View {
    let start = transform.canvasPoint(guideStart(line))
    let end = transform.canvasPoint(guideEnd(line))
    Path { path in
      path.move(to: CGPoint(x: start.x, y: start.y))
      path.addLine(to: CGPoint(x: end.x, y: end.y))
    }
    .stroke(.tint, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    .allowsHitTesting(false)
    // Feedback about a pointer gesture, meaningless to a rotor.
    .accessibilityHidden(true)
  }

  private func guideStart(_ line: SnapLine) -> DisplayPoint {
    switch line.axis {
    case .x: DisplayPoint(x: line.position, y: line.from)
    case .y: DisplayPoint(x: line.from, y: line.position)
    }
  }

  private func guideEnd(_ line: SnapLine) -> DisplayPoint {
    switch line.axis {
    case .x: DisplayPoint(x: line.position, y: line.to)
    case .y: DisplayPoint(x: line.to, y: line.position)
    }
  }
}
