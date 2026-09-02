import CandelaKit
import Foundation
import SwiftUI

/// Mode-naming copy shared by every surface. Naming a size is a copy rule (never imply
/// true native HiDPI at an arbitrary size), and a rule split across private
/// helpers drifts the first time one is edited.
enum DisplayModeCopy {
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
  /// no mode behind it. Routed here so the times sign has one spelling.
  static func size(width: Int, height: Int) -> String {
    "\(width) × \(height)"
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
  static func previewAnnouncement(mode: DisplayMode, seconds: Int) -> String {
    let spoken = ModeSpeech.spoken(
      logicalWidth: mode.logicalWidth,
      logicalHeight: mode.logicalHeight,
      refreshHz: mode.refreshHz
    )
    return "Display changed to \(spoken). Keep this resolution? \(countdown(seconds))"
  }

  // The CoreGraphics code stays out of these sentences: it is diagnostic, and
  // belongs in a tooltip, not in a line read while the screen is wrong.

  // Computed, not stored: `LocalizedStringKey` is not `Sendable`, so a static
  // `let` of one is a concurrency error under complete checking.

  /// A `begin()` that failed. Nothing was applied, so nothing needs answering.
  static var startFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not switch this display. Nothing changed."
  }

  /// One sentence for either reason a selection took no effect: a new reason
  /// with no row here is a compile error, not surfaces quietly disagreeing.
  static func startFailure(_ reason: DisplayModeCoordinator.StartFailure.Reason) -> LocalizedStringKey {
    switch reason {
    case .failed: startFailure
    case let .blocked(claimant): ReconfigurationCopy.blocked(by: claimant)
    }
  }

  /// The tooltip beside it: diagnostic, not part of the statement.
  static func startFailureDiagnostic(_ reason: DisplayModeCoordinator.StartFailure.Reason) -> String {
    switch reason {
    case let .failed(error): "CoreGraphics error \(error.cgErrorCode)"
    case let .blocked(claimant): "Held by \(claimant.rawValue)"
    }
  }

  /// A `confirm()`/`revert()`/expiry that threw. The preview is still on the
  /// display and nothing auto-retries, so this must invite another attempt.
  static var resolveFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not complete that change. The display is still showing the preview. Try again."
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
  /// still exists, so trying again from the list is worth doing.
  static func reapplyFailed(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "\(AppInfo.productName) could not restore the resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))). Nothing was changed."
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
