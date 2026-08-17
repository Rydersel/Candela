import AppKit
import CandelaKit
import SwiftUI

/// Marks every confirmation window as one, so a newcomer can see the questions
/// already on screen without any surface knowing about another surface. It is
/// the app's own window list being read, not cross-feature state (#126).
private let confirmationPanelIdentifier = NSUserInterfaceItemIdentifier(
  "com.rydersel.Candela.confirmation"
)

/// The frames of the confirmation windows currently up on `screen`, excluding
/// the one being placed.
///
/// Same-screen only: windows on different displays cannot overlap, and treating
/// them as obstacles would push a lone question off its own centre.
@MainActor
private func occupiedConfirmationFrames(on screen: NSScreen, excluding panel: NSWindow) -> [CGRect] {
  NSApp.windows
    .filter {
      $0 !== panel && $0.isVisible && $0.identifier == confirmationPanelIdentifier
        && $0.screen?.displayID == screen.displayID
    }
    .map(\.frame)
}

/// The window a keep-or-revert question is asked in, shared by every feature
/// that asks one.
///
/// **Why a window rather than a banner.** For a panel-started change it is
/// forced: the panel is a SwiftUI view inside a real `NSMenu` tracking session,
/// and that session ends on Escape, on a click in the menu bar, and — the case
/// that matters — possibly as a side effect of the display reconfiguration the
/// preview itself performs. Change something, the panel vanishes, half a minute
/// later the screen snaps back with no explanation. A hotkey-started change has
/// no panel open at all.
///
/// For a settings-started change it is a judgement, and it was made the other way
/// once. A pane's banner is a few lines of text partway down a scrolling page, in
/// a window that is very often on a DIFFERENT display from the one that just
/// changed. It was missable, and this is a *safety* question — the countdown
/// exists because a bad change can leave a screen unreadable, so it must never be
/// answered blind or, worse, silently.
///
/// A dialog on the affected display is also the platform's own answer: macOS
/// confirms display changes exactly this way.
///
/// **Its buttons take the FIRST click.** That was an open question until
/// 2026-08-04 and it is the reason this window could be promoted at all: a
/// never-activated window can swallow the click that would otherwise focus it,
/// and there is no `acceptsFirstMouse` override anywhere in this repo. Measured
/// on real hardware with a synthesised `kCGEventLeftMouseDown`/`Up` pair while
/// another app was frontmost — one click on the primary committed, one click on
/// the secondary reverted. No override is needed. The result depends on the style
/// mask and on `becomesKeyOnlyIfNeeded`; re-measure if either changes.
///
/// WHICH DISPLAY is the caller's business, not this type's: it differs per
/// feature (a mode preview asks on its own display, a mirror preview must ask on
/// the master), and resolving it needs topology this island deliberately holds
/// none of.
///
/// Where on that display is this type's business, and has to be: every surface
/// centred its own window, so two questions resolving to one display landed on
/// exactly the same point and neither ever moved (#126). Deciding it here is
/// what lets a newcomer step clear of the questions already up without any
/// surface learning about another surface.
@MainActor
final class ConfirmationPanel<Content: View> {
  /// Drawn nowhere (`titleVisibility` is hidden) — it exists so assistive
  /// technology has a name for the window. Deliberately the subject, not the
  /// question, which is only one of the things the window says.
  private let accessibilityTitle: String
  private var panel: NSPanel?
  private var hosting: ConfirmationHostingView<Content>?
  /// What the window is currently showing, or nil while hidden. `present` is
  /// called on every countdown tick, so without this the window would be
  /// re-positioned and re-ordered-front once a second, fighting anyone who
  /// dragged it out of the way. It holds the CONTENT identity rather than the
  /// display: two different questions can follow each other on one display, and
  /// an ID alone could not tell that the window had to change.
  private var shown: AnyHashable?

  init(accessibilityTitle: String) {
    self.accessibilityTitle = accessibilityTitle
  }

