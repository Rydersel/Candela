import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep this resolution?" surface — the DEFAULT owner of the answer
/// (SO6). The coordinator presents it for every preview except one whose
/// `surface` is `.settingsBanner` (a change started from a key settings
/// window), where the banner region answers instead and this window is never
/// shown: one answerable surface per preview, decided at start.
///
/// Why it is a window at all, and why its buttons take the first click, are
/// `ConfirmationPanel`'s to explain — this type owns only the two things that are
/// specific to a resolution change: where the question goes, and what it says.
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
  /// Resolves a display to one that has an `NSScreen` — itself, or its mirror
  /// master (DT15). Injected for the same reason `displayName` is: the island
  /// holds no topology of its own and exercises no judgement about mirroring
  /// (DT16).
  ///
  /// The default is the IDENTITY function and not something obviously broken,
  /// because identity is exactly the old behaviour and is right for every
  /// unmirrored display. Wired at launch in `StatusItemController`.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private let window = ConfirmationPanel<ModeConfirmationView>(
    accessibilityTitle: "Display resolution"
  )

  init(coordinator: DisplayModeCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - ModeConfirmationPresenting

  func presentConfirmation(_ content: ModeConfirmationContent) {
    guard let screen = ConfirmationScreen.resolve(
      for: content, drawable: drawableDisplayID
    ) else {
      dismissConfirmation()
      return
    }

    window.present(content, on: screen) {
      ModeConfirmationView(
        coordinator: coordinator, content: content,
        displayName: displayName(content.displayID)
      )
    }
  }

  func dismissConfirmation() {
    window.dismiss()
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
      ConfirmationCard {
        ConfirmationTitle("Keep this resolution?")
        ConfirmationSubtitle(verbatim: subtitle(preview))

        if let failure = preview.failure {
          // Nothing auto-retries a failed resolution. Staying silent would
          // leave the display on a mode the user never approved, held only
          // until the app exits.
          ConfirmationCaption(DisplayModeCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          ConfirmationCountdown(DisplayModeCopy.countdown(preview.secondsRemaining))
        } else if preview.failure != nil {
          ConfirmationCaption(DisplayModeCopy.expiryAlreadyRan)
        }

        ConfirmationAnswers {
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
      ConfirmationCard {
        ConfirmationTitle("Resolution not changed")
        if !displayName.isEmpty {
          ConfirmationSubtitle(verbatim: displayName)
        }
        ConfirmationCaption(DisplayModeCopy.startFailure(failure.reason))
          .help(DisplayModeCopy.startFailureDiagnostic(failure.reason))

        ConfirmationAnswers {
          Button("OK") { coordinator.dismissStartFailure() }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func subtitle(_ preview: DisplayModeCoordinator.Preview) -> String {
    let mode = "\(DisplayModeCopy.size(preview.mode)), \(DisplayModeCopy.refresh(preview.mode.refreshHz))"
    return displayName.isEmpty ? mode : "\(displayName): \(mode)"
  }
}
