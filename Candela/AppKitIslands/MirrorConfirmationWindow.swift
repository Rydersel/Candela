import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep mirroring?" surface, and the only place a hotkey-initiated mirror
/// change ever says anything.
///
/// Why it is a window at all, and why its buttons take the first click, are
/// `ConfirmationPanel`'s to explain. What is specific here is where it goes: on
/// the **master**, because the display the request named has no `NSScreen` from
/// the instant the preview applies — that is not a rescue, it is the mechanism.
@MainActor
final class MirrorConfirmationWindow: MirrorConfirmationPresenting {
  private let coordinator: MirroringCoordinator
  /// Resolves to a display that has a screen — see `ModeConfirmationWindow`.
  /// The default is the IDENTITY function and not something obviously broken,
  /// because identity is right for every unmirrored display; wired at launch.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private let window = ConfirmationPanel<MirrorConfirmationView>(
    accessibilityTitle: "Display mirroring"
  )

  init(coordinator: MirroringCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - MirrorConfirmationPresenting

  func presentMirrorConfirmation(_ content: MirrorConfirmationContent) {
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

    window.present(content, on: screen) {
      MirrorConfirmationView(coordinator: coordinator, content: content)
    }
  }

  func dismissMirrorConfirmation() {
    window.dismiss()
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
      ConfirmationCard {
        ConfirmationTitle(MirroringCopy.question)
        ConfirmationSubtitle(verbatim: subtitle(preview))

        if let failure = preview.failure {
          // Nothing auto-retries a failed resolution. Staying silent would leave
          // the user on a topology they never approved, held only until the app
          // exits.
          ConfirmationCaption(MirroringCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          ConfirmationCountdown(MirroringCopy.countdown(preview.secondsRemaining))
        }

        ConfirmationAnswers {
          // Both answers carry the preview THIS window is rendering, so an
          // answer can only ever resolve what the user was looking at.
          Button(MirroringCopy.stopNow) { Task { await coordinator.revert(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: false))
            .keyboardShortcut(.cancelAction)
          Button(MirroringCopy.keep) { Task { await coordinator.confirm(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
        .disabled(coordinator.isApplying)
      }
    }
  }

  // MARK: - A change that did not happen, or did not happen fully

  @ViewBuilder private var reportBody: some View {
    ConfirmationCard {
      ConfirmationTitle(MirroringCopy.reportTitle)
      // Every refusal states a reason, and there are EIGHT of them. There is no
      // "it did not work", and no `default:` arm — `MirroringCopy.refusal`
      // switches exhaustively so a new case is a compile error rather than a
      // silently generic sentence.
      if let refusal = coordinator.lastRefusal {
        // Named through the coordinator, because one of the eight refusals
        // carries the displays it is about and says nothing true without them.
        ConfirmationCaption(MirroringCopy.refusal(refusal, name: coordinator.displayName))
      }
      if let failure = coordinator.lastFailure {
        ConfirmationCaption(MirroringCopy.applyFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
      }
      // The four-way gate said no (AR12). Neither a refusal about the topology
      // nor a failed apply — nothing was staged. Said out loud because a hotkey
      // press has no other surface at all, and silence on it reads as a dead key.
      if let blockedBy = coordinator.blockedBy {
        ConfirmationCaption(ReconfigurationCopy.blocked(by: blockedBy))
      }
      // A break that committed exactly what it staged and still left a set
      // standing. Said out loud, because "mirroring off" over a set the user is
      // still looking at is the defect this whole feature exists to close.
      if !coordinator.lastPartialBreak.isEmpty {
        ConfirmationSubtitle(verbatim: MirroringCopy.partialBreak(
          residual: coordinator.lastPartialBreak, name: coordinator.displayName
        ))
      }

      ConfirmationAnswers {
        Button("OK") { coordinator.dismissReport() }
          .buttonStyle(AnswerButtonStyle(isPrimary: true))
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func subtitle(_ preview: MirroringCoordinator.Preview) -> String {
    let count = preview.value.applied.count
    return count == 1
      ? "1 display is showing this one's picture."
      : "\(count) displays are showing this one's picture."
  }
}
