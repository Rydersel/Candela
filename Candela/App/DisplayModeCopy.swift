import CandelaKit
import Foundation
import SwiftUI

/// The words every surface uses to name a display mode: the settings section,
/// the panel's resolution list, and the floating confirmation panel.
///
/// Shared rather than repeated because RM11 is a copy *rule* — "looks like",
/// never "true native HiDPI" — and a rule enforced in three private helpers is
/// a rule that drifts the first time one of them is edited.
enum DisplayModeCopy {
  /// RM11. On a fixed panel only one logical size is a true 2× of the native
  /// framebuffer; everything else renders oversized and downsamples, so the
  /// honest claim is about how big things look, not about what the panel is.
  static func size(_ mode: DisplayMode) -> String {
    size(mode.descriptor)
  }

  /// The same sentence for a STORED choice, which is a descriptor rather than a
  /// live mode. Routed through one implementation so a remembered resolution is
  /// named the same way as the row the user picked it from.
  static func size(_ descriptor: DisplayModeDescriptor) -> String {
    "Looks like \(descriptor.logicalWidth) × \(descriptor.logicalHeight)"
  }

  /// Rates are quantized to one decimal at the CoreGraphics boundary, so 59.9
  /// is a real value and truncating it to "59 Hz" would both misreport it and
  /// collide with a genuine 59 Hz row.
  static func refresh(_ hz: Double) -> String {
    hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz)
  }

  static func countdown(_ seconds: Int) -> String {
    seconds == 1
      ? "Reverting to the previous resolution in 1 second."
      : "Reverting to the previous resolution in \(seconds) seconds."
  }

  // The three sentences below are shown by two surfaces each and are stated
  // once here for the same reason as the labels above: they agree today, and
  // agreement is not a property two literals keep. The CoreGraphics code stays
  // out of them deliberately — it is diagnostic, and belongs in a tooltip
  // rather than in a sentence someone has to read while their screen is wrong.

  // Computed, not stored: `LocalizedStringKey` is not `Sendable`, so a static
  // `let` of one is a concurrency error under complete checking. Each of these
  // is a literal with no state behind it.

  /// A `begin()` that failed. Nothing was applied, so nothing needs answering.
  static var startFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not switch this display. Nothing changed."
  }

  /// A `confirm()`/`revert()`/expiry that threw. The preview is still on the
  /// display and nothing auto-retries, so this must invite another attempt.
  static var resolveFailure: LocalizedStringKey {
    "\(AppInfo.productName) could not complete that change. The display is still showing the preview — try again."
  }

  /// Said only alongside `resolveFailure`: the countdown is spent, so the user
  /// is now the only thing that can end this.
  static var expiryAlreadyRan: LocalizedStringKey {
    "The automatic revert has already run, so it will not try again on its own."
  }

  // MARK: - Reapply
  //
  // Reapply happens at launch and on reconnect, with nobody watching. These
  // three sentences are the entire difference between "Candela restored your
  // resolution" and "Candela did something to your display and did not say
  // what", so each one names the resolution that was ASKED FOR first — that is
  // the thing the user recognises — and only then what actually happened.

  /// Something adjacent was applied (or is already on screen). Never silent:
  /// the user chose a resolution deliberately and is not on it.
  static func reapplySubstituted(
    requested: DisplayModeDescriptor, applied: DisplayMode
  ) -> LocalizedStringKey {
    "The resolution saved for this display — \(size(requested)), \(refresh(requested.refreshHz)) — is no longer available. \(AppInfo.productName) used \(size(applied)), \(refresh(applied.refreshHz)) instead."
  }

  /// Nothing close enough existed, so nothing was changed. Says so explicitly:
  /// "we left it alone" is information, and its absence reads as a silent
  /// failure of the whole feature.
  static func reapplyUnavailable(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "The resolution saved for this display — \(size(requested)), \(refresh(requested.refreshHz)) — is no longer available, and nothing close enough to use in its place. \(AppInfo.productName) left this display as it found it."
  }

  /// The apply itself failed. Distinct from `reapplyUnavailable` because the
  /// mode still exists — trying again, from the list, is worth doing.
  static func reapplyFailed(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "\(AppInfo.productName) could not restore the resolution saved for this display — \(size(requested)), \(refresh(requested.refreshHz)). Nothing was changed."
  }

  /// One sentence for whichever of the three happened, so both surfaces make
  /// the same statement about the same report.
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
