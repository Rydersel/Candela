import Foundation

/// Every sentence the diagnostics surfaces derive from a value, in one place.
///
/// Moved here out of `DiagnosticsPage` (#127) without a word changed. The page
/// composed these inline, interleaved with its own layout, where the app target
/// has no test to hold them: "a pane that needs a test has too much in it". The
/// distinctions below are the whole point of the diagnostics feature and several
/// of them are one careless edit away from collapsing into a generic sentence,
/// so each is pinned by `DiagnosticsCopyTests`.
///
/// The three that matter most, all of them defects this feature exists to
/// prevent rather than hypotheticals:
/// - readback has THREE answers, not two: the display answered, it is not
///   answering, or it answered something that could not be read;
/// - a brightness maximum that was READ from the display never reads like one
///   that was assumed;
/// - volume unavailable because the DISPLAY denied it is a different sentence
///   from volume unavailable because a SETTING turned it off.
///
/// It also carries the strings the page and the diagnostics REPORT share. One
/// vocabulary on purpose: the page and the report describe the same facts, and a
/// second set of sentences for the report is a second set to keep true. The
/// report's field values are therefore the page's own words, capitalised the way
/// the page capitalises them: `readback: Answers reads`, not `readback: answers
/// reads`. That is the casing ruling this file owns.
///
/// Returns `String`, never `LocalizedStringKey`, which is why this can live in
/// Kit at all (CandelaKit imports no SwiftUI). The page's captions and row
/// labels stay in `DiagnosticsPageCopy` in the app target for exactly that
/// reason.
///
/// `app` is the product name, passed in rather than read: `AppInfo.productName`
/// is provisional and lives in the app target, and a second copy of the literal
/// here would break the one-line rename it exists to guarantee.
public enum DiagnosticsCopy {

  // MARK: - Shared vocabulary

  /// A fact nothing has looked for yet. Distinct at every call site from a fact
  /// that was looked for and came back absent, which is the whole of DT30 rule
  /// (e) in three words.
  public static let notEnumerated = "Not enumerated yet"

  /// A tag the capabilities string does not carry. Not "None": the display's
  /// description simply had no such tag, which is not the display answering
  /// with an empty one.
  public static let notStated = "Not stated"

  // MARK: - Wire-timing guard (#110)

  /// The row label when the guard is on and withheld something. Here rather
  /// than in the view so the em-dash and key-name guards below cover it: it
  /// carried an em dash from the day it shipped until #129, precisely because
  /// a label sitting inline in a 1159-line view was reachable by no test.
  public static let wireTimingWithheldLabel = "Not offered: no matching timing"

  /// The row label when the guard is off. `docs/ADVANCED-SETTINGS.md` quotes
  /// this exact wording, so it is shipped documentation as well as copy.
  public static let wireTimingCheckLabel = "Unsupported-timing check"

  /// Says what WE did and why, never what the display or macOS did (DT30 rule
  /// (d)). Names no pref key: `wireTimingGuard` is a `defaults write` escape
  /// hatch with no control in the interface (D26), so naming it in a tooltip
  /// told the user nothing they could act on and broke D25.
  public static let wireTimingGuardOff = """
    Turned off by an advanced setting. Resolutions the display has no matching \
    timing for are offered again, and some displays scan those out letterboxed \
    or cropped.
    """

  /// The tooltip on the withheld-count row. Describes the display's behaviour,
  /// which is why it is phrased about displays rather than about the guard.
  public static let wireTimingWithheld = """
    These resolutions run at refresh rates this display advertises no \
    full-width timing for. Displays bind them to a different timing \
    instead, which can letterbox or crop the desktop.
    """

  // MARK: - Verdict

