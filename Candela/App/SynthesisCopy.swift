import CandelaKit
import SwiftUI

/// Every user-visible word about synthesized sizes: the opt-in
/// row, the badge and rate column on a synthesized row, the refusal sentences,
/// and the two diagnostics lines.
///
/// Three constraints bind everything here.
///
/// No sharpness claim, ever (the camera gate measured supersampling
/// reading SOFTER on standard-PPI glass). This feature sells size granularity:
/// "more sizes", never "sharper", "full resolution" or "Retina".
///
/// No refresh rate is ever named. A synthesized row carries the `refreshHz: 0`
/// sentinel because the rate belongs to the display rather than to the stop,
/// and while a size is engaged the display runs at the virtual master's
/// achievable rate [MEASURED 2026-08-18: 100 Hz from a 175 Hz start, the
/// display's own rate returning on disengage]. The cap depends on the master's
/// pixel size, so no sentence may name a figure.
///
/// No refusal claims a size has been withdrawn. `sizeNoLongerOffered` is
/// reachable while the size is visibly on the glass, so it states what the app
/// could not do rather than what the display no longer offers.
enum SynthesisCopy {
  // MARK: - The opt-in row

  /// "More sizes" is the whole promise: options between the ones the display
  /// reports, with no claim about how any of them look.
  static var optInTitle: String { "More sizes" }

  /// The mechanism is named because it is visible: a virtual display appears in
  /// System Settings while a size is engaged, and a person who finds it there
  /// unexplained has found a bug rather than a feature.
  static var optInCaption: String {
    "Adds in-between scaled sizes rendered through a virtual display. The picture may use more memory while one is active."
  }

  // MARK: - Synthesized rows

  /// The mark on a row this app renders rather than one the display offers.
  ///
  /// NOT `DisplayModeCopy.addedByApp` ("Added by Candela"), which marks a mode
  /// our own enumeration FOUND on the display. The two differ in what they cost
  /// and in what happens when the app quits, so the marks stay distinguishable.
  static var badge: String { "Rendered by \(AppInfo.productName)" }

  /// The rate column of a synthesized row. The stop has no rate of its own, so
  /// the column states what happens to the display's rate rather than naming a
  /// figure that would be this panel's.
  ///
  /// A promise, not the cost note it once was: the engage tail re-times the
  /// slave onto its own mode and CHECKS the achieved state, with the HDR round
  /// trip as the fallback, so the display keeps its rate. This renders on every
  /// OFFERED row, so a cost claim that is usually false is a caution attached
  /// to every stop before anybody chooses one.
  ///
  /// "display", not "panel": that word was retired from visible copy while
  /// leaving it in the type and comment vocabulary.
  static var keepsPanelRefresh: String { "Keeps the display's refresh rate" }

  /// The All list enumerates what the display reports, so while a synthesized
  /// size is engaged the row the checkmark would sit on is absent. Said out
  /// loud rather than left as a list with nothing ticked.
  static var engagedSizeNotListed: String {
    "The size in use is one \(AppInfo.productName) renders, so this list does not hold it. It is in the Recommended list."
  }

  // MARK: - Refusals

  /// The HDR-engaged guard's sentence read in the other direction, for the panel's HDR button
  /// while a size is engaged. The mirror image of `refusal`'s `.hdrEngaged`:
  /// the two guard one pairing from opposite ends, and a person who has met one
  /// should recognise the other.
  ///
  /// A String rather than a `LocalizedStringKey` because the panel's hover
  /// captions take verbatim text.
  static var hdrBlockedBySynthesizedSize: String {
    "Turn off the size \(AppInfo.productName) renders to use HDR."
  }

