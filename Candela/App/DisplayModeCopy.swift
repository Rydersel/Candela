import CandelaKit
import Foundation
import SwiftUI

/// The words every surface uses to name a display mode: the settings section,
/// the panel's resolution list, and the floating confirmation panel.
///
/// Shared rather than repeated because RM11 is a copy *rule* — never imply true
/// native HiDPI at an arbitrary size — and a rule enforced in three private
/// helpers is a rule that drifts the first time one of them is edited.
enum DisplayModeCopy {
  /// The plain size, with no hedge.
  ///
  /// It used to read "Looks like 2560 × 1440", Apple's own idiom for a scaled
  /// mode. That was the whole of our RM11 answer and it cost more than it
  /// bought: the hedge is the loudest thing in every row, it says nothing about
  /// WHICH way a mode is inexact, and it reads as evasive next to a picker
  /// labelled Size.
  ///
  /// RM11 is carried by tags on the surfaces that OFFER a size, because there
  /// the size alone says nothing about which duplicate is which. Every one of
  /// them now states it in SO14's vocabulary, from the single
  /// `DisplayModeCoordinator.Catalog.tags(for:isLowResolutionDuplicate:)`:
  /// "HiDPI" retired, the 1x duplicate tagged "low resolution" instead. The
  /// menu-bar list was the last surface still saying "HiDPI", left alone by the
  /// settings overhaul (spec §11) and closed as #96.
  ///
  /// The settings hub's curated Size picker is the ruled
  /// exception (SO14/SO18): it is deduplicated by logical size, "HiDPI" is
  /// retired from copy, and the row states its OUTCOME (the caps-at marker)
  /// instead of its catalog entry. Surfaces that merely NAME the mode already
  /// in force — the confirmation window's subtitle, the reapply reports, the
  /// panel's collapsed Resolution summary — carry the size alone, because there
  /// the claim is "this is the mode", not "this size is what the panel is".
  static func size(_ mode: DisplayMode) -> String {
    size(mode.descriptor)
  }

  /// The same label for a STORED choice, which is a descriptor rather than a
  /// live mode. Routed through one implementation so a remembered resolution is
  /// named the same way as the row the user picked it from.
  static func size(_ descriptor: DisplayModeDescriptor) -> String {
    size(width: descriptor.logicalWidth, height: descriptor.logicalHeight)
  }

  /// The same label from bare numbers, for the density model's recommendation:
  /// it names a logical SIZE with no mode behind it (`SizeRecommendation` holds
  /// no `ioModeID` on purpose). Routed here so the times sign has one spelling.
  static func size(width: Int, height: Int) -> String {
    "\(width) × \(height)"
  }

  /// The mark on an option that is in the list because this app's own
  /// enumeration found it. Shown on the surfaces that OFFER a size to choose
  /// from, so the value the app adds is legible at the moment it is delivered.
  ///
  /// Three constraints meet in these three words. It states what WE did and
  /// never what macOS does: no API reports which resolutions the Displays
  /// settings pane is showing, so "hidden by macOS" is a claim we cannot check.
  /// It makes no quality claim (RM11): every one of these renders oversized and
  /// downsamples, so "better", "extra sharp" or "full resolution" would all be
  /// false. And it says nothing about the mechanism, which is the app's
  /// business and not the reader's.
  ///
  /// Spoken and seen are the same words, deliberately: there is no symbol or
  /// abbreviation here for a screen reader to mispronounce.
  static var addedByApp: String { "Added by \(AppInfo.productName)" }

  /// The mark on the size the density model names for this panel. Stated here
  /// with the other marks because a row can carry both, and two literals in two
  /// views is how one word becomes two.
  ///
  /// One word, and it is the whole claim (RM11): a suggestion about THIS
  /// display's physical size, never a claim about the mode's quality and never
  /// a HiDPI implication. Everything that would earn a longer sentence, the
  /// physical measurement behind it included, belongs to a surface with room
  /// for a sentence, never to this word.
  ///
  /// Spoken and seen are the same word, like `addedByApp`: nothing here for a
  /// screen reader to mispronounce.
  ///
  /// It shares a word with `AllModesPage.ListMode.recommended`, whose segmented
  /// control names the CURATED LIST. The overlap is deliberate rather than
  /// missed: both mean "this is what we suggest", at list scale and at row
  /// scale, and RM11 fixes this word.
  static var recommended: String { "Recommended" }

