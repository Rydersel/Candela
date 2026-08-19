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
  /// The layout to draw, owned by `ArrangementPane`. Never mutated here.
  ///
  /// Usually the live layout, read from `CGDisplayBounds` over the ONLINE
  /// display list (AR1). NOT always: while the coordinator has a reconfiguration
  /// in flight the pane hands its settle down here instead, so this is then the
  /// layout a change REQUESTED rather than one the machine has reached. See
  /// `isApplying`, which is how that case is told apart, and what the gesture
  /// routes key on.
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
  /// Whether the coordinator has a reconfiguration in flight.
  ///
  /// It is what makes `arrangement` above readable: the pane holds its request
  /// there while an apply is outstanding, so a committed change animates into
  /// its result rather than back into the layout it started from. That settle is
  /// the pane's and not this view's, because "a layout has been asked for and
  /// the apply is outstanding" is a fact about the coordinator; while a map
  /// widget owned it, the pane's own button was the one route that never got the
  /// behaviour.
  ///
  /// What the flag buys HERE is about the gesture rather than about the settle:
  /// a request the coordinator refuses is never achieved, so no NEW request may
  /// be composed from it. That is every route this view owns, not only the
  /// pointer ones: `dragGesture`, `nudge`, the tile's context-menu item and its
  /// VoiceOver custom action all build from `displayed` and all refuse on this.
  var isApplying: Bool = false
  @Binding var selection: CGDirectDisplayID?
  /// Asks for a layout. The pane starts the preview and its countdown, and
  /// holds the requested layout on the map until the apply finishes.
  ///
  /// EVERY route arrives here, a drop and an arrow-key nudge and both "Use as
  /// Main Display" actions alike, which is what makes them behave the same. A
  /// valid layout that differs from the current one is the usual case rather
  /// than a guarantee: the VoiceOver action carries no `.disabled` guard the way
  /// the context-menu button does, so a rotor user can ask for the layout that
  /// is already showing. The pane and the coordinator both take that quietly.
  let onPropose: (DisplayArrangement) -> Void
  /// Called when a drop was refused (AR7), with every problem that refused it,
  /// so the pane can say what is wrong in words. Colour alone is never the
  /// signal — and a red border says "no" without saying why.
  let onRefuse: ([ArrangementProblem]) -> Void

  @State private var drag: TileDrag?
  @FocusState private var focused: CGDirectDisplayID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Sized to fit INSIDE the grouped form's section card at the settings
  /// window's 720 pt minimum width, measured rather than budgeted: the card's
  /// interior there is about 454 pt (2x captures, 2026-08-18). The previous 480
  /// was derived from the detail COLUMN's width and never actually fit the
  /// card, which stayed latent while the saved frame was wide; at a saved
  /// 720 pt frame, NavigationSplitView resolves the over-constraint by
  /// confiscating the sidebar's margins, so the sidebar sits flush against the
  /// window edge, and the theft persists on every other pane until relaunch.
  /// 440 leaves ~14 pt of slack for scroller and inset variance.
  ///
  static let canvasSize = CanvasSize(width: 440, height: 250)
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
  /// step with the proposal. `arrangement` is the whole of what this view knows
  /// about the world, a settle included, so there is no second layout here to
  /// keep in agreement with the one it was handed.
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
  /// so the edge drawn is always the edge the release commits to (AR3).
  ///
  /// The tag is carried here because `SnapLine` cannot answer the question:
  /// an insert seam and an attachment edge are both `.abut`, the same kind an
  /// ordinary snap guide carries, so `kind` distinguishes snapping from
  /// aligning and never a rendered position from a committed one. Only the
  /// proposal knows which list a line came out of.
  ///
  /// **A landing draws its guide only when the release will commit it.** The
  /// landing that resolves back to the layout the drag started from is no
  /// commitment at all, and drawing its line promises an outcome the release
  /// cannot deliver: drag one of two abutting displays straight away from its
  /// neighbour, past the snap threshold and near no other edge, and the nearest
  /// legal position the attach policy can rank is the display's own original
  /// one. The solid guide said the drop would succeed; the tile then sprang home
  /// and the pane called the layout invalid. Keyed on `commitment` for that
  /// reason, which is what the release itself keys on, so the two cannot
  /// disagree about whether anything is going to happen.
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
  /// which displays they broke rather than only which one they are holding.
  ///
  /// A drop that is going to COMMIT reddens nothing. The position under the
  /// pointer is not legal and the proposal says so, but the release will
  /// succeed: the guide names where the display goes. Red is reserved for the
  /// drop that really will spring back, or it stops meaning anything (AR15).
  ///
  /// Keyed on `commitment`, not on whether a landing exists, because those two
  /// disagree in exactly the case an ordinary gesture reaches: a landing that
  /// resolves back to the baseline commits nothing. Dragging one of two abutting
  /// displays straight away from its neighbour and letting go near no other edge
  /// used to draw a solid landing guide and no red, which AR15 defines as "this
  /// release will succeed", and then sprang the tile home and named displays
  /// that had never moved as the reason the layout was invalid.
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
      // No fill and no border. The map is drawn ON the pane's field, which
      // spans the whole row; a card here as well nests one bordered container
      // inside another and is what made the map read as an island floating off
      // the section's leading edge. `contentShape` below still gives the
      // background its tap target.
      Color.clear

      ForEach(displayed.tiles) { tile in
        tileView(tile)
      }

      ForEach(guideLines) { guide($0) }
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
      // Greyed while an apply is outstanding, for the reason the drag and the
      // nudge are refused: this composes from `displayed`, which is the pane's
      // settle during one, so a request built here would carry the relative
      // geometry of a layout that has only been ASKED for. If the first apply is
      // then refused by AR12's four-way gate, this one can succeed and put the
      // machine into the very layout the gate just turned down.
      Button("Use as Main Display") { onPropose(displayed.makingMain(tile.id)) }
        .disabled(isApplying || displayed.mainDisplayID == tile.id)
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
    //
    // A custom action carries no greyed state a rotor user can read, so the
    // refusal is a guard rather than a `.disabled`. Same fact as the context
    // menu above and for the same reason: `displayed` is the pane's settle while
    // an apply is outstanding.
    .accessibilityAction(named: Text("Use as Main Display")) {
      guard !isApplying else { return }
      onPropose(displayed.makingMain(tile.id))
    }
    .position(x: rect.midX, y: rect.midY)
    // No implicit animation while dragging: the tile must track the pointer,
    // not lag behind it on a spring.
    //
    // Keyed on the whole rect rather than on midX and midY separately, because
    // a drop that changes the layout's bounds refits the transform and so
    // resizes every tile. With only the centres keyed the tiles slid to their
    // new positions while snapping to their new sizes in the same frame.
    //
    // A keyed `.animation` here is MEASURED to work despite this canvas living
    // in a grouped `Form` [2026-08-18]: an `Animatable` probe counted 168
    // interpolated frames for this shape in a `Form` section, the same as for
    // the control outside one. The harness that produced that number was not
    // committed; skill `candela-ui-verification` describes its shape well
    // enough to rebuild, which is the citation to follow rather than any
    // scratch path.
    //
    // The skill's "a keyed animation in a Form animates nothing" is about a
    // CONDITIONAL ROW arriving and leaving, which is a transition; a persistent
    // child moving is not the same question, and conflating the two cost a
    // deploy here. Replacing this with a bare ambient transaction was tried and
    // reverted: it animates too, and buys nothing this does not already do.
    .animation(isDragging ? nil : motion, value: rect)
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
  /// layout this view was handed so the badge does not vanish under the pointer.
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
        // A NEW drag is refused while a reconfiguration is outstanding, because
        // it would be baselined on a layout that has only been ASKED for: the
        // refusal paths leave such a request unachieved, so a move measured from
        // it would fold a layout that never happened into this drop. Every route
        // that composes from `displayed` is refused on the same fact: the nudge,
        // the context-menu item and the VoiceOver action below.
        //
        // A drag already in progress is left alone: freezing a tile under the
        // pointer mid gesture is worse than letting it finish, and its release
        // goes through the same commit path it always did.
        //
        // Selecting comes FIRST, so a refused gesture is not silently inert: a
        // drag that neither moves the tile nor marks it leaves nothing on screen
        // to say the app noticed the pointer at all. Selecting cannot ask for a
        // layout, so it is safe on the refused path too, and the guard below
        // still keeps the gesture from moving anything.
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
          // `onPropose` is called from INSIDE the animation, and that is the
          // easiest thing here to get wrong. That call is what arms the pane's
          // settle, so the settle and this view's `drag = nil` have to land in
          // ONE transaction: split them and the map renders a frame of the
          // pre-drop layout and animates BACKWARD into it, which is the whole
          // defect the settle exists to remove. Kept together, the tiles animate
          // from where the pointer left them to where the drop puts them, which
          // for an insert is the first and only time the displays the user did
          // not grab move.
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
  /// fall through to the scroll view rather than being swallowed by a tile that
  /// did nothing — a focused tile at the end of its walk must not eat every
  /// further press of that arrow.
  ///
  /// A nudge is refused outright while an apply is outstanding, for the reason a
  /// new drag is: `displayed` is then the layout a change REQUESTED, and a
  /// request the coordinator refuses is never achieved, so a move measured from
  /// it would carry a layout that never happened into the next one.
  ///
  /// That refusal returns `.handled`, unlike the end-of-walk one above. The key
  /// HAS a meaning on this tile and is only temporarily unavailable, so letting
  /// it fall through scrolls the settings page instead: the user presses an
  /// arrow to move a display and the pane slides away under them, which reads as
  /// the app doing something else rather than as the app waiting.
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
  /// Same tint for both, deliberately: this is one gesture and a second colour
  /// would read as a second kind of state, next to the red that already means
  /// "this drop springs back". What separates them is weight, which is the
  /// difference they actually describe. A snap guide says where the tile is
  /// being drawn, and it is provisional: keep dragging and it goes away. The
  /// landing says where the display will BE after the release, which is AR15's
  /// whole argument for letting the tile go on tracking the pointer, and that
  /// argument only holds while the guide naming the destination can be picked
  /// out of the up-to-three lines on screen.
  @ViewBuilder private func guide(_ guide: Guide) -> some View {
    let line = guide.line
    let start = transform.canvasPoint(guideStart(line))
    let end = transform.canvasPoint(guideEnd(line))
    Path { path in
      path.move(to: CGPoint(x: start.x, y: start.y))
      path.addLine(to: CGPoint(x: end.x, y: end.y))
    }
    .stroke(
      .tint,
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
