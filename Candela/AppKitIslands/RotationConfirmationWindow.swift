import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep this orientation?" surface — the third caller of
/// `ConfirmationPanel`, which is why it is this short.
///
/// **RT12: it goes on the display it rotated**, resolved through
/// `drawableDisplayID` like the other two, so a rotated mirror slave asks on its
/// master. That is also the surface most likely to look wrong, because RS3
/// measured that a rotation swaps the display's bounds — this window centres
/// itself in `visibleFrame`, which is exactly the value that changes.
@MainActor
final class RotationConfirmationWindow: RotationConfirmationPresenting {
  private let coordinator: RotationCoordinator
  var displayName: (CGDirectDisplayID) -> String = { _ in "" }
  /// Identity by default — right for every unmirrored display; wired at launch.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private let window = ConfirmationPanel<RotationConfirmationView>(
    accessibilityTitle: "Display orientation"
  )

  init(coordinator: RotationCoordinator) {
    self.coordinator = coordinator
  }

  func presentRotationConfirmation(_ content: RotationConfirmationContent) {
    // A report is not about a display that changed, so it goes on the main
    // display — the one the user is certainly looking at.
    let target: CGDirectDisplayID = switch content {
    case let .preview(displayID): drawableDisplayID(displayID)
    case .report: CGMainDisplayID()
    }
    // No screen even after resolving: the display departed, or the list has not
    // caught up with the reconfiguration. A preview retries this on every
    // countdown tick, so a momentarily stale screen list self-heals.
    guard let screen = NSScreen.screens.first(where: { $0.displayID == target }) else {
      dismissRotationConfirmation()
      return
    }

    let name: String = switch content {
    case let .preview(displayID): displayName(displayID)
    case .report: ""
    }
    window.present(content, on: screen) {
      RotationConfirmationView(coordinator: coordinator, content: content, displayName: name)
    }
  }

  func dismissRotationConfirmation() {
    window.dismiss()
  }
}

/// Reads the coordinator directly, so ticks and late failures render themselves.
/// Deliberately the same words as the settings section — two spellings of one
/// statement are two things to keep true.
struct RotationConfirmationView: View {
  let coordinator: RotationCoordinator
  let content: RotationConfirmationContent
  let displayName: String

  var body: some View {
    switch content {
    case .preview: previewBody
    case .report: reportBody
    }
  }

  @ViewBuilder private var previewBody: some View {
    // Rendered from the coordinator's own answer, never from what the caller
    // remembered passing in.
    if let preview = coordinator.preview {
      ConfirmationCard {
        ConfirmationTitle(RotationCopy.question)
        ConfirmationSubtitle(verbatim: RotationCopy.previewSubtitle(
          name: displayName, to: preview.request.to
        ))

        if let failure = preview.failure {
          ConfirmationCaption(RotationCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          ConfirmationCountdown(RotationCopy.countdown(preview.secondsRemaining))
        }

        ConfirmationAnswers {
          // Both answers carry the preview THIS window is rendering, so an
          // answer can only ever resolve what the user was looking at.
          Button(RotationCopy.revert) { Task { await coordinator.revert(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: false))
            .keyboardShortcut(.cancelAction)
          Button(RotationCopy.keep) { Task { await coordinator.confirm(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
        .disabled(coordinator.isApplying)
      }
    }
  }

  @ViewBuilder private var reportBody: some View {
    ConfirmationCard {
      ConfirmationTitle(RotationCopy.reportTitle)
      if let refusal = coordinator.lastRefusal {
        ConfirmationCaption(RotationCopy.refusal(refusal))
      }
      if let failure = coordinator.lastFailure {
        ConfirmationCaption(RotationCopy.applyFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
      }
      // The four-way gate said no (AR12). Nothing was applied, so this is
      // neither a refusal about the display nor a failed apply.
      if let blockedBy = coordinator.blockedBy {
        ConfirmationCaption(ReconfigurationCopy.blocked(by: blockedBy))
      }

      ConfirmationAnswers {
        Button("OK") { coordinator.dismissReport() }
          .buttonStyle(AnswerButtonStyle(isPrimary: true))
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}