  /// Why a synthesized size did not engage. No `default:` arm: a new reason is
  /// a compile error here rather than a silent generic sentence.
  static func refusal(_ reason: SynthesisCoordinator.Refusal.Reason) -> LocalizedStringKey {
    switch reason {
    case .builtIn:
      // Unreachable from the external hub, but stated rather than left
      // to a fallback.
      "\(AppInfo.productName) renders these sizes on external displays only."
    case .hdrEngaged:
      "Turn off HDR to use a synthesized size."
    case .alreadyMirrored:
      // True of both ends of a set: the reason fires for the display showing
      // another one and for the one being shown, so a sentence that picked a
      // side would be wrong half the time.
      "This display is part of a mirror set. Turn mirroring off to use a size \(AppInfo.productName) renders."
    case .notOffered:
      "Turn on More sizes to use a size \(AppInfo.productName) renders."
    case .sizeNoLongerOffered:
      // Never "that size is no longer offered": this can fire while the size is
      // engaged and visible, and a sentence contradicting the screen is worse
      // than a vague one.
      "\(AppInfo.productName) could not match that size to this display. Pick one from the list of sizes."
    case .restoreSuperseded:
      // Names the outcome and the one move that undoes it. No mechanism: the
      // person did not start the operation that took over.
      "Another display change took over, so the size \(AppInfo.productName) renders was not put back. Pick it again from the list of sizes."
    case .hdrLeftStanding:
      // The one state this feature can leave behind that only the person can
      // clear, so it names the control. Brightness and volume go over the data
      // cable, which HDR takes away.
      "\(AppInfo.productName) turned HDR on to renegotiate this display's link and could not turn it off again. Turn HDR off in System Settings: brightness and volume controls cannot reach the display while it is on."
    case .busy:
      "\(AppInfo.productName) is still finishing the last display change. Try again in a moment."
    case let .blocked(claimant):
      // The one sentence every reconfiguration-gate claimant says, from the one place it lives.
      ReconfigurationCopy.blocked(by: claimant)
    case let .engine(failure):
      engineFailure(failure)
    }
  }

  /// The sequence failed, and each sentence names the step. All of them are
  /// direction-neutral: the same failures arrive from an engage, a teardown and
  /// an opt-out.
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
      // The one case where saying nothing would leave a virtual display
      // standing with no account of it anywhere a person can read.
      //
      // "usually", and the second route, because quitting is NOT sufficient in
      // the measured exception: while the virtual display is the only
      // ACTIVE display macOS will not remove it, and it survived both the
      // owning object's release and a SIGKILL. A real display being active
      // again clears it within about a second.
      "\(AppInfo.productName) could not finish taking the last rendered size down. A virtual display may still be in place: quitting \(AppInfo.productName) usually removes it, and if one stays, waking the screen or connecting another display releases it."
    }
  }

  // MARK: - Diagnostics

  /// The engaged pairing as one report line: the size on the glass and the slot
  /// its virtual display holds. The slot is what distinguishes two engaged
  /// displays in a pasted report.
  ///
  /// Through `DisplayModeCopy.size` so the times sign has ONE spelling: a size
  /// spelled differently from the picker does not match itself under a search.
  static func diagnosticsActive(width: Int, height: Int, slot: Int) -> String {
    "Synthesized size active: \(DisplayModeCopy.size(width: width, height: height)) (virtual display slot \(slot))"
  }

  /// The pasted report's mode line while a stop is engaged. Its own sentence
  /// because a report line is already labelled ("current mode: ...") and would
  /// otherwise read as two labels stacked. It names NO rate: the engaged rate is
  /// the virtual master's achievable one rather than anything chosen here.
  static func reportMode(width: Int, height: Int, slot: Int) -> String {
    "\(DisplayModeCopy.size(width: width, height: height)) (synthesized, virtual display slot \(slot))"
  }

  /// How many stops the ladder offers this display. Shown only where the opt-in
  /// is on: a zero under an opt-in that is off reads as a feature that found
  /// nothing rather than one nobody asked for.
  static func diagnosticsOffered(_ count: Int) -> String {
    "Synthesized sizes offered: \(count)"
  }
}
