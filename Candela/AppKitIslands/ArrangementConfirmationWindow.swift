import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// The "Keep this arrangement?" surface, a CALLER of `ConfirmationPanel` rather
/// than a window type of its own, which is why it is this short.
///
/// A window that re-derives its own buttons is how one shipped with an invisible
/// grey primary button: `.borderedProminent` renders inactive in an `.accessory`
/// app that is never frontmost. Every keep-or-revert question in this app is
/// drawn by `ConfirmationCard` and answered by `AnswerButtonStyle`.
///
/// **It goes on the display holding the menu bar**, which the coordinator
/// resolves from the ACHIEVED layout: the arrangement change may itself have
/// moved the menu bar, and the question is worth asking where the user can see
/// the consequence.
@MainActor
final class ArrangementConfirmationWindow: ArrangementConfirmationPresenting {
  private let coordinator: ArrangementCoordinator
  var displayName: (CGDirectDisplayID) -> String = { _ in "" }
  /// Identity by default, which is right for every unmirrored display; wired at
  /// launch.
  var drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { $0 }

  private let window = ConfirmationPanel<ArrangementConfirmationView>(
    accessibilityTitle: "Display arrangement"
  )

  init(coordinator: ArrangementCoordinator) {
    self.coordinator = coordinator
  }

  func presentArrangementConfirmation(_ content: ArrangementConfirmationContent) {
    guard let screen = ConfirmationScreen.resolve(
      for: content, drawable: drawableDisplayID
    ) else {
      dismissArrangementConfirmation()
      return
    }

    window.present(content, on: screen) {
      ArrangementConfirmationView(
        coordinator: coordinator, content: content, displayName: displayName
      )
    }
  }

  func dismissArrangementConfirmation() {
    window.dismiss()
  }
}

/// Reads the coordinator directly, so ticks and late failures render themselves.
/// The same words as the canvas: two spellings of one statement are two things
/// to keep true.
struct ArrangementConfirmationView: View {
  let coordinator: ArrangementCoordinator
  let content: ArrangementConfirmationContent
  /// A closure rather than a resolved string: a layout is a fact about the whole
  /// display set, so the sentences below name more than one display.
  let displayName: (CGDirectDisplayID) -> String

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
        ConfirmationTitle(ArrangementCopy.question)
        ConfirmationSubtitle(verbatim: ArrangementCopy.previewSubtitle(
          displayCount: preview.value.achieved.tiles.count,
          mainDisplayName: preview.value.achieved.mainDisplayID.map(displayName) ?? ""
        ))

        // What macOS did that was not asked for (§6.3). Shown here as well as
        // in the canvas because this window is the surface guaranteed to be on
        // screen, and a layout the system rewrote is a different question from
        // the one that was asked.
        ForEach(Array(preview.notices.enumerated()), id: \.offset) { _, notice in
          ConfirmationCaption(ArrangementCopy.notice(notice, name: displayName))
        }

        if let failure = preview.failure {
          ConfirmationCaption(ArrangementCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          ConfirmationCountdown(ArrangementCopy.countdown(preview.secondsRemaining))
        } else if preview.failure != nil {
          ConfirmationCaption(ArrangementCopy.expiryAlreadyRan)
        }

        ConfirmationAnswers {
          // Both answers carry the preview THIS window is rendering, so an
          // answer can only ever resolve what the user was looking at.
          Button(ArrangementCopy.revert) { Task { await coordinator.revert(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: false))
            .keyboardShortcut(.cancelAction)
          Button(ArrangementCopy.keep) { Task { await coordinator.confirm(preview) } }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
        .disabled(coordinator.isApplying)
      }
    }
  }

  /// What this card is reporting, which is what titles it. The precedence
  /// between a known divergence, an uncertain one and "nothing changed" is
  /// decided in `CandelaKit`, where a test can reach it.
  private var reportSubject: ArrangementReportSubject {
    .of(
      hasRecoverableLayout: coordinator.recoverableLayout != nil,
      restoreNotice: coordinator.restoreNotice
    )
  }

  @ViewBuilder private var reportBody: some View {
    ConfirmationCard {
      ConfirmationTitle(ArrangementCopy.reportTitle(reportSubject))
      if !coordinator.lastInvalidLayout.isEmpty {
        ConfirmationCaption(ArrangementCopy.invalidLayout(
          coordinator.lastInvalidLayout, name: displayName
        ))
      }
      if let failure = coordinator.lastFailure {
        ConfirmationCaption(ArrangementCopy.applyFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
      }
      // The gate said no. Nothing was staged, so this is neither a
      // refusal about the layout nor a failed apply.
      if let blockedBy = coordinator.blockedBy {
        ConfirmationCaption(ReconfigurationCopy.blocked(by: blockedBy))
      }
      // A saved layout that did not come back. It shares this card rather than
      // getting a window of its own: a second window asking the same class of
      // question is how one shipped with an invisible primary button.
      if let restoreNotice = coordinator.restoreNotice {
        ConfirmationCaption(ArrangementCopy.restoreNotice(restoreNotice, name: displayName))
      }

      // The layout the machine was in before an apply that diverged, offered
      // back. Only this branch has a second button, because only it has
      // something to do rather than something to read.
      if coordinator.recoverableLayout != nil {
        ConfirmationCaption(ArrangementCopy.divergedOffer)
        ConfirmationAnswers {
          Button("OK") { coordinator.dismissReport() }
            .buttonStyle(AnswerButtonStyle(isPrimary: false))
            .keyboardShortcut(.cancelAction)
          Button(ArrangementCopy.restore) { coordinator.restoreRecoverableLayout() }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
      } else {
        ConfirmationAnswers {
          Button("OK") { coordinator.dismissReport() }
            .buttonStyle(AnswerButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }
}
