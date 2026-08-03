import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep this resolution?" surface for a preview started from the menu-bar
/// panel.
///
/// **Why a window and not a banner in the panel.** The panel is a SwiftUI view
/// inside a real `NSMenu` tracking session. That session ends on Escape, on a
/// click in the menu bar, and — the case that matters — possibly as a side
/// effect of the display reconfiguration the preview itself performs. If the
/// confirm UI lived in the panel, the plausible outcome is: pick a resolution,
/// the panel vanishes, fifteen seconds later the screen snaps back with no
/// explanation. That reads as the feature being broken, and it is a *safety*
/// surface — the countdown exists because a bad mode can leave a screen
/// unreadable, so it must never be answered blind or, worse, silently.
///
/// A floating panel on the affected display is also the platform's own answer:
/// macOS confirms display changes with a dialog on the display that changed.
///
/// The commit is still explicit — nothing is committed at session scope without
/// someone pressing Keep, and doing nothing still reverts.
@MainActor
final class ModeConfirmationWindow: ModeConfirmationPresenting {
  private let coordinator: DisplayModeCoordinator
  /// Friendly-name resolution (renames, per-display prefs) is the panel's
  /// business, not the coordinator's, so it is injected at launch. Default is
  /// deliberately empty rather than a hardware name: an unwired presenter
  /// should look unfinished in testing, not plausibly right.
  var displayName: (CGDirectDisplayID) -> String = { _ in "" }

  private var panel: NSPanel?
  /// The display the panel is currently showing for, or nil while hidden.
  /// `presentConfirmation` is called on every countdown tick, so without this
  /// the window would be re-positioned and re-ordered-front once a second,
  /// fighting anyone who dragged it out of the way.
  private var shownFor: CGDirectDisplayID?

  init(coordinator: DisplayModeCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - ModeConfirmationPresenting

  func presentConfirmation(on displayID: CGDirectDisplayID) {
    guard shownFor != displayID else { return }
    // No screen for the display this preview is on: either it has departed (the
    // coordinator discards the preview on the next screen-parameters
    // notification) or the list has not caught up with the reconfiguration yet.
    // Hide rather than leave a window naming the previous display up — this is
    // retried on every countdown tick, so a momentarily stale screen list
    // self-heals a second later.
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      dismissConfirmation()
      return
    }

    let panel = panel ?? makePanel()
    self.panel = panel
    shownFor = displayID

    let hosting = panel.contentView as? ConfirmationHostingView
    hosting?.rootView = ModeConfirmationView(
      coordinator: coordinator, displayName: displayName(displayID)
    )
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
    guard shownFor != nil else { return }
    shownFor = nil
    panel?.orderOut(nil)
  }

  // MARK: - The window

  private func makePanel() -> NSPanel {
    let hosting = ConfirmationHostingView(
      rootView: ModeConfirmationView(coordinator: coordinator, displayName: "")
    )
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
    panel.title = "Keep this resolution?"
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

/// Reads `coordinator.preview` directly, so the countdown ticks and a failure
/// appears without the window controller knowing anything about either.
///
/// Deliberately the same words as the settings banner — this is the same
/// question, and two spellings of it would be two things to keep true.
struct ModeConfirmationView: View {
  let coordinator: DisplayModeCoordinator
  let displayName: String

  var body: some View {
    // Rendered from the coordinator's own answer, never from what the caller
    // remembered passing in.
    if let preview = coordinator.preview {
      VStack(alignment: .leading, spacing: 8) {
        Text("Keep this resolution?")
          .font(.headline)
        Text(verbatim: subtitle(preview))
          .font(.callout)
          .foregroundStyle(.secondary)
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
        } else if preview.failure != nil {
          caption(DisplayModeCopy.expiryAlreadyRan)
        }

        HStack(spacing: 8) {
          Spacer(minLength: 0)
          // Both answers carry the preview THIS window is rendering, so a
          // selection landing between the click and the queued operation is
          // refused as stale rather than resolved by an answer given about
          // something else.
          Button("Revert Now") { Task { await coordinator.revert(preview) } }
          Button("Keep") { Task { await coordinator.confirm(preview) } }
            .buttonStyle(.borderedProminent)
        }
        // Belt to the intent check's braces: while a selection is still landing
        // the window is about to change, so offering an answer to the old one
        // is pointless even though it is now harmless.
        .disabled(coordinator.isApplying)
      }
      .padding(16)
      .frame(width: 320, alignment: .leading)
    }
  }

  private func subtitle(_ preview: DisplayModeCoordinator.Preview) -> String {
    let mode = "\(DisplayModeCopy.size(preview.mode)), \(DisplayModeCopy.refresh(preview.mode.refreshHz))"
    return displayName.isEmpty ? mode : "\(displayName) — \(mode)"
  }

  private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