  /// The hub's one-line suggestion: the size and the reason in one sentence.
  ///
  /// Two second sentences, picked by the caller from the curated row this
  /// applies, because the recommended size is NOT always a scaled mode: on the
  /// MAG running 1920 × 1080 the model names 3440 × 1440, whose representative
  /// is the panel's own native mode. "It renders larger and scales the result"
  /// scales nothing there.
  ///
  /// Keyed off the mode's NATIVE flag, never off framebuffer equality with the
  /// panel's native pixel count: the exact-2x HiDPI mode of a 5K or 6K panel
  /// renders into the native framebuffer while presenting half the logical
  /// size, so a pixel-equality test calls it unscaled and this would tell a 5K
  /// owner that looks-like-2560 × 1440 is their native resolution. The flag
  /// answers the question actually being asked, and everything it leaves out
  /// falls to the scaled sentence, which is the milder of the two claims.
  ///
  /// The scaled sentence is the RM11 half: it states the mechanism plainly and
  /// never implies the panel is natively that size. The other states provenance,
  /// and neither makes a quality claim.
  ///
  /// The claim is about THIS panel's physical size and nothing else. No
  /// measurement, no PPI, no band: those are the model's workings, and a
  /// suggestion someone has to do arithmetic to evaluate is not a suggestion.
  static func recommendationCallout(width: Int, height: Int, isNative: Bool) -> String {
    let fit = "For this display's size, \(size(width: width, height: height)) is the comfortable fit."
    return isNative
      ? "\(fit) It is this display's native resolution."
      : "\(fit) It renders larger and scales the result."
  }

  /// Names the ACT, not the size: the sentence above already named the size,
  /// and a button repeating it would be read as a second, different size.
  static var recommendationApply: String { "Use This Size" }

  /// Closes the row for this display for good: the dismissal pref is not in the
  /// per-display reset's enumerated batch, so only Reset All Settings clears it.
  /// What keeps the suggestion reachable afterwards is the Recommended mark on
  /// the size picker, which this does not touch: the passive signal outlives the
  /// row that argues for it.
  static var recommendationDismiss: String { "Dismiss" }

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

  /// The NON-owning surface's whole rendering (SO6): status plus a pointer to
  /// where the buttons are. Never shown beside buttons — a passive line that
  /// named a deadline without saying where to answer would read as a countdown
  /// to nothing.
  static func passiveCountdown(_ seconds: Int) -> String {
    seconds == 1
      ? "Reverting in 1 second. Answer in the confirmation window."
      : "Reverting in \(seconds) seconds. Answer in the confirmation window."
  }

  /// A11y contract 8: the announcement posted when the answerable banner
  /// appears. Names the new mode in spoken form and the deadline; the 10- and
  /// 3-second re-announcements reuse `countdown(_:)`.
  static func previewAnnouncement(mode: DisplayMode, seconds: Int) -> String {
    let spoken = ModeSpeech.spoken(
      logicalWidth: mode.logicalWidth,
      logicalHeight: mode.logicalHeight,
      refreshHz: mode.refreshHz
    )
    return "Display changed to \(spoken). Keep this resolution? \(countdown(seconds))"
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

  /// The sentence for either reason a selection took no effect, in ONE place:
  /// three surfaces render `StartFailure`, and a reason added without a row here
  /// is a compile error rather than three surfaces disagreeing.
  static func startFailure(_ reason: DisplayModeCoordinator.StartFailure.Reason) -> LocalizedStringKey {
    switch reason {
    case .failed: startFailure
    case let .blocked(claimant): ReconfigurationCopy.blocked(by: claimant)
    }
  }

  /// The tooltip beside it. Diagnostic rather than part of the statement — the
  /// same split the CoreGraphics error code already had.
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
    "The resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))) is no longer available. \(AppInfo.productName) used \(size(applied)), \(refresh(applied.refreshHz)) instead."
  }

  /// Nothing close enough existed, so nothing was changed. Says so explicitly:
  /// "we left it alone" is information, and its absence reads as a silent
  /// failure of the whole feature.
  static func reapplyUnavailable(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "The resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))) is no longer available, and nothing close enough to use in its place. \(AppInfo.productName) left this display as it found it."
  }

  /// The apply itself failed. Distinct from `reapplyUnavailable` because the
  /// mode still exists — trying again, from the list, is worth doing.
  static func reapplyFailed(requested: DisplayModeDescriptor) -> LocalizedStringKey {
    "\(AppInfo.productName) could not restore the resolution saved for this display (\(size(requested)), \(refresh(requested.refreshHz))). Nothing was changed."
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