  /// The most actionable true sentence, in the order a person would want to
  /// hear them. It claims nothing the rows below it do not: the failure flag,
  /// the presence of a target and the worst-of-three read evidence are the same
  /// three values "Last brightness command" and "Reading values back" render.
  public static func verdict(
    isBuiltIn: Bool,
    path: BrightnessPath,
    lastApplyFailed: Bool,
    hasAppliedTarget: Bool,
    evidence: DDCReadEvidence,
    app: String
  ) -> String {
    if isBuiltIn {
      return "macOS controls this display's brightness directly, so there is nothing for \(app) to send over a cable."
    }
    if case .unavailable = path {
      return "Nothing is moving this display's brightness. See Availability below."
    }
    if lastApplyFailed {
      return "The last brightness command was not accepted. Try a different cable or port."
    }
    guard hasAppliedTarget else {
      return "\(app) has not sent anything to this display yet."
    }
    return switch evidence {
    case .answered, .notAttempted:
      "Brightness is being sent to this display and accepted."
    case .allZeros:
      "Brightness is being sent to this display and accepted, but it never answers a read."
    case .noReply:
      "Brightness is being sent to this display and accepted, but it is not answering reads."
    }
  }

  // MARK: - This display

  /// "Not enumerated yet" and "reported nothing" are different facts, and the
  /// report's `connection:` field only distinguishes present from absent, so the
  /// page keeps the distinction that `transport(_:)` collapses to nil.
  public static func connection(_ facts: DisplayHardwareFacts?) -> String {
    if let transport = transport(facts) { return transport }
    return facts == nil ? notEnumerated : "This display does not report its connection type"
  }

  public static func manufacturer(_ facts: DisplayHardwareFacts?) -> String {
    guard let facts else { return notEnumerated }
    return facts.manufacturerID ?? "Not reported"
  }

  public static func serial(_ facts: DisplayHardwareFacts?) -> String {
    guard let facts else { return notEnumerated }
    if let alphanumeric = facts.alphanumericSerialNumber { return alphanumeric }
    if let numeric = facts.numericSerialNumber { return String(numeric) }
    return "Not reported"
  }

  /// The identity-keys tooltip. Carries the IOReg PATH and deliberately not
  /// `ioregMatchScore`: that score is a non-optional `Int` reading 0 both when
  /// nothing matched and when the CoreDisplay dictionary could not be read at
  /// all, so any wording for 0 asserts one of two incompatible things; and its
  /// documented "0…20" ceiling is wrong (the real maximum is 16). A number that
  /// cannot be worded honestly is not a number to put in front of a user, and
  /// DT30 rule (g) wants the real one or none.
  public static func ioregPath(_ facts: DisplayHardwareFacts?) -> String {
    guard let facts else { return "The system port path for this display has not been read yet." }
    guard let location = facts.ioDisplayLocation else {
      return "This display reports no system port path."
    }
    return "System port path: \(location)"
  }

  public static func displaySize(widthCm: Int, heightCm: Int) -> String {
    "\(widthCm) × \(heightCm) cm"
  }

  /// The second identity key, which is absent until the mode catalog is built.
  public static func displayKey(_ key: String?) -> String {
    key ?? notEnumerated
  }

  /// Three distinct answers, and the distinction matters (DT30 rule (e)): "none
  /// on this display" is a measurement, "not available" is a missing capability,
  /// and conflating them would report a capability gap as a fact about the
  /// display.
  public static func additionalResolutions(revealed: Int, revealsHiddenModes: Bool) -> String {
    guard revealsHiddenModes else {
      return "Not available on this version of macOS"
    }
    return revealed == 0 ? "None for this display" : "\(revealed)"
  }

  // MARK: - Brightness control

