import Foundation

/// Every sentence the diagnostics surfaces derive from a value, in one place.
///
/// In Kit rather than in the page because the app target has no test to hold
/// these, and the distinctions below are the whole point of the feature: each is
/// one careless edit from collapsing into a generic sentence, and each is pinned
/// by a test.
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
/// The page and the diagnostics REPORT share one vocabulary: a second set of
/// sentences for the report is a second set to keep true. The report's field
/// values are the page's own words with the page's capitalisation
/// (`readback: Answers reads`), and that casing ruling lives here.
///
/// Returns `String`, never `LocalizedStringKey`, which is why this can live in
/// Kit at all. The page's captions and row labels stay in `DiagnosticsPageCopy`.
///
/// `app` is the product name, passed in rather than read: a second copy of the
/// literal here would break the one-line rename it exists to guarantee.
public enum DiagnosticsCopy {

  // MARK: - Shared vocabulary

  /// A fact nothing has looked for yet. Distinct at every call site from a fact
  /// that was looked for and came back absent.
  public static let notEnumerated = "Not enumerated yet"

  /// A tag the capabilities string does not carry. Not "None": the display's
  /// description simply had no such tag, which is not the display answering
  /// with an empty one.
  public static let notStated = "Not stated"

  // MARK: - Wire-timing guard

  /// The row label when the guard is on and withheld something. Here rather than
  /// in the view so the em-dash and key-name guards cover it; inline in the view
  /// it carried an em dash from the day it shipped, reachable by no test.
  public static let wireTimingWithheldLabel = "Not offered: no matching timing"

  /// The row label when the guard is off. `docs/ADVANCED-SETTINGS.md` quotes
  /// this exact wording, so it is shipped documentation as well as copy.
  public static let wireTimingCheckLabel = "Unsupported-timing check"

  /// Says what WE did and why, never what the display or macOS did. Names no
  /// pref key: `wireTimingGuard` is a `defaults write` escape hatch with no
  /// control in the interface, so naming it tells the user nothing they can
  /// act on and breaks the rule against internal key names in UI copy.
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
  /// `ioregMatchScore`: that score reads 0 both when nothing matched and when
  /// the CoreDisplay dictionary could not be read at all, so any wording for 0
  /// asserts one of two incompatible things. This row wants the real number
  /// or none.
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

  /// Three distinct answers, and the distinction matters: "none
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
    // The wire's two arms name the CAUSE in the value, unlike the pair above:
    // the user did not do this and has no other explanation for it.
    case let .softwareOnly(.gamma, .ddcUnresponsive, dimsBelow):
      "Software only below \(SliderSnap.percentText(dimsBelow)), through the display's color profile: this display stopped answering brightness commands"
    case let .softwareOnly(.overlay, .ddcUnresponsive, dimsBelow):
      "Software only below \(SliderSnap.percentText(dimsBelow)), through a dark overlay: this display stopped answering brightness commands"
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Nothing is moving this display's brightness"
    case .unavailable(.ddcUnresponsiveWithNoSoftwareLeg):
      "Nothing is moving this display's brightness: it stopped answering brightness commands"
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

  /// The four-facts rule applied to capabilities: answered,
  /// answered-but-unreadable, asked-and-unanswered, and never-asked are FOUR
  /// facts and each gets its own sentence. Collapsing any pair lets the page
  /// accuse a display that was never asked, or credit one whose answer we
  /// could not read.
  ///
  /// `parsedACommandList` is false when the description did not parse end to end,
  /// which is a DIFFERENT answer from "the display listed no codes".
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
  /// advertises. Never a claim about what macOS hides, only about
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
  /// `refreshFromHardware` returns before it reads for a display on the native
  /// path or with the brightness command turned off, and the pass may not have
  /// run yet, so the flag is false without anything having asked. "The display
  /// did not report one" there is an absence claim about a probe that never ran.
  ///
  /// A maximum that was READ says so outright, and never wears the "Assumed" the
  /// other two arms carry.
  ///
  /// Takes the brightness controller's OWN evidence, not the folded worst of
  /// three: the maximum comes from the brightness read alone, so a volume read
  /// that answered must not speak for it.
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
  // The typed-and-recorded rule lives here: no value in this group may read
  // just "Unavailable" or "Not supported". Every one of them names the thing that
  // took the feature away, and every reason comes off a typed value rather than
  // being composed at the point of display.