  /// Idempotent for unchanged `identity`: the content view reads its coordinator
  /// directly, so ticks and late failures re-render themselves without the window
  /// being touched.
  func present(_ identity: AnyHashable, on screen: NSScreen, content: () -> Content) {
    guard shown != identity else { return }
    let view = content()

    // A view built here has no window yet, so nothing it invalidates before the
    // suspension can reach any geometry.
    let hosting = self.hosting ?? ConfirmationHostingView(rootView: view)
    let isFirstPresent = self.hosting == nil
    // Geometry is this method's for the whole pass: it measures, sizes and places
    // the window below, and an auto-resize starting mid-pass would work from the
    // centre the window had BEFORE placement. This also ends the suspension a
    // dismissal leaves standing. Dropping an invalidation inside the pass is only
    // safe because `ConfirmationCard` pins its width at 340 pt, so `fittingSize`
    // answers the same width every time and cannot oscillate against the size
    // applied here.
    hosting.suspendAutoResize()
    defer { hosting.resumeAutoResize() }
    if isFirstPresent {
      hosting.frame.size = hosting.fittingSize
      self.hosting = hosting
      panel = makePanel(hosting: hosting)
    } else {
      hosting.rootView = view
    }
    guard let panel else { return }
    shown = identity

    // Measure the NEW root view, not the previous one: the origin below is
    // computed from the resulting frame, and centring against a stale size puts
    // the window off-centre on the display it is asking about.
    hosting.layoutSubtreeIfNeeded()
    panel.setContentSize(hosting.fittingSize)

    // Centred when this is the only question up, and clear of the others when
    // it is not (#126). Placement runs once per content identity, never on a
    // countdown tick, so the incumbent keeps the place it was given and a
    // window the user dragged is left where they put it.
    panel.setFrameOrigin(ConfirmationPlacement.origin(
      size: panel.frame.size,
      in: screen.visibleFrame,
      avoiding: occupiedConfirmationFrames(on: screen, excluding: panel)
    ))
    // Only alpha animates, and the window is ordered front before the fade
    // starts: this is the keep-or-revert answer, so it must take a click from
    // the instant it is on screen rather than when some animation ends.
    //
    // A question already up (a second question following the first) keeps the
    // opacity it has and is never dipped.
    let fadeIn = Motion.windowFadeIn(reduceMotion: Motion.systemReduceMotion)
    // Reduce Motion lands on full opacity at once. Otherwise the fade starts
    // from the live alpha, which is 0 for a window that is not up.
    let start = fadeIn > 0 ? (panel.isVisible ? panel.alphaValue : 0) : 1
    // A fade-in animator survives orderOut and keeps driving the hidden
    // window's alpha toward 1 (measured). On the normal path the fade below
    // replaces it by itself, so this group looks removable; it is not. It
    // covers the one path with no following animation: Reduce Motion turns
    // fadeIn to 0 and start to 1, and only this group stops the surviving
    // animator from finishing on top of the direct assignment.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().alphaValue = start
    }
    panel.alphaValue = start
    // Never `makeKeyAndOrderFront`: an accessory-policy app cannot be activated
    // from inside a menu tracking session anyway (see `SettingsOpener`), and
    // stealing focus to confirm a display change would be its own defect.
    panel.orderFrontRegardless()
    if fadeIn > 0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = fadeIn
        panel.animator().alphaValue = 1
      }
    }
  }

  /// Closes instantly, and deliberately: there is no dismissal fade.
  ///
  /// Usually the card's content is gone before this runs (measured 5 of 6:
  /// a coordinator clears its preview, awaits an actor hop, and SwiftUI
  /// commits the emptied body inside the hop), so a dismissal fade would show
  /// a blank panel dissolving. The synchronous paths, the start-failure OK
  /// among them, reach here with the card intact, and stay instant too: the
  /// answer is the event, and a window that lingers after it reads as an
  /// unanswered question.
  func dismiss() {
    guard shown != nil else { return }
    shown = nil
    guard let panel else { return }
    // Belt, since the emptied card's intrinsic size has usually collapsed by now:
    // nothing should size this window between here and the next `present`, which
    // resumes the auto-resize and re-applies both size and placement itself.
    hosting?.suspendAutoResize()
    panel.orderOut(nil)
  }

  private func makePanel(hosting: ConfirmationHostingView<Content>) -> NSPanel {
    // No `.closable`: a close button is an answer that resolves nothing, and it
    // would leave the countdown running behind a dismissed window.
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = hosting
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.isFloatingPanel = true
    // `isFloatingPanel` turns `hidesOnDeactivate` ON, and this app is an
    // accessory that is essentially never the active app — left alone, the
    // confirmation would be invisible exactly when it is needed.
    panel.hidesOnDeactivate = false
    // Not `becomesKeyOnlyIfNeeded`: SwiftUI buttons in a never-key window are a
    // gamble, and `.nonactivatingPanel` already means becoming key does not
    // activate the app or disturb what the user was doing.
    panel.becomesKeyOnlyIfNeeded = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isReleasedWhenClosed = false
    panel.title = accessibilityTitle
    panel.identifier = confirmationPanelIdentifier
    return panel
  }
}

/// Keeps the window's size matched to SwiftUI's ideal size: the content grows
/// when a failure caption appears, and a panel that does not follow would clip
/// the very sentence explaining what went wrong. Same idiom as
/// `PanelHostingView`.
///
/// It carries the whole burden on a countdown tick, because `present`
/// short-circuits on unchanged content and so never reaches the sizing code
/// above. Since the initialiser narrows `sizingOptions`, it is also the ONLY
/// thing that resizes the window: AppKit's own content-driven path is off, which
/// is what makes the size suspendable at all.
private final class ConfirmationHostingView<Content: View>: NSHostingView<Content> {
  /// Set while the resize animation is running. Every intermediate frame lays
  /// the content out again, and each of those layouts can invalidate the
  /// intrinsic size: unguarded, each one would start a fresh animation from a
  /// half-finished frame and the window would never settle. Whatever the content
  /// asked for while it was ignored is settled by the completion handler.
  private var isResizingWindow = false
  /// Bumped whenever the auto-resize is suspended. A resize animation compares
  /// the generation it captured before pinning its destination, so a frame
  /// computed for a question that has since been replaced or answered can never
  /// overwrite the geometry of what is on screen now.
  private var resizeGeneration: UInt64 = 0
  /// True while someone else owns this window's geometry: `present` for the length
  /// of its own sizing and placement pass, and `dismiss` from the close until the
  /// next `present` resumes it.
  private var isAutoResizeSuspended = false

