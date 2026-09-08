import CandelaKit
import Foundation
import SwiftUI

/// Mode-naming copy shared by every surface. Naming a size is a copy rule (never imply
/// true native HiDPI at an arbitrary size), and a rule split across private
/// helpers drifts the first time one is edited.
enum DisplayModeCopy {
  /// How a surface spells a size. Everything in the app windows writes
  /// "2560 × 1440" and calls it a resolution; guided setup writes "2560 x 1440"
  /// and calls it a size, on every line it has. A sentence that arrives in the
  /// other dialect reads as a line borrowed from somewhere else, so the dialect
  /// is a parameter here rather than a second copy of the sentence over there.
  enum SizeDialect {
    case resolution
    case size

    var times: String {
      switch self {
      case .resolution: "×"
      case .size: "x"
      }
    }

    var noun: String {
      switch self {
      case .resolution: "resolution"
      case .size: "size"
      }
    }
  }

  /// The plain size, with no hedge. This rule rides on the tags of surfaces that
  /// OFFER a size (the shared size vocabulary, one source in
  /// `DisplayModeCoordinator.Catalog.tags(for:isLowResolutionDuplicate:)`);
  /// surfaces that only NAME the mode in force carry the size alone.
  static func size(_ mode: DisplayMode) -> String {
    size(mode.descriptor)
  }

  /// Same label for a stored choice, so a remembered resolution reads exactly
  /// like the row it was picked from.
  static func size(_ descriptor: DisplayModeDescriptor) -> String {
    size(width: descriptor.logicalWidth, height: descriptor.logicalHeight)
  }

  /// Bare numbers, for the density model's recommendation: a logical size with
  /// no mode behind it. Routed here so each dialect's times sign has one
  /// spelling.
  static func size(width: Int, height: Int, dialect: SizeDialect = .resolution) -> String {
    "\(width) \(dialect.times) \(height)"
  }

  /// Marks an option this app's own enumeration found. States what WE did, not
  /// what macOS hides: no API reports the Displays pane's list. No quality claim:
  /// every one of these renders oversized and downsamples.
  static var addedByApp: String { "Added by \(AppInfo.productName)" }

  /// The mark on the size the density model names for this panel. One word is
  /// the whole claim: this display's physical size, never the mode's
  /// quality and never HiDPI.
  static var recommended: String { "Recommended" }

  /// Built-in panels: macOS calls this size Default, so both windows do too.
  static var defaultSize: String { "Default" }

  /// The hub's one-line suggestion: the size, then the reason. Two second
  /// sentences because the recommended size is not always a scaled mode.
  ///
  /// Keyed off the mode's NATIVE flag, never framebuffer equality with the
  /// panel's pixel count: a 5K panel's exact-2x HiDPI mode fills the native
  /// framebuffer at half the logical size, so a pixel test calls it unscaled and
  /// we would tell a 5K owner that looks-like-2560 × 1440 is native.
  static func recommendationCallout(width: Int, height: Int, isNative: Bool) -> String {
    let fit = "For this display's size, \(size(width: width, height: height)) is the comfortable fit."
    return isNative
      ? "\(fit) It is this display's native resolution."
      : "\(fit) It renders larger and scales the result."
  }

  /// Names the act, not the size: a button repeating the size above reads as a
  /// second, different size.
  static var recommendationApply: String { "Use This Size" }

  /// Permanent for this display: the dismissal pref sits outside the
  /// per-display reset batch, so only Reset All Settings clears it. The
  /// Recommended mark on the size picker survives, so the suggestion stays
  /// reachable.
  static var recommendationDismiss: String { "Dismiss" }