  /// Three answers, because there are three outcomes. `.softwareOnly` is the one
  /// where PART of the slider works, and reporting it as either available or
  /// unavailable would be false in the half that matters.
  public static func brightnessAvailability(_ path: BrightnessPath) -> String {
    switch path {
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Unavailable: combined dimming is off for this display and its hardware brightness command is turned off"
    case .unavailable(.ddcUnresponsiveWithNoSoftwareLeg):
      "Unavailable: this display stopped answering brightness commands, and dimming hands off to software at a point with no software range below it"
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      "Partly available: the hardware brightness command is turned off, so only the part of the slider below \(SliderSnap.percentText(dimsBelow)) moves anything"
    case let .softwareOnly(_, .ddcUnresponsive, dimsBelow):
      "Partly available: this display stopped answering brightness commands, so only the part of the slider below \(SliderSnap.percentText(dimsBelow)) moves anything"
    case .native, .software, .hardware, .combined:
      "Available"
    }
  }

  /// The row the three-distinct-answers rule exists for. `.unknown` is NOT
  /// "unsupported": `.unsupported` is reachable ONLY from a description that
  /// parsed cleanly end to end and did not list the code, so flattening three
  /// states to two greys a working control on a display that merely stayed
  /// silent. The volume-capabilities rule resolves unknown to enabled, and
  /// this says that out loud.
  ///
  /// `support` is nil when nobody has asked yet, which is not `.unknown`: a
  /// stored `.unknown` means the probe ran and the display said nothing usable.
  /// Folding the two put "this display did not answer" against a display that
  /// was never spoken to.
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
      // through because it was unbalanced, carried no top-level `vcp(` tag, or
      // listed no codes. Only the first is silence.
      //
      // In the second the description IS populated, so "this display did not
      // answer" would contradict the same section's "The display answered" three
      // rows away.
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
  ///
  /// The row's help is "VCP 0x8D", so it answers whether the display's own mute
  /// command is the one carrying a mute. That is the STRATEGY IN FORCE, not the
  /// pref: `VolumeSliderPolicy.usesDedicatedMuteCommand` decides it, and both
  /// demotions it applies leave the engine writing the volume register while the
  /// pref still asks for the mute command. Read from the pref alone this row
  /// said "Available" about a command the mute never reached.
  ///
  /// Named apart for the reason the volume row names its two causes apart: a
  /// user told the display refused goes looking at their hardware.
  ///
  /// The prior two answers keep their precedence, so neither may be replaced by
  /// a sentence about where a mute would land.
  ///
  /// The consequence names the LEVEL a degraded mute reaches, never a register
  /// value: it goes out through `rawValue(for: 0)`, so a volume floor sends that
  /// floor and Invert sends the top of the range. "All the way down" is the
  /// claim neither falsifies.
  ///
  /// `muteSupport` is non-optional because the volume-capabilities rule sends
  /// both nil and `.unknown` to the dedicated command; the volume row's
  /// optional exists because the two earn different sentences there.
  public static func muteAvailability(
    muteEnabled: Bool,
    volumeAvailable: Bool,
    forceSoftware: Bool,
    override: AudioSinkOverride,
    muteSupport: VCPSupport
  ) -> String {
    if !muteEnabled {
      return "Unavailable: muting with the display's own mute command is turned off"
    }
    guard volumeAvailable else {
      return commandTurnedOff(command: "volume", forceSoftware: forceSoftware)
    }
    guard !VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: override, muteSupport: muteSupport)
    else {
      // The escape hatch names itself: it is a setting, and a reader who does
      // not know it is on cannot account for what follows. Over a clean denial
      // it is also the one cell that writes 0x8D into a display saying it has
      // none, which is where a mute the app records and no register carries
      // comes from.
      switch override {
      case .forcePresent where muteSupport == .unsupported:
        return "Available: you set this display's volume slider to always on, so muting uses the mute command this display's description does not list"
      case .forcePresent:
        return "Available: you set this display's volume slider to always on"
      case .auto, .forceNone:
        return "Available"
      }
    }
    switch override {
    case .forceNone:
      return "Unavailable: you set this display's volume slider to always off, so muting turns the volume command all the way down instead"
    case .auto:
      return "Unavailable: this display's description parsed cleanly and does not list the mute command, so muting turns the volume command all the way down instead"
    case .forcePresent:
      // Unreachable: the override keeps the dedicated command whatever the
      // display says, so the guard above answered. Stated rather than defaulted
      // so a new case is a compile error here.
      return "Available"
    }
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

