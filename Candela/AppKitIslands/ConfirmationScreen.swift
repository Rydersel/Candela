import AppKit
import CandelaKit
import CoreGraphics

/// What a confirmation window is ABOUT, which is what decides where it goes.
///
/// The question is "which display is this content about", not
/// preview-versus-report: `ModeConfirmationContent` carries a display in both of
/// its cases, and the preview/report split was only ever how the others happened
/// to spell it.
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
/// Not `ConfirmationPlacement` in `ConfirmationPanel.swift`, which answers where
/// on that screen it sits without overlapping its siblings. The name collision
/// is why this one says `Screen`.
@MainActor
enum ConfirmationScreen {
  /// The screen the window belongs on, or nil to dismiss instead.
  ///
  /// **The window goes where there are PIXELS.** For a preview on a display that
  /// has since become a mirror slave, resolving through `drawable` is a rescue.
  ///
  /// Resolution is one-directional in its safety. A sample lagging a mirror
  /// ENGAGING self-heals: the lookup fails, the caller dismisses, and the next
  /// countdown tick re-runs this against a caught-up sample. A sample lagging a
  /// mirror BREAKING does NOT: the ex-master is a real screen, so the window
  /// appears on the WRONG display and no later tick re-positions it. It is still
  /// answerable there and the countdown still reverts, so the cost is one
  /// preview on the wrong panel.
  ///
  /// Nil means no screen even after resolving: the display departed, or the list
  /// has not caught up with the reconfiguration. Callers hide rather than leave a
  /// window naming the previous display up; a preview retries on every countdown
  /// tick, so a momentarily stale screen list self-heals a second later.
  static func resolve(
    for content: some ConfirmationContent,
    drawable: (CGDirectDisplayID) -> CGDirectDisplayID
  ) -> NSScreen? {
    let target = content.subjectDisplayID.map(drawable) ?? CGMainDisplayID()
    return NSScreen.screens.first { $0.displayID == target }
  }
}
