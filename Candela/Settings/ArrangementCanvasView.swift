import CandelaKit
import CoreGraphics
import SwiftUI

/// The drag-to-arrange mini-map (drag-canvas §5.2).
///
/// Fixed size on purpose: a `GeometryReader`-driven canvas would rescale the map
/// under the pointer mid-drag, and a fixed box keeps the screenshot checks
/// reproducible.
///
/// Nothing here re-derives geometry. Conversions go through `CanvasTransform`,
/// snaps through `ArrangementSnapper`, validity through `ArrangementRules` and
/// the drag decision through `ArrangementDragPolicy`; this target owns the
/// gesture plumbing and nothing else.
@MainActor
struct ArrangementCanvasView: View {
  /// The layout to draw, owned by `ArrangementPane`. Never mutated here.
  ///
  /// Usually the live layout from `CGDisplayBounds` over the ONLINE display list.
  /// While the coordinator has a reconfiguration in flight the pane hands
  /// its settle down here instead, so this is then a layout that was REQUESTED,
  /// not one the machine has reached. See `isApplying`.
  let arrangement: DisplayArrangement
  /// The user's name for a display, or "" when nothing can name it. Resolution
  /// belongs to the surface, so the canvas asks rather than deciding.
  let name: (CGDirectDisplayID) -> String
  /// Is this a software-only display: one of Candela's own, or a foreign
  /// synthetic one. Asked, not decided, for `name`'s reason. The tile draws it in
  /// the Virtual Displays pane's purple.
  var isVirtual: (CGDirectDisplayID) -> Bool = { _ in false }
  /// Is this tile a synthesized size: a virtual display whose picture IS a
  /// physical panel's, standing in for it while the size is engaged.
  ///
  /// The tile is presented as that panel: it drops the virtual-display colour
  /// and the mirror count, which would be counting the panel the tile already
  /// names. It keeps its own ID and stays movable, because the virtual display
  /// owns the desktop and so is the member of the pair a layout can move.
  var isSynthesisPair: (CGDirectDisplayID) -> Bool = { _ in false }
  /// Is this the built-in display, which draws as a laptop rather than as a
  /// monitor. Asked, not decided, for `name`'s reason.
  var isBuiltIn: (CGDirectDisplayID) -> Bool = { _ in false }
  /// Whether the coordinator has a reconfiguration in flight.
  ///
  /// It is what makes `arrangement` above readable: the pane holds its request
  /// there while an apply is outstanding, so a committed change animates into its
  /// result rather than back into the layout it started from.
  ///
  /// A request the coordinator refuses is never achieved, so no NEW request may
  /// be composed from one. Every route here refuses on this flag: `dragGesture`,
  /// `nudge`, the context-menu item and the VoiceOver custom action.
  var isApplying: Bool = false
  @Binding var selection: CGDirectDisplayID?
  /// Asks for a layout. The pane starts the preview and its countdown, and
  /// holds the requested layout on the map until the apply finishes.
  ///
  /// EVERY route arrives here, which is what makes them behave the same. A
  /// no-op is possible: the VoiceOver action carries no `.disabled` guard, so a
  /// rotor user can ask for the layout already showing, and the pane and the
  /// coordinator both take that quietly.
  let onPropose: (DisplayArrangement) -> Void
  /// Called when a drop was refused, with every problem that refused it,
  /// so the pane can say what is wrong in words. Colour alone is never the
  /// signal: a red border says "no" without saying why.
  let onRefuse: ([ArrangementProblem]) -> Void