  /// `supportsHDR` is false in three different situations: the display lists no
  /// HDR modes, the async capability refresh has not landed, or
  /// MonitorPanel.framework did not load. Blaming the display for the last two
  /// is the same defect as reporting an unasked display as unsupported, so the
  /// sentence names both and says they are indistinguishable from here.
  ///
  /// The DisplayServices check runs FIRST. It is a different framework, the one
  /// carrying native brightness, which is the only path that reaches a display
  /// in HDR mode. Behind the `supportsHDR` guard it could never fire for the case
  /// it describes: a machine with no private frameworks fails that guard first.
  public static func hdrAvailability(
    displayServicesAvailable: Bool, supportsHDR: Bool, app: String
  ) -> String {
    guard displayServicesAvailable else {
      return "Unavailable: macOS did not load the framework \(app) needs for HDR brightness"
    }
    guard supportsHDR else {
      return "Unavailable: \(hdrNoAnswer(app: app)) Either it lists no HDR modes, or macOS did not load the framework \(app) asks. From here the two look the same."
    }
    return "Available"
  }

  /// The claim itself, without the diagnostics row's verdict prefix or its two
  /// causes: the menu-bar panel's greyed HDR button captions itself with this, and a
  /// 280 pt row has no space for the full sentence. Shared rather than restated so
  /// the surface a person meets first cannot drift from the one they meet second.
  public static func hdrNoAnswer(app: String) -> String {
    "\(app) has no HDR answer for this display."
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
  ///
  /// Volume and mute are armed on separate verdicts (separate registers, and a
  /// display can list one and deny the other), so the report names them apart
  /// when only one is watched. Watching both keeps the single phrase, since
  /// splitting the ordinary state makes every report read like a special case.
  public static func watchedKeyFamilies(brightness: Bool, volume: Bool, mute: Bool) -> [String] {
    var families: [String] = []
    if brightness { families.append("brightness") }
    if volume, mute {
      families.append("volume and mute")
    } else if volume {
      families.append("volume")
    } else if mute {
      families.append("mute")
    }
    return families
  }

  /// Reads from the LAST ARMED config, not a freshly computed one. The two
  /// differ exactly when a rearm failed, which is the case this row is for.
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
  ///
  /// **`isSynthesized` outranks the flag, in all three of its states.** A
  /// panel showing a synthesized size IS a mirror slave to CoreGraphics while
  /// showing its own desktop: the pixels come from a virtual display Candela
  /// made for it, so "showing another display's contents" names a display the
  /// user does not have. The caller answers from the engine's pairing table,
  /// which is the authority on synthesis topology.
  public static func mirroring(isMirrorSlave: Bool?, isSynthesized: Bool = false) -> String {
    if isSynthesized { return "Showing a synthesized size" }
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
  /// is macOS's, not ours, so this maps nothing and prettifies nothing: copy
  /// that invents a vocabulary lies the moment the kernel's changes.
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
