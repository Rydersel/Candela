import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep this resolution?" surface. **The primary one, for every preview**,
/// whichever surface started it.
///
/// **Why a window rather than a banner.** For a panel-started preview it is
/// forced: the panel is a SwiftUI view inside a real `NSMenu` tracking session,
/// and that session ends on Escape, on a click in the menu bar, and — the case
/// that matters — possibly as a side effect of the display reconfiguration the
/// preview itself performs. Pick a resolution, the panel vanishes, half a minute
/// later the screen snaps back with no explanation.
///
/// For a settings-started preview it is a judgement, and it was made the other
/// way once. The pane's banner is a few lines of text partway down a scrolling
/// page, in a window that is very often on a DIFFERENT display from the one that
/// just changed. It was missable, and this is a *safety* question — the
/// countdown exists because a bad mode can leave a screen unreadable, so it must
/// never be answered blind or, worse, silently. So the window takes that preview
/// too, and the banner stays only as the recovery surface for when this window
/// is on screen but unusable (see `DisplayModeSection.previewBanner`).
///
/// A dialog on the affected display is also the platform's own answer: macOS
/// confirms display changes exactly this way.
///
/// The commit is still explicit — nothing is committed at session scope without
/// someone pressing Keep, and doing nothing still reverts.
///
/// **Its buttons take the FIRST click.** That was an open question until
/// 2026-08-04 and it is the reason this window could be promoted at all: a
/// never-activated window can swallow the click that would otherwise focus it,
/// and there is no `acceptsFirstMouse` override anywhere in this repo. Measured
/// on real hardware with a synthesised `kCGEventLeftMouseDown`/`Up` pair while
/// another app was frontmost — one click on Keep committed, one click on Revert
/// Now reverted. No override is needed. The result depends on the style mask and
/// on `becomesKeyOnlyIfNeeded`; re-measure if either changes.
@MainActor
final class ModeConfirmationWindow: ModeConfirmationPresenting {
  private let coordinator: DisplayModeCoordinator
  /// Friendly-name resolution (renames, per-display prefs) is the panel's
  /// business, not the coordinator's, so it is injected at launch. Default is
  /// deliberately empty rather than a hardware name: an unwired presenter
  /// should look unfinished in testing, not plausibly right.
  var displayName: (CGDirectDisplayID) -> String = { _ in "" }
  /// Resolves a display to one that has an `NSScreen` — itself, or its mirror
  /// master (DT15). Injected for the same reason `displayName` is: the island
  /// holds no topology of its own and exercises no judgement about mirroring
  /// (DT16).
  ///
  /// The default is the IDENTITY function and not something obviously broken,
  /// because identity is exactly the old behaviour and is right for every
  /// unmirrored display. Wired at launch in `StatusItemController`.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private var panel: NSPanel?
  /// What the window is currently showing, or nil while hidden.
  /// `presentConfirmation` is called on every countdown tick, so without this
  /// the window would be re-positioned and re-ordered-front once a second,
  /// fighting anyone who dragged it out of the way. It holds the CONTENT rather
  /// than the display: a preview and a start failure can follow each other on
  /// one display, and an ID alone could not tell that the window had to change.
  private var shown: ModeConfirmationContent?