  /// The engine's own answer, put into the user's words. `BrightnessPath` gained
  /// a `.softwareOnly` case after the diagnostics rows were specified, and it is
  /// the one case where PART of the slider works, so it gets its own sentence
  /// rather than being folded in with plain software dimming, which would
  /// overstate what moves.
  public static func brightnessPath(_ path: BrightnessPath) -> String {
    switch path {
    case .native:
      "macOS native brightness"
    case .hardware:
      "Hardware commands over the data cable"
    case .software(.gamma):
      "Software, through the display's color profile"
    case .software(.overlay):
      "Software, through a dark overlay"
    case let .combined(switching, .gamma):
      "Split at \(SliderSnap.percentText(switching)): software below, the data cable above"
    case let .combined(switching, .overlay):
      "Split at \(SliderSnap.percentText(switching)): overlay below, the data cable above"
    case let .softwareOnly(.gamma, .ddcTurnedOff, dimsBelow):
      "Software only below \(SliderSnap.percentText(dimsBelow)), through the display's color profile"
    case let .softwareOnly(.overlay, .ddcTurnedOff, dimsBelow):
      "Software only below \(SliderSnap.percentText(dimsBelow)), through a dark overlay"
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Nothing is moving this display's brightness"
    }
  }

  public static func nativeBrightness(isAvailable: Bool, app: String) -> String {
    isAvailable
      ? "Available on this Mac"
      : "Unavailable: macOS did not load the framework \(app) needs for it"
  }

  /// The built-in's whole DDC story, stated once. It is not a failure, a
  /// preference, or something a future release fixes, so it is not phrased as
  /// any of those.
  public static let builtInHardwareControl =
    "Does not apply: this display has no data cable to carry hardware commands"

  public static func gammaConflicts(_ count: Int) -> String {
    count == 0
      ? "None noticed"
      : "\(count): another app keeps taking this display's color profile back"
  }

  // MARK: - Reported capabilities

  /// SO5 applied to capabilities: answered, answered-but-unreadable,
  /// asked-and-unanswered, and never-asked are FOUR facts and each gets its own
  /// sentence. The probe not having run is not the same fact as the display
  /// having stayed silent, and a display whose description arrived but would not
  /// parse is not the same fact as either. Collapsing any pair lets the page
  /// accuse a display that was never asked, or credit one whose answer we could
  /// not read.
  ///
  /// `parsedACommandList` is false when the description did not parse end to end
  /// (D24), which is a DIFFERENT answer from "the display listed no codes".
  public static func capabilityAnswer(
    hasDescription: Bool,
    parsedACommandList: Bool,
    wasAsked: Bool,
    app: String
  ) -> String {
    if hasDescription {
      return parsedACommandList
        ? "The display answered"
        : "The display answered, but \(app) could not read its description"
    }
    if wasAsked {
      return "\(app) asked and the display sent nothing it could read"
    }
    return "Not asked yet"
  }

  /// The four commands this app speaks, and which of them this display
  /// advertises. Never a claim about what macOS hides (DT30 rule d), only about
  /// what the display itself listed. nil codes means the description did not
  /// parse, which is not an empty list.
  public static func advertisedCommands(_ codes: Set<UInt8>?, app: String) -> String {
    guard let codes else {
      return "The description did not parse, so \(app) makes no claim about it"
    }
    let spoken: [(UInt8, String)] = [
      (VCP.brightness, "brightness"),
      (VCP.contrast, "contrast"),
      (VCP.audioSpeakerVolume, "volume"),
      (VCP.audioMuteScreenBlank, "mute"),
    ]
    let listed = spoken.filter { codes.contains($0.0) }.map(\.1)
    if listed.isEmpty {
      return "None of the four \(app) uses, out of \(codes.count) listed"
    }
    return listed.joined(separator: ", ") + " (of \(codes.count) commands listed)"
  }

  /// The write-only display is NAMED. It is a real and permanent property of
  /// some hardware, it explains every other value on the page, and a user who
  /// has it needs the words to search for.
  ///
  /// THREE outcomes past "not asked", and none of them may be folded together:
  /// answering, never answering, and not replying are three different faults
  /// with three different next steps.
  public static func readEvidence(_ evidence: DDCReadEvidence, app: String) -> String {
    switch evidence {
    case .notAttempted: "\(app) has not read from this display"
    case .answered: "This display answers reads"
    case .allZeros: "Write-only: this display takes commands but never answers a read"
    case .noReply: "This display did not reply to a read"
    }
  }

