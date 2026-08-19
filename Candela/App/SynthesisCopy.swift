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
/// sentinel because the rate belongs to the display rather than to the stop.
/// While a size is engaged the display runs at the virtual master's achievable
/// rate, which can be lower than what it ran before [MEASURED 2026-08-18:
/// 100 Hz on the wire from a 175 Hz start; the display's own rate returns on
/// disengage]. The cap depends on the master's pixel size, so no sentence may
/// name a figure, and "0 Hz" is a value no display runs at.
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

  /// The rate column of a synthesized row. The stop has no rate of its own, so
  /// the column states what happens to the display's rate rather than naming a
  /// figure that would be this panel's.
  ///
  /// **Ruled back to a promise on 2026-08-18**, after a spell as a cost note
  /// ("May lower the refresh rate while in use"). That sentence was ruled while
  /// the master paced the wire: the mirror left the slave on a timing of the
  /// OS's choosing, measured at 100 Hz from a 175 Hz start. The engage tail now
  /// re-times the slave onto its own mode and CHECKS the achieved state, with
  /// the HDR round trip as the fallback when it cannot, so the display keeps
  /// its own rate. A cost claim that is usually false costs the feature its
  /// adoption; it is also rendered on every OFFERED row, so the wrong sentence
  /// is a caution attached to every stop before anybody chooses one.
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
  /// SS9's sentence read in the other direction, for the panel's HDR button
  /// while a size is engaged. Deliberately the mirror image of `.hdrEngaged`
  /// above: the two refusals guard one pairing from opposite ends, and a person
  /// who has met one should recognise the other.
  ///
  /// A String rather than a `LocalizedStringKey` because the panel's hover
  /// captions take verbatim text.
  static var hdrBlockedBySynthesizedSize: String {
    "Turn off the size \(AppInfo.productName) renders to use HDR."
  }

  static func refusal(_ reason: SynthesisCoordinator.Refusal.Reason) -> LocalizedStringKey {
    switch reason {
    case .builtIn:
      // SS14. Unreachable from the external hub, which is the only surface that
      // renders this today, and stated rather than left to a fallback.
      "\(AppInfo.productName) renders these sizes on external displays only."
    case .hdrEngaged:
      "Turn off HDR to use a synthesized size."
    case .alreadyMirrored:
      // Says what is true of both ends of a set: the reason fires for the
      // display that is showing another one and for the one being shown, and a
      // sentence that picked a side would be wrong half the time. No internal
      // name for the mechanism, and no promise about what happens next.
      "This display is part of a mirror set. Turn mirroring off to use a size \(AppInfo.productName) renders."
    case .notOffered:
      "Turn on More sizes to use a size \(AppInfo.productName) renders."
    case .sizeNoLongerOffered:
      // Never "that size is no longer offered": the ordering that produces this
      // can fire while the size is engaged and visible, and a sentence
      // contradicting the screen is worse than a vague one.
      "\(AppInfo.productName) could not match that size to this display. Pick one from the list of sizes."
    case .restoreSuperseded:
      // Names the outcome and the one move that undoes it. No mechanism: the
      // person did not start the operation that took over and does not need to
      // know which one it was.
      "Another display change took over, so the size \(AppInfo.productName) renders was not put back. Pick it again from the list of sizes."
    case .hdrLeftStanding:
      // The one state this feature can leave behind that only the person can
      // clear, so it names the control rather than describing the mechanism.
      // Brightness and volume go over the data cable, which HDR takes away.
      "\(AppInfo.productName) turned HDR on to renegotiate this display's link and could not turn it off again. Turn HDR off in System Settings: brightness and volume controls cannot reach the display while it is on."
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
      //
      // "usually", and the second route, because quitting is NOT sufficient in
      // the measured exception (S1 5A): while the virtual display is the only
      // ACTIVE display, macOS will not remove it, and it survived both the
      // owning object's release and a SIGKILL of the owner. What clears it is a
      // real display being active again, within about a second. Promising that
      // quitting removes it would be a promise the machine can refuse.
      "\(AppInfo.productName) could not finish taking the last rendered size down. A virtual display may still be in place: quitting \(AppInfo.productName) usually removes it, and if one stays, waking the screen or connecting another display releases it."
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
  /// master's descriptor, and the engaged rate is the master's achievable one
  /// rather than anything chosen here.
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