  init(coordinator: DisplayModeCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - ModeConfirmationPresenting

  func presentConfirmation(_ content: ModeConfirmationContent) {
    guard shown != content else { return }
    let displayID = content.displayID
    // The window goes where there are PIXELS. For a mode preview on a display
    // that has since become a mirror slave this is a rescue; for a MIRROR
    // preview it is the mechanism — the display named in the request loses its
    // screen the instant the preview applies, so an unresolved lookup would
    // dismiss the one surface offering the revert.
    //
    // Resolution is one-directional in its safety, and the unsafe direction
    // reaches here. A sample lagging a mirror ENGAGING self-heals: the lookup
    // fails, the guard below dismisses, `shown` goes back to nil, and the next
    // countdown tick — which is otherwise a no-op, `shown != content` being
    // false — re-runs this against a caught-up sample and puts the window up.
    // A sample lagging a mirror BREAKING does NOT: the ex-master is a real
    // screen, so the window appears on the WRONG display, `shown` records it,
    // and no later tick re-positions it. The window is answerable where it
    // lands and the countdown still reverts, so the cost is a confirmation on
    // the wrong panel for the life of one preview, not an unanswerable one.
    let placement = drawableDisplayID(displayID)
    // No screen even after resolving: either the display has departed (the
    // coordinator discards the preview on the next screen-parameters
    // notification) or the list has not caught up with the reconfiguration yet.
    // Hide rather than leave a window naming the previous display up — a preview
    // retries this on every countdown tick, so a momentarily stale screen list
    // self-heals a second later.
    guard let screen = NSScreen.screens.first(where: { $0.displayID == placement }) else {
      dismissConfirmation()
      return
    }

    let view = ModeConfirmationView(
      coordinator: coordinator, content: content, displayName: displayName(displayID)
    )
    let panel = panel ?? makePanel(showing: view)
    self.panel = panel
    shown = content

    let hosting = panel.contentView as? ConfirmationHostingView
    hosting?.rootView = view
    if let hosting {
      // Measure the NEW root view, not the previous one: the origin below is
      // computed from the resulting frame, and centring against a stale size
      // puts the window off-centre on the display it is asking about.
      hosting.layoutSubtreeIfNeeded()
      panel.setContentSize(hosting.fittingSize)
    }
    let frame = panel.frame
    let visible = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(
      x: visible.midX - frame.width / 2,
      y: visible.midY - frame.height / 2
    ))
    // Never `makeKeyAndOrderFront`: an accessory-policy app cannot be activated
    // from inside a menu tracking session anyway (see `SettingsOpener`), and
    // stealing focus to confirm a resolution would be its own defect.
    panel.orderFrontRegardless()
  }

  func dismissConfirmation() {
    guard shown != nil else { return }
    shown = nil
    panel?.orderOut(nil)
  }

  // MARK: - The window

  /// Built around the view it will first show, so its initial size is the size
  /// of real content rather than of a placeholder.
  private func makePanel(showing view: ModeConfirmationView) -> NSPanel {
    let hosting = ConfirmationHostingView(rootView: view)
    hosting.frame.size = hosting.fittingSize

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
    // Drawn nowhere (`titleVisibility` is hidden) — it exists so assistive
    // technology has a name for the window. Deliberately not the question,
    // which is only one of the two things this window says.
    panel.title = "Display resolution"
    return panel
  }
}