  /// The SHORT verdict: the hub's chevron preview and the report's `readback:`
  /// field. `readEvidence(_:app:)` says the same thing at length; both come off
  /// the same worst-of-three evidence, so they cannot disagree.
  public static func readbackVerdict(_ evidence: DDCReadEvidence) -> String {
    switch evidence {
    case .notAttempted: "Not asked yet"
    case .answered: "Answers reads"
    case .allZeros: "Write-only"
    case .noReply: "Not answering"
    }
  }

  /// Three answers, because `didReadMax` being false is not one fact.
  /// `BrightnessController.refreshFromHardware` returns before it reads for a
  /// display on the native path or with the brightness command turned off, and
  /// the pass may simply not have run yet: in all of those it leaves the flag
  /// false without ever having asked. "The display did not report one" there is
  /// an absence claim about a probe that never ran, and it renders directly
  /// above the same section's "has not read from this display".
  ///
  /// A maximum that was READ says so outright, and never wears the word
  /// "Assumed" that the other two arms carry.
  ///
  /// Takes the brightness controller's OWN evidence, not the folded worst of
  /// three: the maximum comes from the brightness read alone, so a volume read
  /// that answered must not be allowed to speak for it.
  public static func brightnessScale(
    didReadMax: Bool, maxValue: UInt16, evidence: DDCReadEvidence, app: String
  ) -> String {
    if didReadMax {
      return "This display reported a maximum of \(maxValue)"
    }
    if evidence == .notAttempted {
      return "Assumed 100: \(app) has not asked this display for its scale"
    }
    return "Assumed 100: the display did not report one"
  }

  // MARK: - Availability
  //
  // DT30 rule (a) lives here: no value in this group may read just
  // "Unavailable" or "Not supported". Every one of them names the thing that
  // took the feature away, and every reason comes off a typed value rather than
  // being composed at the point of display.

  /// Three answers, because there are three outcomes. `.softwareOnly` is the one
  /// where PART of the slider works, and reporting it as either available or
  /// unavailable would be false in the half that matters.
  public static func brightnessAvailability(_ path: BrightnessPath) -> String {
    switch path {
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Unavailable: combined dimming is off for this display and its hardware brightness command is turned off"
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      "Partly available: the hardware brightness command is turned off, so only the part of the slider below \(SliderSnap.percentText(dimsBelow)) moves anything"
    case .native, .software, .hardware, .combined:
      "Available"
    }
  }

  /// DT30 rule (b), the row that rule exists for. `.unknown` is NOT
  /// "unsupported": `.unsupported` is reachable ONLY from a description that
  /// parsed cleanly end to end and did not list the code. A page that flattened
  /// three states to two would grey a working control on a display that merely
  /// stayed silent. D24's doctrine is that unknown resolves to enabled, and this
  /// is that doctrine said out loud.
  ///
  /// `support` is nil when nobody has asked yet, which is not `.unknown`: a
  /// stored `.unknown` means the probe ran and the display said nothing usable.
  /// Folding the two put "this display did not answer" against a display that
  /// was never spoken to, one row away from the row that states the difference.
  public static func volumeAvailability(
    override: AudioSinkOverride,
    isAvailable: Bool,
    support: VCPSupport?,
    hasDescription: Bool,
    forceSoftware: Bool,
    app: String
  ) -> String {
    switch override {
    case .forceNone:
      return "Unavailable: you set this display's volume slider to always off"
    case .forcePresent:
      return "Available: you set this display's volume slider to always on"
    case .auto:
      break
    }
    if !isAvailable { return commandTurnedOff(command: "volume", forceSoftware: forceSoftware) }
    guard let support else {
      return "Available: \(app) has not asked this display yet, so the control stays on"
    }
    switch support {
    case .supported:
      return "Available: this display lists the volume command"
    case .unsupported:
      return "Unavailable: this display's description parsed cleanly and does not list the volume command"
    case .unknown:
      // A stored `.unknown` has TWO producers: the capability read came back
      // nil, OR a string arrived and `CapabilityString.support(forVCP:in:)` fell
      // through to `.unknown` because it was unbalanced, carried no top-level
      // `vcp(` tag, or listed no codes. Only the first is silence.
      //
      // In the second, the description IS populated, and saying "this display
      // did not answer" there contradicts, three rows apart, the same section's
      // "The display answered", its verbatim copy of what the display sent, and
      // "The description did not parse, so … makes no claim about it"
      // (`codes(in:)` fails on exactly the same three gates, in the same order).
      return hasDescription
        ? "Available: \(app) could not read a command list out of this display's description, so the control stays on"
        : "Available: this display sent no answer \(app) could read, so the control stays on"
    }
  }