  @State private var drag: TileDrag?
  @FocusState private var focused: CGDirectDisplayID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.settingsAccent) private var lighting

  /// Sized to fit INSIDE the card, whose interior does not vary with the window:
  /// the page's content column is capped at `SettingsTheme.pageWidth`. Fixed for
  /// the two reasons in this view's header, neither about the column.
  static let canvasSize = CanvasSize(width: 440, height: 250)
  private static let spaceName = "candela.arrangement.canvas"
  private static let margin: Double = 14

  /// A canvas-space translation this view refuses to convert.
  ///
  /// `CanvasTransform.displayDistance` divides by a scale that can be ~0.05 and
  /// then calls `Int(_:)`, which TRAPS on a non-finite or astronomically large
  /// value. `ArrangementDragPolicy.propose` cannot guard it, since a policy does
  /// not know what its caller's coordinate space means. The bound is far outside
  /// any reachable drag.
  private static let translationLimit: Double = 1_000_000

  /// Everything a drag needs as ONE optional, not three `@State` properties kept
  /// in agreement: "a drag is in progress" then cannot be true while the tile it
  /// is about is unknown.
  struct TileDrag: Equatable {
    let id: CGDirectDisplayID
    /// The layout as of drag START. `DragGesture`'s translation is measured from
    /// the same instant, so folding the policy's own output back in would apply
    /// the move again on every frame.
    let baseline: DisplayArrangement
    /// FROZEN at drag start: the transform is fitted to the layout's
    /// bounds, which the dragged tile changes, so recomputing it here would
    /// rescale the whole map under the pointer on every frame.
    let transform: CanvasTransform
    var proposal: ArrangementProposal
  }

  // MARK: - Derived state

  /// Rendered, never mirrored: `arrangement` is the whole of what this view
  /// knows, settle included, so there is no second layout to fall out of step
  /// with the proposal.
  private var displayed: DisplayArrangement { drag?.proposal.arrangement ?? arrangement }
  private var transform: CanvasTransform { drag?.transform ?? restingTransform }

  private var restingTransform: CanvasTransform {
    CanvasTransform.fitting(arrangement.bounds, in: Self.canvasSize, margin: Self.margin)
  }

  /// How much EVERY tile says, decided once for the whole map (see
  /// `TileLabelStyle`). Per-tile decisions let one short tile drop its resolution
  /// beside neighbours that kept theirs, which reads as a rendering bug. Tile
  /// sizes do not change during a drag, so this cannot flicker under the pointer.
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

  /// One guide to draw, and which question it answers. Up to three are on
  /// screen at once and they describe two different outcomes, so the picture has
  /// to keep them apart: see `guide(_:)`.
  private struct Guide: Identifiable {
    let id: Int
    let line: SnapLine
    /// Where the display GOES on release, rather than where it is being drawn.
    let isLanding: Bool
  }

  /// The snap guides for where the tile is, tagged apart from the landing guide
  /// for where it goes if it cannot stay there. Both come from the one proposal,
  /// so the edge drawn is always the edge the release commits to.
  ///
  /// The tag is carried here because `SnapLine` cannot answer it: an insert seam
  /// and an attachment edge are both `.abut`, so `kind` separates snapping from
  /// aligning, never a rendered position from a committed one. Only the proposal
  /// knows which list a line came out of.
  ///
  /// A landing draws its guide only when the release will commit it. A landing
  /// that resolves back to the layout the drag started from commits nothing, and
  /// its solid guide promised a drop that then sprang home. Keyed on
  /// `commitment`, which the release keys on too, so the two cannot disagree.
  private var guideLines: [Guide] {
    guard let drag else { return [] }
    let snaps = drag.proposal.lines.map { (line: $0, isLanding: false) }
    let committed = drag.proposal.commitment == nil ? [] : (drag.proposal.landing?.lines ?? [])
    let landing = committed.map { (line: $0, isLanding: true) }
    return (snaps + landing).enumerated().map {
      Guide(id: $0.offset, line: $0.element.line, isLanding: $0.element.isLanding)
    }
  }

  /// Every display NAMED in a problem, not just the dragged one (§3.5): moving
  /// the middle display of a row strands the far one, and the user has to see
  /// which displays they broke.
  ///
  /// A drop that is going to COMMIT reddens nothing. Red is reserved for the drop
  /// that really will spring back, or it stops meaning anything.
  ///
  /// Keyed on `commitment`, not on whether a landing exists: a landing that
  /// resolves back to the baseline commits nothing, and keying on its existence
  /// drew a solid guide and no red for a drop that then sprang home.
  private var invalidIDs: Set<CGDirectDisplayID> {
    guard let drag, !drag.proposal.isValid, drag.proposal.commitment == nil else { return [] }
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
      // No fill and no border: the map is drawn ON the pane's stage floor, and a
      // second surface here nests one bordered container inside another.
      // `contentShape` below still gives the background its tap target.
      Color.clear

      ForEach(displayed.tiles) { tile in
        tileView(tile)
      }

      ForEach(guideLines) { guide($0) }
    }
    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
    .coordinateSpace(.named(Self.spaceName))
    .contentShape(Rectangle())
    // Exempt from the settings window's move-by-background dragging: AppKit asks
    // the hit view whether a mouse-down may move the window, the hosting view
    // says yes, and a tile's drag would lose every gesture to the window move.
    // On the canvas, not on a tile: the per-tile chain above `.position` is
    // load-bearing (see below).
    .blocksWindowDrag()
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
      isBuiltIn: isBuiltIn(tile.id),
      labels: labelStyle
    )
    // ORDER IS LOAD-BEARING. `.position` returns a view that fills the WHOLE
    // parent, so anything attached after it hit-tests the entire canvas and the
    // topmost `zIndex` silently wins everywhere. Symptom: dragging any empty area
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
    // Focus is not a choice, so it does NOT select. Without this a keyboard-only
    // user could focus a tile and never reach "Use as Main Display", which acts
    // on the selection: Tab to a tile, Space to choose it, Tab to the button.
    .onKeyPress(.space) {
      selection = tile.id
      return .handled
    }
    .onKeyPress(.leftArrow) { nudge(tile.id, .left) }
    .onKeyPress(.rightArrow) { nudge(tile.id, .right) }
    .onKeyPress(.upArrow) { nudge(tile.id, .up) }
    .onKeyPress(.downArrow) { nudge(tile.id, .down) }
    .contextMenu {
      // Greyed while an apply is outstanding, like the drag and the nudge: this
      // composes from `displayed`, which is the pane's settle then, so a request
      // built here carries the geometry of a layout only ASKED for. If the first
      // apply is refused by the reconfiguration gate, this one could land the machine in the
      // very layout the gate turned down.
      Button("Use as Main Display") { onPropose(displayed.makingMain(tile.id)) }
        .disabled(isApplying || displayed.mainDisplayID == tile.id)
    }
    .accessibilityElement(children: .ignore)
    // Name AND resolution, unconditionally: `TileLabelStyle` can drop a line
    // from the picture, but never from what is spoken.
    .accessibilityLabel(Text(verbatim: accessibilityLabel(tile)))
    .accessibilityValue(Text(verbatim: accessibilityValue(tile)))
    .accessibilityHint("Use the arrow keys to move this display next to another one.")
    .accessibilityAddTraits(selection == tile.id ? [.isButton, .isSelected] : [.isButton])
    // The same action as the button and the context menu, reachable from the
    // rotor: setting the main display must not depend on a pointer
    // gesture.
    //
    // A custom action carries no greyed state a rotor user can read, so the
    // refusal is a guard rather than a `.disabled`.
    .accessibilityAction(named: Text("Use as Main Display")) {
      guard !isApplying else { return }
      onPropose(displayed.makingMain(tile.id))
    }
    .position(x: rect.midX, y: rect.midY)
    // No implicit animation while dragging: the tile must track the pointer, not
    // lag behind it on a spring.
    //
    // Keyed on the whole rect, not on midX and midY separately: a drop that
    // changes the layout's bounds refits the transform and resizes every tile,
    // and with only the centres keyed the tiles slid and resized in one frame.
    //
    // An `Animatable` probe counted 168 interpolated frames for this shape
    // [MEASURED 2026-08-18]. A bare ambient transaction was tried and reverted:
    // it animates too and buys nothing this does not.
    .animation(isDragging ? nil : motion, value: rect)
    .zIndex(isDragging ? 2 : (selection == tile.id ? 1 : 0))
  }

  /// Reduce Motion turns the spring-back and the settle off **entirely** — a
  /// `nil` animation, not a faster one.
  private var motion: Animation? { Motion.settle(reduceMotion: reduceMotion) }

  /// The user's name for a display, falling back to the name the topology
  /// carries. The fallback is load-bearing: `DisplayDiscovery` filters on a
  /// non-nil `IOAVService`, so a virtual, AirPlay or Sidecar display has no
  /// settings state to be renamed in and would otherwise draw a nameless tile.
  private func label(for tile: ArrangementTile) -> String {
    let friendly = name(tile.id)
    return friendly.isEmpty ? tile.name : friendly
  }

  /// A synthesis pair is drawn as the panel it is showing, so it is not one of
  /// the purple software displays.
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

  /// Mid-drag of the main tile nothing sits at (0,0), a state the machine cannot
  /// be in: moving the main display never changes which one is main. Fall back to
  /// the handed layout so the badge does not vanish under the pointer.
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
    // `.named`, never `.local`: a local space moves WITH the tile, so its own
    // movement would feed back into the translation. Not `.global` either, which
    // is window-relative; naming the canvas keeps the guide geometry and the drop
    // math in one space.
    //
    // `minimumDistance: 2` so a click to select is not a zero-distance drag.
    DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.spaceName))
      .onChanged { value in
        // A NEW drag is refused while a reconfiguration is outstanding: it would
        // be baselined on a layout only ASKED for, folding a layout that never
        // happened into this drop. Every route composing from `displayed` is
        // refused on the same fact.
        //
        // A drag already in progress is left alone; freezing a tile under the
        // pointer mid gesture is worse than letting it finish.
        //
        // Selecting comes FIRST, so a refused gesture is not silently inert.
        // Selecting cannot ask for a layout, so it is safe on that path.
        selection = tile.id
        guard drag != nil || !isApplying else { return }
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
        // §1.5: ONE rounding. The gesture's own `translation` goes straight to
        // the policy, which offsets the drag-start rect once. Converting the grab
        // point and the current point separately rounds twice, and the drift
        // accumulates over a session.
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
        // The SAME proposal that was on screen. Nothing is recomputed here,
        // so a drop can only ever commit what the user was looking at.
        //
        // `commitment`, not `arrangement`: a drop into open space renders under
        // the pointer and lands on the edge its guide has been naming, so the
        // landing is the one to apply. An overlap has no landing and springs
        // back, and a no-op commits nothing.
        if let commitment = finished.proposal.commitment {
          // `onPropose` is called from INSIDE the animation on purpose: it arms
          // the pane's settle, and the settle and this view's `drag = nil` have
          // to land in ONE transaction. Split them and the map renders a frame of
          // the pre-drop layout and animates BACKWARD into it.
          withAnimation(motion) {
            onPropose(commitment)
            drag = nil
          }
        } else {
          if !finished.proposal.isValid { onRefuse(finished.proposal.problems) }
          // On refusal the tile animates home from wherever it was, which is the
          // honest report that the position was not legal. macOS would silently
          // "fix" it to somewhere of its own choosing instead.
          withAnimation(motion) { drag = nil }
        }
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
  /// fall through to the scroll view, so a focused tile at the end of its walk
  /// does not eat every further press of that arrow.
  ///
  /// A nudge is refused while an apply is outstanding, for the reason a new drag
  /// is: `displayed` is then a layout only REQUESTED, and a move measured from it
  /// would carry a layout that never happened into the next one.
  ///
  /// That refusal returns `.handled`, unlike the end-of-walk one: the key HAS a
  /// meaning here and is only temporarily unavailable, so falling through would
  /// scroll the page out from under the user instead.
  private func nudge(_ id: CGDirectDisplayID, _ direction: ArrangementDirection) -> KeyPress.Result {
    guard !isApplying else { return .handled }
    guard let moved = ArrangementDockPolicy.move(id, direction, in: displayed) else {
      return .ignored
    }
    onPropose(moved)
    return .handled
  }

  // MARK: - Snap guides

  /// A snap guide is dashed and hairline; the landing guide is solid and a
  /// half-point heavier.
  ///
  /// Same tint for both: a second colour would read as a second kind of state
  /// next to the red that already means "this drop springs back". Weight is the
  /// difference they describe. A snap guide is provisional; the landing says
  /// where the display will BE after the release.
  @ViewBuilder private func guide(_ guide: Guide) -> some View {
    let line = guide.line
    let start = transform.canvasPoint(guideStart(line))
    let end = transform.canvasPoint(guideEnd(line))
    Path { path in
      path.move(to: CGPoint(x: start.x, y: start.y))
      path.addLine(to: CGPoint(x: end.x, y: end.y))
    }
    .stroke(
      // The destination's own accent, so a guide belongs to the same light as
      // the tile it is naming an edge on.
      lighting.accent,
      style: guide.isLanding
        ? StrokeStyle(lineWidth: 1.5)
        : StrokeStyle(lineWidth: 1, dash: [3, 3])
    )
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