/// Keeps the window's size matched to SwiftUI's ideal size: the content grows
/// when a failure caption appears, and a panel that does not follow would clip
/// the very sentence explaining what went wrong. Same idiom as
/// `PanelHostingView`.
private final class ConfirmationHostingView: NSHostingView<ModeConfirmationView> {
  required init(rootView: ModeConfirmationView) {
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

/// Reads the coordinator directly, so the countdown ticks and a failure appears
/// without the window controller knowing anything about either. `content` says
/// only WHICH of the two things this window is showing; the words come from the
/// coordinator's own state.
///
/// Deliberately the same words as the settings banner and the panel's own rows —
/// these are the same statements, and two spellings of one are two things to
/// keep true.
struct ModeConfirmationView: View {
  let coordinator: DisplayModeCoordinator
  let content: ModeConfirmationContent
  let displayName: String

  var body: some View {
    switch content {
    case .preview: previewBody
    case .startFailure: startFailureBody
    }
  }

  // MARK: - A preview waiting to be answered

  @ViewBuilder private var previewBody: some View {
    // Rendered from the coordinator's own answer, never from what the caller
    // remembered passing in.
    if let preview = coordinator.preview {
      card {
        Text("Keep this resolution?")
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(verbatim: subtitle(preview))
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        if let failure = preview.failure {
          // Nothing auto-retries a failed resolution. Staying silent would
          // leave the display on a mode the user never approved, held only
          // until the app exits.
          caption(DisplayModeCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          Text(verbatim: DisplayModeCopy.countdown(preview.secondsRemaining))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            // A number that changes every second must not be able to change the
            // WIDTH of what it sits in — the buttons below would shuffle under
            // the pointer once a second.
            .monospacedDigit()
        } else if preview.failure != nil {
          caption(DisplayModeCopy.expiryAlreadyRan)
        }

        // Side by side and equally wide, the way an alert asks a question it
        // expects an answer to. Not trailing-aligned any more: at 320pt with a
        // headline the old row read as a form's footer, which is exactly the
        // "easy to miss" this window was promoted to fix.
        HStack(spacing: 10) {
          // Both answers carry the preview THIS window is rendering, so a
          // selection landing between the click and the queued operation is
          // refused as stale rather than resolved by an answer given about
          // something else.
          Button("Revert Now") { Task { await coordinator.revert(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: false))
            .keyboardShortcut(.cancelAction)
          Button("Keep") { Task { await coordinator.confirm(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 6)
        // Belt to the intent check's braces: while a selection is still landing
        // the window is about to change, so offering an answer to the old one
        // is pointless even though it is now harmless.
        .disabled(coordinator.isApplying)
      }
    }
  }

  // MARK: - A selection that never took effect

  /// The panel closes on a selection, so this is the ONLY place a
  /// panel-initiated `begin()` failure is seen without the user happening to
  /// reopen the panel: the screen did not change and there is no preview to
  /// answer, so silence here is indistinguishable from the feature not working.
  ///
  /// No countdown and no revert — nothing was applied. One button, which
  /// dismisses the report rather than resolving anything.
  @ViewBuilder private var startFailureBody: some View {
    if let failure = coordinator.startFailure {
      card {
        Text("Resolution not changed")
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
        if !displayName.isEmpty {
          Text(verbatim: displayName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        caption(DisplayModeCopy.startFailure)
          .help("CoreGraphics error \(failure.error.cgErrorCode)")

        Button("OK") { coordinator.dismissStartFailure() }
          .buttonStyle(AnswerButtonStyle(isPrimary: true))
          .keyboardShortcut(.defaultAction)
          .padding(.top, 6)
      }
    }
  }

  /// One shape for both states, so the window does not change size or alignment
  /// language depending on what it has to say.
  ///
  /// Centred, icon-first and 340pt wide: the shape of a macOS alert, because
  /// that is what this now is. The old 320pt leading-aligned card read as a
  /// tooltip, and a safety question that reads as a tooltip gets treated like
  /// one. The icon is the app's own — nothing else on screen says WHO is asking,
  /// and a resolution that changed by itself is otherwise indistinguishable from
  /// the display or macOS doing it.
  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
      content()
    }
    .multilineTextAlignment(.center)
    .padding(24)
    .frame(width: 340)
  }

  private func subtitle(_ preview: DisplayModeCoordinator.Preview) -> String {
    let mode = "\(DisplayModeCopy.size(preview.mode)), \(DisplayModeCopy.refresh(preview.mode.refreshHz))"
    return displayName.isEmpty ? mode : "\(displayName) — \(mode)"
  }

  private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The two answers, drawn by us rather than by `.bordered` / `.borderedProminent`.
///
/// **`.borderedProminent` renders GREY in this window and always will.** Candela
/// is an `.accessory` app that is essentially never the active application, and
/// AppKit draws controls in an inactive app in their inactive appearance —
/// measured 2026-08-04, the two answers came out visually identical. On an alert
/// whose whole job is to be impossible to miss, "which one is the primary
/// action?" being unanswerable is the defect this window was promoted to fix.
/// `controlAccentColor` is a system colour that does not dim with activation, so
/// asking for it directly is the only thing that survives.
///
/// Both answers share one style so the two capsules cannot end up different
/// heights, which is what happened when only the primary was custom. Hover and
/// pressed states are required of any custom button (`buttons.md`) — and this is
/// a control that reconfigures a screen, so a click that feels unregistered
/// invites a second one.
private struct AnswerButtonStyle: ButtonStyle {
  let isPrimary: Bool
  @State private var isHovering = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(isPrimary ? .semibold : .regular))
      .foregroundStyle(isPrimary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(fill(pressed: configuration.isPressed))
      )
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .onHover { isHovering = $0 }
  }

  private func fill(pressed: Bool) -> AnyShapeStyle {
    if isPrimary {
      let accent = Color(nsColor: .controlAccentColor)
      return AnyShapeStyle(accent.opacity(pressed ? 0.7 : (isHovering ? 0.88 : 1)))
    }
    if pressed { return AnyShapeStyle(.tertiary) }
    return AnyShapeStyle(isHovering ? AnyShapeStyle(.secondary.opacity(0.35)) : AnyShapeStyle(.quaternary))
  }
}