  /// Hands the geometry to the caller and stops any resize in flight.
  ///
  /// An animation running at that moment is stale from that moment: it would keep
  /// driving the window toward the frame the previous content asked for, and an
  /// animator beats a direct assignment, so a placement set now would be
  /// overwritten a frame later. Stopping it where it stands leaves the caller free
  /// to size and place from there.
  func suspendAutoResize() {
    isAutoResizeSuspended = true
    resizeGeneration &+= 1
    let wasResizing = isResizingWindow
    // Cleared before the guard: a view whose window has gone must not keep a flag
    // that would mute every future resize.
    isResizingWindow = false
    guard wasResizing, let window else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().setFrame(window.frame, display: false)
    }
  }

  func resumeAutoResize() {
    isAutoResizeSuspended = false
  }

  required init(rootView: Content) {
    super.init(rootView: rootView)
    // The default options let `NSHostingView` drive the WINDOW's size itself, on a
    // path `invalidateIntrinsicContentSize` cannot suspend. Measured: the moment a
    // coordinator clears its preview the card's body becomes empty, and AppKit had
    // already taken the window to 0x32 before this class was even called; the same
    // path made the mid-countdown grow an instantaneous AppKit jump this class never
    // got to animate, so the grow below was dead code. Keeping only the
    // intrinsic size leaves `fittingSize` and the invalidation hook working, which
    // is what everything here and in `present` measures with, and makes
    // `resizeWindowToFittingSize` the only thing that ever sizes the window.
    // A bare `[]` also stops the window following the content, but it stops
    // publishing an intrinsic size at all: `fittingSize` answers 0x0 and `present`
    // then sizes a zero-by-zero window [both measured 2026-08-17].
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  @objc dynamic required init?(coder _: NSCoder) {
    fatalError("ConfirmationHostingView does not support NSCoder")
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    guard !isResizingWindow, !isAutoResizeSuspended else { return }
    resizeWindowToFittingSize()
  }

  private func resizeWindowToFittingSize() {
    guard let window else { return }
    let target = fittingSize
    guard frame.size != target else { return }
    // An answered question's card empties before `dismiss` is called, and an empty
    // body measures 0 pt wide (measured: 0x32). No question can legitimately ask for
    // that: `ConfirmationCard` pins 340 pt. Refusing it means an emptied card cannot
    // implode a window that is still on screen, whether or not the close is on its
    // way, so this does not depend on the suspension winning a race with SwiftUI.
    guard target.width > 0, target.height > 0 else { return }
    // Grow around the window's CURRENT centre, not its bottom-left origin.
    // AppKit's origin is bottom-left, so a failure caption appearing mid-preview
    // would otherwise push the whole window upward: the buttons would move out
    // from under the pointer at the moment the user is being told to try again.
    // Reading the live centre (rather than re-centring on the screen) means a
    // window the user has dragged stays where they put it.
    let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
    let before = window.frame
    let duration = Motion.windowFadeIn(reduceMotion: Motion.systemReduceMotion)
    // Set before the geometry changes below, which re-lay-out the content and so
    // can re-enter through `invalidateIntrinsicContentSize`.
    isResizingWindow = duration > 0
    window.setContentSize(target)
    window.setFrameOrigin(NSPoint(
      x: centre.x - window.frame.width / 2,
      y: centre.y - window.frame.height / 2
    ))
    guard duration > 0 else { return }
    // The geometry is the unanimated code's own, computed and applied first; only
    // the path there animates. Rewinding to `before` undisplayed (nothing has
    // drawn since) leaves the animator ending on exactly that frame. Both rects
    // share a centre, so the growth stays symmetric about it and the endpoint is
    // the one the jump reached: what changes is that the caption's arrival reads
    // as the window growing rather than as the buttons teleporting. Where the
    // buttons sit at each intermediate height is SwiftUI's to decide, so the path
    // is not a claim this code can make.
    let destination = window.frame
    let generation = resizeGeneration
    window.setFrame(before, display: false)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      window.animator().setFrame(destination, display: true)
    } completionHandler: { [weak self] in
      // Typed `@Sendable`, but fires on the main thread where the window lives.
      MainActor.assumeIsolated {
        // The geometry has been taken over since (a newer question placed, or this
        // one answered), so this destination is stale: pinning it would undo what
        // did the taking over, and the flag is not this animation's to clear any
        // more, since `suspendAutoResize` cleared it and a later resize may have
        // set it again.
        guard let self, self.resizeGeneration == generation else { return }
        // Pinned rather than trusted: the shipped geometry has to be the
        // unanimated one to the point, wherever the animator stopped.
        window.setFrame(destination, display: false)
        self.isResizingWindow = false
        // A content change ignored while the animation ran settles now.
        if self.frame.size != self.fittingSize {
          self.resizeWindowToFittingSize()
        }
      }
    }
  }
}
