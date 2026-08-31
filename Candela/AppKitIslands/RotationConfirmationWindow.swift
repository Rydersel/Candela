import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep this orientation?" surface, the third caller of `ConfirmationPanel`.
///
/// RT12: it goes on the display it rotated, resolved through `drawableDisplayID`,
/// so a rotated mirror slave asks on its master. RS3 measured that rotation swaps
/// the display's bounds, and this window centres itself in `visibleFrame`.
@MainActor
final class RotationConfirmationWindow: RotationConfirmationPresenting {
  private let coordinator: RotationCoordinator
  var displayName: (CGDirectDisplayID) -> String = { _ in "" }
  /// Identity by default, right for every unmirrored display. Wired at launch.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private let window = ConfirmationPanel<RotationConfirmationView>(
    accessibilityTitle: "Display orientation"
  )

  init(coordinator: RotationCoordinator) {
    self.coordinator = coordinator
  }

  func presentRotationConfirmation(_ content: RotationConfirmationContent) {
    guard let screen = ConfirmationScreen.resolve(
      for: content, drawable: drawableDisplayID
    ) else {
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
/// Same words as the settings section, deliberately: two spellings drift apart.
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
    // Rendered from the coordinator's own answer, not what the caller passed in.
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
          // Both answers carry the preview this window rendered, so an answer
          // can only resolve what the user was looking at.
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
      // AR12's gate said no. Nothing was applied, so this is neither a refusal
      // about the display nor a failed apply.
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
