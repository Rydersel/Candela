import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep mirroring?" surface, and the only place a hotkey-initiated mirror
/// change ever says anything.
///
/// It is a window and not a row in the panel for the reason
/// `ModeConfirmationWindow` states: the panel is an `NSMenu` tracking session
/// that ends on Escape, on a menu-bar click, and plausibly as a side effect of
/// the very reconfiguration the preview performs. And the hotkey has no panel
/// open at all.
///
/// It goes on the **master**, because the display the request named has no
/// `NSScreen` from the instant the preview applies — that is not a rescue here,
/// it is the mechanism.
@MainActor
final class MirrorConfirmationWindow: MirrorConfirmationPresenting {
  private let coordinator: MirroringCoordinator
  /// Resolves to a display that has a screen — see `ModeConfirmationWindow`.
  /// The default is the IDENTITY function and not something obviously broken,
  /// because identity is right for every unmirrored display; wired at launch.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private var panel: NSPanel?
  /// What the window is currently showing, or nil while hidden.
  /// `presentMirrorConfirmation` is called on every countdown tick, so without
  /// this the window would be re-positioned and re-ordered-front once a second,
  /// fighting anyone who dragged it out of the way.
  private var shown: MirrorConfirmationContent?

  init(coordinator: MirroringCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - MirrorConfirmationPresenting

  func presentMirrorConfirmation(_ content: MirrorConfirmationContent) {
    guard shown != content else { return }
    // A report is not about a display, so it goes on the main display — the one
    // the user is certainly looking at.
    let target: CGDirectDisplayID = switch content {
    case let .preview(displayID): drawableDisplayID(displayID)
    case .report: CGMainDisplayID()
    }
    // No screen even after resolving: the display has departed, or the list has
    // not caught up with the reconfiguration yet. Hide rather than leave a
    // window naming the previous state up — a preview retries this on every
    // countdown tick, so a momentarily stale screen list self-heals a second
    // later.
    guard let screen = NSScreen.screens.first(where: { $0.displayID == target }) else {
      dismissMirrorConfirmation()
      return
    }

    let view = MirrorConfirmationView(coordinator: coordinator, content: content)
    let panel = panel ?? makePanel(showing: view)
    self.panel = panel
    shown = content

    let hosting = panel.contentView as? MirrorHostingView
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
    // from inside a menu tracking session anyway, and stealing focus to confirm
    // a mirror change would be its own defect.
    panel.orderFrontRegardless()
  }

  func dismissMirrorConfirmation() {
    guard shown != nil else { return }
    shown = nil
    panel?.orderOut(nil)
  }

  // MARK: - The window

  private func makePanel(showing view: MirrorConfirmationView) -> NSPanel {
    let hosting = MirrorHostingView(rootView: view)
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
    // technology has a name for the window.
    panel.title = "Display mirroring"
    return panel
  }
}

/// Keeps the window's size matched to SwiftUI's ideal size: the content grows
/// when a failure caption appears, and a panel that does not follow would clip
/// the very sentence explaining what went wrong. Same idiom as
/// `ConfirmationHostingView` — and it matters MORE here, because
/// `presentMirrorConfirmation` short-circuits on unchanged content, so a
/// countdown tick that adds a caption never reaches the sizing code above.
private final class MirrorHostingView: NSHostingView<MirrorConfirmationView> {
  required init(rootView: MirrorConfirmationView) {
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  @objc dynamic required init?(coder _: NSCoder) {
    fatalError("MirrorHostingView does not support NSCoder")
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    guard let window else { return }
    let target = fittingSize
    guard frame.size != target else { return }
    // Grow around the window's CURRENT centre, not its bottom-left origin.
    // AppKit's origin is bottom-left, so a caption appearing mid-preview would
    // otherwise push the whole window upward — the buttons would move out from
    // under the pointer at the moment the user is being told to try again.
    let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
    window.setContentSize(target)
    window.setFrameOrigin(NSPoint(
      x: centre.x - window.frame.width / 2,
      y: centre.y - window.frame.height / 2
    ))
  }
}

/// Reads the coordinator directly, so ticks and failures appear without the
/// window controller knowing about either. Deliberately the same words as the
/// settings section and the panel rows — two spellings of one statement are two
/// things to keep true.
struct MirrorConfirmationView: View {
  let coordinator: MirroringCoordinator
  let content: MirrorConfirmationContent

  var body: some View {
    switch content {
    case .preview: previewBody
    case .report: reportBody
    }
  }

  // MARK: - A preview waiting to be answered

  @ViewBuilder private var previewBody: some View {
    // Rendered from the coordinator's own answer, never from what the caller
    // remembered passing in.
    if let preview = coordinator.preview {
      card {
        Text(MirroringCopy.question)
          .font(.headline)
        Text(verbatim: subtitle(preview))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let failure = preview.failure {
          // Nothing auto-retries a failed resolution. Staying silent would leave
          // the user on a topology they never approved, held only until the app
          // exits.
          caption(MirroringCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          Text(verbatim: MirroringCopy.countdown(preview.secondsRemaining))
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Spacer(minLength: 0)
          // Both answers carry the preview THIS window is rendering, so an
          // answer can only ever resolve what the user was looking at.
          Button(MirroringCopy.stopNow) { Task { await coordinator.revert(preview) } }
          Button(MirroringCopy.keep) { Task { await coordinator.confirm(preview) } }
            .buttonStyle(.borderedProminent)
        }
        .disabled(coordinator.isApplying)
      }
    }
  }

  // MARK: - A change that did not happen, or did not happen fully

  @ViewBuilder private var reportBody: some View {
    card {
      Text(MirroringCopy.reportTitle)
        .font(.headline)
      // Every refusal states a reason, and there are SEVEN of them. There is no
      // "it did not work", and no `default:` arm — `MirroringCopy.refusal`
      // switches exhaustively so a new case is a compile error rather than a
      // silently generic sentence.
      if let refusal = coordinator.lastRefusal {
        caption(MirroringCopy.refusal(refusal))
      }
      if let failure = coordinator.lastFailure {
        caption(MirroringCopy.applyFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
      }
      // A break that committed exactly what it staged and still left a set
      // standing. Said out loud, because "mirroring off" over a set the user is
      // still looking at is the defect this whole feature exists to close.
      if !coordinator.lastPartialBreak.isEmpty {
        Text(verbatim: MirroringCopy.partialBreak(
          residual: coordinator.lastPartialBreak, name: coordinator.displayName
        ))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("OK") { coordinator.dismissReport() }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  /// One shape for both states, so the window does not change size or alignment
  /// language depending on what it has to say.
  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(16)
    .frame(width: 320, alignment: .leading)
  }

  private func subtitle(_ preview: MirroringCoordinator.Preview) -> String {
    let count = preview.value.applied.count
    return count == 1
      ? "1 display is showing this one's picture."
      : "\(count) displays are showing this one's picture."
  }

  private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
