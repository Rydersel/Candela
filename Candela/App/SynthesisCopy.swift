import CandelaKit
import SwiftUI

/// Every user-visible word about synthesized sizes (SS4/SS5/SS9): the opt-in
/// row, the badge and rate column on a synthesized row, the refusal sentences,
/// and the two diagnostics lines.
///
/// One enum for the same reason `DisplayModeCopy` is one enum: these sentences
/// are shown by more than one surface, and a rule enforced in four private
/// helpers is a rule that drifts the first time one of them is edited.
///
/// **Three constraints bind everything here.**
///
/// No sharpness claim, ever (RM11, and the camera gate of 2026-08-07 measured
/// supersampling reading SOFTER on standard-PPI glass). This feature sells size
/// granularity: "more sizes", never "sharper", "full resolution" or "Retina".
///
/// No refresh rate is ever named. A synthesized row carries the `refreshHz: 0`
/// sentinel because the rate belongs to the display rather than to the stop,
/// and the mirror preserves whatever the display was already running [MEASURED
/// 2026-08-17 at 100 Hz: 100 before, during and after]. 175 Hz specifically is a
/// prediction and not a measurement, so no sentence may name a figure, and
/// "0 Hz" is a value no display runs at.
///
/// No refusal claims a size has been withdrawn. `sizeNoLongerOffered` is
/// reachable while the size is visibly on the glass, so it states what the app
/// could not do rather than what the display no longer offers.
enum SynthesisCopy {
  // MARK: - The opt-in row (SS4)

  /// The row's title. "More sizes" is the whole promise: the feature adds
  /// options between the ones the display reports, and says nothing about how
  /// any of them look.
  static var optInTitle: String { "More sizes" }

  /// What turning it on gets you and what it costs, in one sentence each. The
  /// mechanism is named because it is visible: a virtual display appears in
  /// System Settings while a size is engaged, and a person who finds it there
  /// with no explanation has found a bug rather than a feature.
  static var optInCaption: String {
    "Adds in-between scaled sizes rendered through a virtual display. The picture may use more memory while one is active."
  }

  // MARK: - Synthesized rows (SS5)

  /// The mark on a row this app renders rather than one the display offers.
  ///
  /// Deliberately NOT `DisplayModeCopy.addedByApp` ("Added by Candela"), which
  /// marks a mode our own enumeration FOUND on the display. The two mechanisms
  /// differ in what they cost and in what happens when the app quits, so the
  /// two marks stay distinguishable (SS5).
  static var badge: String { "Rendered by \(AppInfo.productName)" }

  /// The rate column of a synthesized row. The stop has no rate of its own:
  /// what scans out is whatever the display was already running.
  ///
  /// "display", not "panel". SO14 retired that word from visible copy while
  /// leaving it in the type and comment vocabulary, which is exactly the split
  /// this property's own name sits on the other side of.
  static var keepsPanelRefresh: String { "Keeps the display's refresh rate" }

  /// The All list enumerates what the display reports, and a synthesized size
  /// is not in it, so the row the checkmark would sit on is absent while a size
  /// is engaged. Said out loud rather than left as a list with nothing ticked.
  static var engagedSizeNotListed: String {
    "The size in use is one \(AppInfo.productName) renders, so this list does not hold it. It is in the Recommended list."
  }

  // MARK: - Refusals (SS9, SS14)

  /// Why a synthesized size did not engage. No `default:` arm anywhere below: a
  /// new reason is a compile error here rather than a silent generic sentence.
  static func refusal(_ reason: SynthesisCoordinator.Refusal.Reason) -> LocalizedStringKey {
    switch reason {
    case .builtIn:
      // SS14. Unreachable from the external hub, which is the only surface that
      // renders this today, and stated rather than left to a fallback.
      "\(AppInfo.productName) renders these sizes on external displays only."
    case .hdrEngaged:
      "Turn off HDR to use a synthesized size."
    case .notOffered:
      "Turn on More sizes to use a size \(AppInfo.productName) renders."
    case .sizeNoLongerOffered:
      // Never "that size is no longer offered": the ordering that produces this
      // can fire while the size is engaged and visible, and a sentence
      // contradicting the screen is worse than a vague one.
      "\(AppInfo.productName) could not match that size to this display. Pick one from the list of sizes."
    case .busy:
      "\(AppInfo.productName) is still finishing the last display change. Try again in a moment."
    case let .blocked(claimant):
      // The one sentence every AR12 claimant says, from the one place it lives.
      ReconfigurationCopy.blocked(by: claimant)
    case let .engine(failure):
      engineFailure(failure)
    }
  }

  /// The sequence failed, and each sentence names the step rather than saying
  /// "it did not work". Every one of them is direction-neutral: the same
  /// failures arrive from an engage, from a teardown and from an opt-out, and
  /// a sentence that assumed one of the three would be wrong in the other two.
  static func engineFailure(_ failure: SynthesisFailure) -> LocalizedStringKey {
    switch failure {
    case .unavailable:
      "Virtual displays are unavailable on this version of macOS, and these sizes are rendered through one."
    case .noFreeSlot:
      "\(AppInfo.productName) can render a size on two displays at once, and both are in use."
    case .createFailed:
      "macOS did not create the virtual display this size needs. Nothing was changed."
    case .virtualModeNotAchieved:
      // Never "at the sharpness it needs": the claim is about geometry.
      "The virtual display did not come up at the size that was asked for, so nothing was changed."
    case .mirrorRefused:
      "macOS refused to show this display through the virtual display, so nothing was changed."
    case .engageNotAchieved:
      "This display did not take the new size, so it was put back."
    case .notEngaged:
      "No size \(AppInfo.productName) renders is in use on this display."
    case .unwindIncomplete:
      // The loudest answer in the enum, and the one case where saying nothing
      // would leave a virtual display standing with no account of it anywhere a
      // person can read.
      "\(AppInfo.productName) could not finish taking the last rendered size down. A virtual display may still be in place; quitting \(AppInfo.productName) removes it."
    }
  }

  // MARK: - Diagnostics

  /// The engaged pairing, as one report line: the size on the glass and the
  /// slot its virtual display holds. The slot is what distinguishes two engaged
  /// displays from each other in a pasted report.
  ///
  /// The size goes through `DisplayModeCopy.size`, which exists so the times
  /// sign has ONE spelling: a report line naming a size with a different
  /// character from the picker it was chosen in is a size that does not match
  /// itself under a search.
  static func diagnosticsActive(width: Int, height: Int, slot: Int) -> String {
    "Synthesized size active: \(DisplayModeCopy.size(width: width, height: height)) (virtual display slot \(slot))"
  }

  /// The pasted report's mode line while a stop is engaged.
  ///
  /// Its own sentence rather than the page's line above, because a report line
  /// is already labelled ("current mode: ...") and would otherwise read as two
  /// labels stacked. It names NO rate: the readback it replaces is the virtual
  /// master's descriptor, and the display's own rate is preserved by the mirror
  /// rather than chosen here.
  static func reportMode(width: Int, height: Int, slot: Int) -> String {
    "\(DisplayModeCopy.size(width: width, height: height)) (synthesized, virtual display slot \(slot))"
  }

  /// How many stops the ladder offers this display. Shown only where the opt-in
  /// is on: a zero under an opt-in that is off would read as a feature that
  /// found nothing rather than one nobody asked for.
  static func diagnosticsOffered(_ count: Int) -> String {
    "Synthesized sizes offered: \(count)"
  }
}