  public static func contrastAvailability(isAvailable: Bool, forceSoftware: Bool) -> String {
    isAvailable ? "Available" : commandTurnedOff(command: "contrast", forceSoftware: forceSoftware)
  }

  /// The SETTING that turns muting off is a different sentence from the DISPLAY
  /// denying the volume command, and this row is the one place both can reach.
  public static func muteAvailability(
    muteEnabled: Bool, volumeAvailable: Bool, forceSoftware: Bool
  ) -> String {
    if !muteEnabled {
      return "Unavailable: muting with the display's own mute command is turned off"
    }
    return volumeAvailable
      ? "Available"
      : commandTurnedOff(command: "volume", forceSoftware: forceSoftware)
  }

  /// `DDCValueController.isAvailable` is `!unavailableDDC && !forceSoftware`,
  /// and the two settings behind it are DIFFERENT things a user can act on
  /// differently: one is this command, the other is every command on this
  /// display. Naming them apart is the difference between a row that explains
  /// and a row that shrugs.
  public static func commandTurnedOff(command: String, forceSoftware: Bool) -> String {
    if forceSoftware {
      return "Unavailable: hardware control is turned off for this display"
    }
    return "Unavailable: the \(command) command is turned off for this display"
  }

  /// `supportsHDR` is false in three different situations: the display really
  /// lists no HDR modes, the async capability refresh has not landed yet, and
  /// MonitorPanel.framework did not load at all. Blaming the display for the
  /// last two is the same defect as reporting an unasked display as unsupported,
  /// so the sentence names both possibilities and says they are indistinguishable
  /// from here.
  ///
  /// The DisplayServices check runs FIRST. It is a different framework, the one
  /// that carries native brightness, which is the only path that reaches a
  /// display in HDR mode, and it is knowable regardless of what MonitorPanel
  /// answered. Behind the `supportsHDR` guard it could never fire for the case it
  /// describes, because a machine with no private frameworks at all fails the
  /// guard first.
  public static func hdrAvailability(
    displayServicesAvailable: Bool, supportsHDR: Bool, app: String
  ) -> String {
    guard displayServicesAvailable else {
      return "Unavailable: macOS did not load the framework \(app) needs for HDR brightness"
    }
    guard supportsHDR else {
      return "Unavailable: \(app) has no HDR answer for this display. Either it lists no HDR modes, or macOS did not load the framework \(app) asks. From here the two look the same."
    }
    return "Available"
  }

  // MARK: - Right now
  //
  // State, not settings. Everything here can be different a second from now, and
  // every one of them has words: nothing in this group is carried by a colour or
  // an icon alone.

  public static func hdrState(engaged: Bool) -> String {
    engaged ? "Engaged" : "Off"
  }

  /// The epoch gate stops every submit, native and DDC alike.
  public static func writeGate(isSending: Bool) -> String {
    isSending ? "Being sent" : "Paused while displays are changing or asleep"
  }

  public static let safeModeState = "On for this session"

