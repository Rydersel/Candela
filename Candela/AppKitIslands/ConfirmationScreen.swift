import AppKit
import CandelaKit
import CoreGraphics

/// What a confirmation window is ABOUT, which is what decides where it goes.
///
/// #136 (split from #68) starts from a different question than that issue did.
/// It described the shared code as a switch over preview-versus-report, and on
/// that reading `ModeConfirmationContent` does not fit: both of its cases carry
/// a display. Asked as "which display is this content about", all four fit,
/// because that is the question the placement actually answers, and the
/// preview/report split was only ever how three of them happened to spell it.
protocol ConfirmationContent {
  /// The display this content is about, or nil when it concerns no display in
  /// particular and belongs on the main one.
  var subjectDisplayID: CGDirectDisplayID? { get }
}

/// A report is not about a display that changed, so it goes on the main display:
/// the one the user is certainly looking at.
extension MirrorConfirmationContent: ConfirmationContent {
  var subjectDisplayID: CGDirectDisplayID? {
    switch self {
    case let .preview(displayID): displayID
    case .report: nil
    }
  }
}

extension RotationConfirmationContent: ConfirmationContent {
  var subjectDisplayID: CGDirectDisplayID? {
    switch self {
    case let .preview(displayID): displayID
    case .report: nil
    }
  }
}

extension ArrangementConfirmationContent: ConfirmationContent {
  var subjectDisplayID: CGDirectDisplayID? {
    switch self {
    case let .preview(displayID): displayID
    case .report: nil
    }
  }
}

/// Mode has no display-less case: a start failure names the display it failed
/// on, so it belongs there rather than on the main display.
extension ModeConfirmationContent: ConfirmationContent {
  var subjectDisplayID: CGDirectDisplayID? { displayID }
}

/// WHICH screen a confirmation window belongs on.
///
/// Not to be confused with `ConfirmationPlacement` in `ConfirmationPanel.swift`,
/// which answers where on that screen it sits without overlapping its siblings
/// (#126). Two different questions; the name collision between them is what
/// prompted this one to say `Screen`.
@MainActor
enum ConfirmationScreen {
  /// The screen the window belongs on, or nil to dismiss instead.
  ///
  /// **The window goes where there are PIXELS.** For a preview on a display that
  /// has since become a mirror slave, resolving through `drawable` is a rescue.
  ///
  /// Resolution is one-directional in its safety, and the unsafe direction
  /// reaches here. A sample lagging a mirror ENGAGING self-heals: the lookup
  /// fails, the caller dismisses, the panel's identity goes back to nil, and the
  /// next countdown tick (otherwise a no-op) re-runs this against a caught-up
  /// sample and puts the window up. A sample lagging a mirror BREAKING does NOT:
  /// the ex-master is a real screen, so the window appears on the WRONG display,
  /// the identity records it, and no later tick re-positions it. The window is
  /// answerable where it lands and the countdown still reverts, so the cost is a
  /// confirmation on the wrong panel for the life of one preview, not an
  /// unanswerable one.
  ///
  /// Nil means no screen even after resolving: either the display departed (the
  /// coordinator discards the preview on the next screen-parameters
  /// notification) or the list has not caught up with the reconfiguration.
  /// Callers hide rather than leave a window naming the previous display up; a
  /// preview retries this on every countdown tick, so a momentarily stale screen
  /// list self-heals a second later.
  static func resolve(
    for content: some ConfirmationContent,
    drawable: (CGDirectDisplayID) -> CGDirectDisplayID
  ) -> NSScreen? {
    let target = content.subjectDisplayID.map(drawable) ?? CGMainDisplayID()
    return NSScreen.screens.first { $0.displayID == target }
  }
}
