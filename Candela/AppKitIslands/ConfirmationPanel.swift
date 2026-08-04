import AppKit
import SwiftUI

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
/// Placement is the caller's business, not this type's: which display a question
/// belongs on differs per feature (a mode preview asks on its own display, a
/// mirror preview must ask on the master), and resolving that needs topology this
/// island deliberately holds none of.
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

  var isShowing: Bool { shown != nil }

  /// Idempotent for unchanged `identity`: the content view reads its coordinator
  /// directly, so ticks and late failures re-render themselves without the window
  /// being touched.
  func present(_ identity: AnyHashable, on screen: NSScreen, content: () -> Content) {
    guard shown != identity else { return }
    let view = content()

    let hosting: ConfirmationHostingView<Content>
    if let existing = self.hosting {
      hosting = existing
      hosting.rootView = view
    } else {
      hosting = ConfirmationHostingView(rootView: view)
      hosting.frame.size = hosting.fittingSize
      self.hosting = hosting
      panel = makePanel(hosting: hosting)
    }
    guard let panel else { return }
    shown = identity

    // Measure the NEW root view, not the previous one: the origin below is
    // computed from the resulting frame, and centring against a stale size puts
    // the window off-centre on the display it is asking about.
    hosting.layoutSubtreeIfNeeded()
    panel.setContentSize(hosting.fittingSize)

    let frame = panel.frame
    let visible = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(
      x: visible.midX - frame.width / 2,
      y: visible.midY - frame.height / 2
    ))
    // Never `makeKeyAndOrderFront`: an accessory-policy app cannot be activated
    // from inside a menu tracking session anyway (see `SettingsOpener`), and
    // stealing focus to confirm a display change would be its own defect.
    panel.orderFrontRegardless()
  }

  func dismiss() {
    guard shown != nil else { return }
    shown = nil
    panel?.orderOut(nil)
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
/// above.
private final class ConfirmationHostingView<Content: View>: NSHostingView<Content> {
  required init(rootView: Content) {
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  @objc dynamic required init?(coder _: NSCoder) {
    fatalError("ConfirmationHostingView does not support NSCoder")
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    guard let window else { return }
    let target = fittingSize
    guard frame.size != target else { return }
    // Grow around the window's CURRENT centre, not its bottom-left origin.
    // AppKit's origin is bottom-left, so a failure caption appearing mid-preview
    // would otherwise push the whole window upward — the buttons would move out
    // from under the pointer at the moment the user is being told to try again.
    // Reading the live centre (rather than re-centring on the screen) means a
    // window the user has dragged stays where they put it.
    let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
    window.setContentSize(target)
    window.setFrameOrigin(NSPoint(
      x: centre.x - window.frame.width / 2,
      y: centre.y - window.frame.height / 2
    ))
  }
}