  /// Split out so a row can tell "watching nothing" from "not running" without
  /// recomputing the words.
  public static func watchedKeyFamilies(brightness: Bool, volumeOrMute: Bool) -> [String] {
    var families: [String] = []
    if brightness { families.append("brightness") }
    if volumeOrMute { families.append("volume and mute") }
    return families
  }

  /// Reads from the LAST ARMED config, not a freshly computed one. The two
  /// differ exactly when a rearm failed, which is the case this row is for (B9).
  public static func watchedKeys(families: [String], tapRunning: Bool) -> String {
    guard tapRunning else {
      return "None: the media-key tap is not running"
    }
    return families.isEmpty
      ? "None: every media key is going straight to macOS"
      : families.joined(separator: ", ")
  }

  public static let noDefaultOutputDevice = "macOS reports no default output device"

  public static func audioMatch(deviceName: String, matches: Bool) -> String {
    matches
      ? "\(deviceName): matched to this display"
      : "\(deviceName): not matched to this display"
  }

  public static func lastWrite(target: HardwareTarget?, failed: Bool) -> String {
    guard let target else {
      return failed
        ? "The last command was not accepted"
        : "Nothing has been sent to this display yet"
    }
    let value: String = switch target {
    case let .ddc(raw): "value \(raw) over the data cable"
    case let .native(level): "\(SliderSnap.percentText(Double(level))) through macOS"
    }
    return failed
      ? "Last accepted: \(value). The most recent command was not accepted."
      : "Accepted: \(value)"
  }

  /// `CGDisplayMirrorsDisplay` names the display whose contents this one is
  /// SHOWING. It is not a membership test (a mirror MASTER reports null, and so
  /// does a standalone display), so this claims only what that call can support.
  /// nil is the display not having been enumerated yet.
  public static func mirroring(isMirrorSlave: Bool?) -> String {
    guard let isMirrorSlave else { return notEnumerated }
    return isMirrorSlave
      ? "Showing another display's contents"
      : "Showing its own contents"
  }

  // MARK: - Modes

  public static func mode(_ mode: DisplayMode) -> String {
    "\(mode.logicalWidth) × \(mode.logicalHeight) at \(Int(mode.refreshHz.rounded())) Hz"
  }

  /// The page's row. Longer than `reapplyEvent`, which is a ring entry.
  public static func reapplyProblem(_ notice: ModeReapplyNotice, app: String) -> String {
    switch notice {
    case let .substituted(applied):
      "\(app) could not restore your saved resolution and used \(mode(applied)) instead"
    case .unavailable:
      "Your saved resolution is not offered by this display right now"
    case .failed:
      "Restoring your saved resolution failed"
    }
  }

  /// One line for the diagnostics event ring. Terser than the page's row: the
  /// ring is a sequence and reads as one.
  public static func reapplyEvent(_ notice: ModeReapplyNotice) -> String {
    switch notice {
    case let .substituted(applied):
      "saved resolution unavailable, used \(mode(applied))"
    case .unavailable:
      "saved resolution not offered"
    case .failed:
      "restoring the saved resolution failed"
    }
  }

  /// Rendered as the kernel spelled it. The `Transport` dictionary's vocabulary
  /// is macOS's, not ours, and no real display's spelling has been observed, so
  /// this maps nothing and prettifies nothing. Copy that invents a vocabulary
  /// lies the moment the kernel's changes.
  ///
  /// nil covers BOTH "not enumerated yet" and "reported nothing". The page
  /// distinguishes them through `connection(_:)`; the report's field cannot, so
  /// it says `not reported` for either, which is true of both.
  public static func transport(_ facts: DisplayHardwareFacts?) -> String? {
    guard let facts else { return nil }
    switch (facts.transportUpstream, facts.transportDownstream) {
    case let (up?, down?) where up == down: return up
    case let (up?, down?): return "\(up) → \(down)"
    case let (up?, nil): return up
    case let (nil, down?): return down
    case (nil, nil): return nil
    }
  }
}