  /// Rates quantize to one decimal at the CoreGraphics boundary, so 59.9 is
  /// real: truncating it collides with a genuine 59 Hz row.
  static func refresh(_ hz: Double) -> String {
    hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz)
  }

  static func countdown(_ seconds: Int) -> String {
    seconds == 1
      ? "Reverting to the previous resolution in 1 second."
      : "Reverting to the previous resolution in \(seconds) seconds."
  }

  /// The non-owning surface's whole rendering: status, plus where the
  /// buttons are. A deadline with nowhere to answer reads as a countdown to
  /// nothing.
  static func passiveCountdown(_ seconds: Int) -> String {
    seconds == 1
      ? "Reverting in 1 second. Answer in the confirmation window."
      : "Reverting in \(seconds) seconds. Answer in the confirmation window."
  }

  /// A11y contract 8: posted when the answerable banner appears. The 10- and
  /// 3-second re-announcements reuse `countdown(_:)`.
  ///
  /// Names the resolution, never says the display changed to it: an unhonoured
  /// commit leaves something else on the glass, and the listener cannot check.
  static func previewAnnouncement(mode: DisplayMode, seconds: Int) -> String {
    let spoken = ModeSpeech.spoken(
      logicalWidth: mode.logicalWidth,
      logicalHeight: mode.logicalHeight,
      refreshHz: mode.refreshHz
    )
    return "Keep \(spoken)? \(countdown(seconds))"
  }

  /// Beside the keep question, when the apply that started the preview
  /// committed onto something else. The question names what was ASKED for,
  /// because that is what Keep re-applies; this names what the display is
  /// showing, which is the one thing the person answering cannot check against
  /// the question in front of them.
  ///
  /// States the geometry and nothing else. Whether the mode is wrong for the
  /// panel, or scanned out on the wrong wire timing, is not something a
  /// readback can tell us.
  static func achievedGeometry(_ commit: DisplayConfigError.UnhonouredCommit) -> String {
    guard let achieved = commit.achieved else { return unreadableAchievedGeometry() }
    return achievedGeometry(
      width: achieved.logicalWidth, height: achieved.logicalHeight,
      refreshHz: achieved.refreshHz
    )
  }

  /// The same sentence from bare numbers, for a surface holding the geometry
  /// without the error it came from: guided setup's flow model is deliberately
  /// free of engine types, and its adapters carry them. That surface passes its
  /// own dialect, so the caption reads in the page's spelling rather than
  /// arriving in the settings window's.
  static func achievedGeometry(
    width: Int, height: Int, refreshHz: Double, dialect: SizeDialect = .resolution
  ) -> String {
    "The display is showing \(size(width: width, height: height, dialect: dialect)), \(refresh(refreshHz))."
  }

  /// The other arm, spelled once for both entry points.
  static func unreadableAchievedGeometry(dialect: SizeDialect = .resolution) -> String {
    "This display did not report which \(dialect.noun) it is showing."
  }

  // The CoreGraphics code stays out of these sentences: it is diagnostic, and
  // belongs in a tooltip, not in a line read while the screen is wrong.

  // Computed, not stored: `LocalizedStringKey` is not `Sendable`, so a static
  // `let` of one is a concurrency error under complete checking.

  /// A `begin()` that failed with nothing committed. No preview is armed and no
  /// transaction went through, so this display is where it was: the mode was
  /// unreadable, the change would not stage, or the commit was refused.
  static var startFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not switch this display to the resolution you picked. Nothing changed, so it is still showing the resolution it was on."
  }

  /// The same failure with a commit behind it, which has exactly one route:
  /// ending an outstanding preview on ANOTHER display committed without landing
  /// where it was asked to, and `ModePreviewSession.begin` returns before it
  /// touches this display. So this display did not move and that one did not go
  /// back, and neither half may be said the other way round.
  static var startFailureAfterACommit: LocalizedStringKey {
    "\(AppInfo.productName) could not switch this display to the resolution you picked, because another display could not be put back to the resolution it was on. Check that display before trying again."
  }

  /// One sentence for each reason a selection took no effect: a new reason with
  /// no row here is a compile error, not surfaces quietly disagreeing.
  static func startFailure(_ reason: DisplayModeCoordinator.StartFailure.Reason) -> LocalizedStringKey {
    switch reason {
    case let .failed(error): error.didCommit ? startFailureAfterACommit : startFailure
    case let .blocked(claimant): ReconfigurationCopy.blocked(by: claimant)
    }
  }

  /// The floating card's subject line, under a title that says this display's
  /// resolution did not change.
  ///
  /// The committed arm names TWO displays. Its caption is about a display that
  /// is not this one, so a card naming one display above that sentence reads as
  /// a contradiction rather than as one story. The other display cannot be
  /// named: `DisplayConfigError` carries no display ID, and widening it would
  /// touch every caller.
  static func startFailureSubject(
    displayName: String, reason: DisplayModeCoordinator.StartFailure.Reason
  ) -> String {
    guard case let .failed(error) = reason, error.didCommit else { return displayName }
    return displayName.isEmpty
      ? "This display and another display"
      : "\(displayName) and another display"
  }

  /// The tooltip beside it: diagnostic, not part of the statement.
  ///
  /// Through `diagnostic(_:)`: ending a preview on ANOTHER display can commit
  /// without taking, and that failure has no CoreGraphics code to print. It also
  /// has no display ID on it, so which display it is about is said here, where
  /// the route is known, rather than inside `diagnostic`, which several surfaces
  /// share.
  static func startFailureDiagnostic(_ reason: DisplayModeCoordinator.StartFailure.Reason) -> String {
    switch reason {
    case let .failed(error):
      error.didCommit ? "Another display: \(diagnostic(error))" : diagnostic(error)
    case let .blocked(claimant): "Held by \(claimant.rawValue)"
    }
  }

  /// The tooltip for any `DisplayConfigError`; no surface reads `cgErrorCode`
  /// itself. An unhonoured commit's code is a sentinel, not a CoreGraphics
  /// error, and the finding there is which resolution the display was left on.
  static func diagnostic(_ error: DisplayConfigError) -> String {
    guard let unhonoured = error.unhonouredCommit else {
      return "CoreGraphics error \(error.cgErrorCode)"
    }
    let landed = unhonoured.achieved.map { "\(size($0)), \(refresh($0.refreshHz))" }
    return "CoreGraphics reported success; display shows \(landed ?? "an unreadable resolution")"
  }

  /// A `confirm()`/`revert()`/expiry that threw. Nothing auto-retries, so this
  /// must invite another attempt. It does not say which resolution is on the
  /// glass: the readback can fail on a commit CoreGraphics already made.
  static var resolveFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not complete that change. Check this display, then try again."
  }

  /// Said only alongside `resolveFailure`: the countdown is spent, so the user
  /// is now the only thing that can end this.
  static var expiryAlreadyRan: LocalizedStringKey {
    "The automatic revert has already run, so it will not try again on its own."
  }

  // MARK: - Reapply
  //
  // Reapply runs at launch and on reconnect with nobody watching, so each
  // sentence names the resolution that was asked for first, then what happened.

  /// Something adjacent was applied (or is already on screen). Never silent:
  /// the user chose a resolution deliberately and is not on it.
  static func reapplySubstituted(
    requested: DisplayModeDescriptor, applied: DisplayMode
  ) -> LocalizedStringKey {
    "The resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))) is no longer available. \(AppInfo.productName) used \(size(applied)), \(refresh(applied.refreshHz)) instead."
  }

  /// Nothing close enough existed, so nothing changed. Said out loud: silence
  /// here reads as the whole feature failing.
  static func reapplyUnavailable(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "The resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))) is no longer available, and nothing close enough to use in its place. \(AppInfo.productName) left this display as it found it."
  }

  /// The apply failed. Distinct from `reapplyUnavailable` because the mode
  /// still exists, so trying again from the list is worth doing. No claim about
  /// where the display was left: the readback can fail on a commit that went
  /// through, unattended.
  static func reapplyFailed(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "\(AppInfo.productName) could not restore the resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))). Pick it from the list of resolutions to try again."
  }

  /// One sentence for whichever happened, so both surfaces say the same thing.
  static func reapply(
    requested: DisplayModeDescriptor, notice: ModeReapplyNotice
  ) -> LocalizedStringKey {
    switch notice {
    case let .substituted(mode): reapplySubstituted(requested: requested, applied: mode)
    case .unavailable: reapplyUnavailable(requested: requested)
    case .failed: reapplyFailed(requested: requested)
    }
  }
}
