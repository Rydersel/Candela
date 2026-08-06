import CandelaKit
import SwiftUI

/// One `Section("Diagnostics")` under a connected display: what this display
/// is, how its brightness is being driven, what it told us, what is
/// unavailable and why, and what is true right now.
///
/// The feature is the HONESTY RULES (DT30), not the rows:
/// - every "unavailable" row states a REASON drawn from a typed value;
/// - an unanswered display is reported as UNANSWERED, never as unsupported;
/// - a write-only panel is NAMED, with the consequence stated plainly;
/// - we never claim what macOS hides, only what our own curation did;
/// - "not measured yet" (nil) is never rendered as "no answer" (empty);
/// - internal key names never reach copy (D25).
///
/// It renders under the BUILT-IN display too (DT45), not only under externals —
/// and the rules above are what make that worth doing rather than merely
/// possible. "Why can't hardware control reach my laptop screen?" is a real
/// question this feature exists to answer, and it is answered here, once, in
/// the brightness group. Every row that describes a data cable, an EDID or a
/// DDC answer is OMITTED for the built-in rather than rendered against a fact
/// that will never arrive: `DisplayDiscovery` is external-only by construction,
/// so a "Connection: not enumerated yet" on the built-in would be a permanent
/// promise of an answer, which is exactly the shape DT30 rule (e) forbids.
///
/// `@MainActor` is load-bearing: a `View`'s stored and computed properties
/// other than `body` are nonisolated under complete concurrency, and this one
/// constructs and reads main-actor types.
///
/// It WRITES NOTHING (DT31) — no `PrefName` case, no `DisplayPrefWriter`, no
/// button. D29 does not bind it today and binds the moment a control is added:
/// a "re-probe now" control would fall under D29 rule 3 immediately.
@MainActor
struct DisplayDiagnosticsSection: View {
  let state: AppModel.DisplayState

  @Environment(AppModel.self) private var model

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var facts: DisplayHardwareFacts? { model.hardwareFacts[persistenceKey] }
  private var path: BrightnessPath { state.controller.brightnessPath }

  /// Asked of the model's own slot rather than of the persistence key: the
  /// model is the thing that decides which display is the built-in, and a
  /// literal key compared here would be a second, driftable copy of that
  /// decision.
  private var isBuiltIn: Bool { model.builtIn?.id == state.id }

  var body: some View {
    // MANDATORY. `DisplayPrefs` is plain `UserDefaults` and is not observable;
    // `prefsRevision` is the ONLY invalidation signal, and this section reads
    // prefs in four of its five groups. Omitting it yields a silently stale
    // page.
    let _ = model.prefsRevision

    Section("Diagnostics") {
      thisDisplayGroup
      brightnessGroup
      // Every row in group 3 is about a DDC answer, and the built-in never
      // gives one — it has no wire and `probeVolumeCapabilities` walks
      // `model.displays`, which is external-only. Rendering it there would put
      // "Not asked yet" under a heading promising an answer that can never
      // arrive (DT30 rule (e)); the built-in's DDC story is already stated
      // once, in group 2, where it is true.
      if !isBuiltIn {
        whatTheDisplaySaidGroup
      }
      unavailableGroup
      rightNowGroup
    }
  }

  // MARK: - 1. This display

  @ViewBuilder private var thisDisplayGroup: some View {
    SettingsCaption("This display")

    LabeledContent("Reported name") {
      Text(verbatim: state.display.name).foregroundStyle(.secondary)
    }

    if !DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName).isEmpty {
      LabeledContent("Your name for it") {
        Text(verbatim: DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName))
          .foregroundStyle(.secondary)
      }
    }

    // The cable-and-EDID rows. Omitted wholesale for the built-in panel — see
    // the type comment.
    if !isBuiltIn {
      SettingRow("Which cable this display is connected through.") {
        LabeledContent("Connection") {
          Text(verbatim: transportText).foregroundStyle(.secondary)
        }
      }

      // "Not enumerated yet" and "Not reported" are different facts and this
      // row used to collapse them, saying the display reported nothing when
      // nothing had been READ. Same defence `transportText` and `serialText`
      // already carry.
      LabeledContent("Manufacturer") {
        Text(verbatim: manufacturerText).foregroundStyle(.secondary)
      }

      LabeledContent("Serial number") {
        Text(verbatim: serialText).foregroundStyle(.secondary)
      }

      // Shown ONLY when it applies, and only once the facts have actually
      // arrived: a caveat raised while we still know nothing would claim the
      // display reported no serial before it reported anything at all. A
      // standing caveat about a hazard the user does not have is noise, and
      // noise is what makes real warnings ignorable.
      if let facts, facts.numericSerialNumber == nil, facts.alphanumericSerialNumber == nil {
        SettingsCaption(
          "This display reports no serial number. Two identical units would share one set of saved settings."
        )
      }

      if let width = facts?.physicalWidthCm, let height = facts?.physicalHeightCm {
        LabeledContent("Panel size") {
          Text(verbatim: "\(width) × \(height) cm").foregroundStyle(.secondary)
        }
      }
    }

    if let native = model.displayModes.catalogs[state.id], native.nativeKnown,
       let current = native.current {
      LabeledContent("Current mode") {
        Text(verbatim: modeText(current)).foregroundStyle(.secondary)
      }
    }

    resolutionSourceRows

    identityKeysRow
  }

  /// Where this display's resolutions came from.
  ///
  /// DT30 rule (d): this describes OUR OWN enumeration, never a claim about
  /// what macOS is hiding. "Listed by macOS" is a count we made; "found beyond
  /// that list" is a count we made. Neither asserts why macOS omitted them.
  @ViewBuilder private var resolutionSourceRows: some View {
    if let catalog = model.displayModes.catalogs[state.id] {
      let publishedCount = catalog.all.count { $0.provenance == .coreGraphics }
      let revealedCount = catalog.all.count { $0.provenance == .coreGraphicsServices }

      LabeledContent("Resolutions listed by macOS") {
        Text(verbatim: "\(publishedCount)").foregroundStyle(.secondary)
      }

      LabeledContent("Additional resolutions found") {
        Text(verbatim: additionalResolutionsText(revealed: revealedCount))
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Three distinct answers, and the distinction matters (DT30 rule (e)):
  /// "none on this panel" is a measurement, "not available" is a missing
  /// capability, and conflating them would report a capability gap as a fact
  /// about the display.
  private func additionalResolutionsText(revealed: Int) -> String {
    guard model.displayModes.revealsHiddenModes else {
      return "Not available on this version of macOS"
    }
    return revealed == 0 ? "None for this display" : "\(revealed)"
  }

  /// The two keys this display's settings hang off. Split out of the group so
  /// the IOReg tooltip can be attached for externals and left off the built-in,
  /// whose IOReg facts are never read at all — a tooltip there would be
  /// reporting a lookup that never ran.
  ///
  /// The tooltip deliberately carries the IOReg PATH and not
  /// `ioregMatchScore`. The score is a non-optional `Int` that reads 0 both
  /// when nothing matched and when the CoreDisplay dictionary could not be read
  /// at all, so any wording for 0 asserts one of two incompatible things; and
  /// its documented "0…20" ceiling is wrong (the real maximum is 16). A number
  /// that cannot be worded honestly is not a number to put in front of a user
  /// — DT30 rule (g) wants the real one or none.
  @ViewBuilder private var identityKeysRow: some View {
    let row = SettingRow(identityKeysCaption) {
      VStack(alignment: .leading, spacing: 2) {
        LabeledContent("Settings key") {
          Text(verbatim: persistenceKey).foregroundStyle(.secondary)
        }
        LabeledContent("Display key") {
          Text(verbatim: displayKey ?? "Not enumerated yet")
            .foregroundStyle(.secondary)
        }
      }
    }

    if isBuiltIn {
      row
    } else {
      row.help(ioregPathHelp)
    }
  }

  /// The caption has to survive the case where the two keys are IDENTICAL —
  /// which is what the built-in shows (`builtIn` / `builtIn`). The original
  /// sentence explained the mechanism and left the user staring at two equal
  /// values under text implying a distinction they could not see.
  private var identityKeysCaption: LocalizedStringKey {
    if displayKey == persistenceKey {
      return "Settings are saved under the first key and resolution under the second. They are the same here: this display has no DDC identity for resolution to key off, so both fall back to the same name."
    }
    return "Settings are saved under the first key. Resolution is saved under the second, because the built-in and virtual displays have no DDC identity to use."
  }

  private var displayKey: String? {
    model.displayModes.catalogs[state.id]?.display.identity.key
  }

  private var ioregPathHelp: String {
    guard let facts else { return "The system port path for this display has not been read yet." }
    guard let location = facts.ioDisplayLocation else {
      return "This display reports no system port path."
    }
    return "System port path: \(location)"
  }

  /// Rendered as the kernel spelled it. The `Transport` dictionary's vocabulary
  /// is macOS's, not ours, and no real panel's spelling has been observed — so
  /// this maps nothing and prettifies nothing. A pane that invents a vocabulary
  /// lies the moment the kernel's changes.
  private var transportText: String {
    guard let facts else { return "Not enumerated yet" }
    switch (facts.transportUpstream, facts.transportDownstream) {
    case let (up?, down?) where up == down: return up
    case let (up?, down?): return "\(up) → \(down)"
    case let (up?, nil): return up
    case let (nil, down?): return down
    case (nil, nil): return "This display does not report its connection type"
    }
  }

  private var manufacturerText: String {
    guard let facts else { return "Not enumerated yet" }
    return facts.manufacturerID ?? "Not reported"
  }

  private var serialText: String {
    guard let facts else { return "Not enumerated yet" }
    if let alphanumeric = facts.alphanumericSerialNumber { return alphanumeric }
    if let numeric = facts.numericSerialNumber { return String(numeric) }
    return "Not reported"
  }

  private func modeText(_ mode: DisplayMode) -> String {
    "\(mode.logicalWidth) × \(mode.logicalHeight) at \(Int(mode.refreshHz.rounded())) Hz"
  }

  // MARK: - 2. How brightness is controlled

  @ViewBuilder private var brightnessGroup: some View {
    SettingsCaption("How brightness is controlled")

    SettingRow(brightnessPathCaption) {
      LabeledContent("Brightness path") {
        Text(verbatim: brightnessPathText).foregroundStyle(.secondary)
      }
    }

    SettingRow("Native brightness is what macOS itself uses. It is the only path that works while a display is in HDR mode.") {
      LabeledContent("Native brightness") {
        Text(DisplayServices.isAvailable
          ? "Available on this Mac"
          : "Unavailable — macOS did not load the framework \(AppInfo.productName) needs for it")
          .foregroundStyle(.secondary)
      }
    }

    // The built-in's whole DDC story, stated once and only where it is true.
    // It is not a failure, a preference, or something a future release fixes,
    // so it is not phrased as any of those.
    if isBuiltIn {
      SettingRow("macOS drives the built-in panel's backlight itself, so there is nothing for \(AppInfo.productName) to send and nothing that can be turned back on.") {
        LabeledContent("Hardware control") {
          Text("Does not apply — this panel has no data cable to carry hardware commands")
            .foregroundStyle(.secondary)
        }
      }
    }

    // Gamma interference is a fight over ONE backend, and the row is shown
    // only to a display actually using it.
    //
    // Two claims the shipped row could not support, both fixed here. First,
    // the counter is only ever touched inside `checkBeforeApply`, which runs
    // one statement before a GAMMA apply — a display on the hardware, native
    // or overlay path is never looked at, so its permanent 0 rendered as
    // "None this session" asserted absence on the strength of a probe that
    // never ran. Omit rather than blank (DT45). Second, the window was wrong:
    // `resetCounter()` fires on EVERY display reconfiguration
    // (`StatusItemController`), so "this session" told a user who had watched
    // a conflict happen, then woken the Mac, that there had been none.
    if usesGammaLeg, let monitor = model.gammaInterference {
      SettingRow(gammaConflictCaption) {
        LabeledContent("Color profile conflicts") {
          Text(gammaConflictText(monitor.interferenceCount(for: state.id)))
            .foregroundStyle(.secondary)
        }
      }
      if monitor.suspendedForSession {
        SettingsCaption("\(AppInfo.productName) has stopped watching for these until it is relaunched.")
      }
    }
  }

  /// Whether the gamma backend is the one carrying this display's software
  /// leg — the only configuration in which anything checks for a clobber.
  private var usesGammaLeg: Bool {
    switch path {
    case .software(.gamma), .combined(_, .gamma), .softwareOnly(.gamma, _, _):
      true
    case .native, .hardware, .software, .combined, .softwareOnly, .unavailable:
      false
    }
  }

  private func gammaConflictText(_ count: Int) -> String {
    count == 0
      ? "None noticed"
      : "\(count) — another app keeps taking this display's color profile back"
  }

  /// Both limits of the number are stated, because neither is guessable from
  /// it: WHEN the count restarts, and that it only counts what was looked at.
  private var gammaConflictCaption: LocalizedStringKey {
    "\(AppInfo.productName) only looks while it is dimming this display through its color profile, and the count starts again whenever your displays are reconfigured — a resolution change, a display plugged or unplugged, or the Mac waking."
  }

  /// The engine's own answer, put into the user's words. `BrightnessPath` gained
  /// a `.softwareOnly` case after this section was specified, and it is the one
  /// case where PART of the slider works — so it gets its own sentence rather
  /// than being folded in with plain software dimming, which would overstate
  /// what moves.
  private var brightnessPathText: String {
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
      "Split at \(percent(switching)) — software below, the data cable above"
    case let .combined(switching, .overlay):
      "Split at \(percent(switching)) — overlay below, the data cable above"
    case let .softwareOnly(.gamma, .ddcTurnedOff, dimsBelow):
      "Software only below \(percent(dimsBelow)), through the display's color profile"
    case let .softwareOnly(.overlay, .ddcTurnedOff, dimsBelow):
      "Software only below \(percent(dimsBelow)), through a dark overlay"
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Nothing is moving this display's brightness"
    }
  }

  private var brightnessPathCaption: LocalizedStringKey {
    switch path {
    case .native:
      "macOS sets this display's brightness directly. No hardware commands are sent over the cable."
    case .hardware:
      "Every brightness change is a command sent to the display over its data cable."
    case .software:
      "The display's own backlight is not touched. \(AppInfo.productName) darkens what is drawn on it."
    case let .combined(switching, _):
      "Below \(percent(switching)) this display dims in software while the cable holds at its lowest level; above it, the cable carries the whole range."
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      "The hardware brightness command is turned off for this display, so only the part of the slider below \(percent(dimsBelow)) dims. Above that, nothing moves."
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Combined dimming is off for this display and its hardware brightness command is turned off, so nothing is left to carry the value."
    }
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  // MARK: - 3. What the display told us

  private var capabilities: String? { model.capabilityString[persistenceKey] }

  /// Three states, never two, and the middle one is deliberately not a
  /// verdict. The probe not having run is not the same fact as the display
  /// having stayed silent, and collapsing them would let the pane accuse a
  /// panel that was never asked.
  ///
  /// The middle state is also as far as the evidence goes. `capabilityString`
  /// is stored only on a successful read, and `readCapabilityString` returns
  /// nil both when nothing came back and when what came back could not be
  /// reassembled — so a display that answered BADLY lands in the same bucket
  /// as one that stayed quiet, and the sentence must not pick between them.
  private var capabilityAnswerText: String {
    if capabilities != nil { return "The display answered" }
    if model.volumeSupport[persistenceKey] != nil {
      return "No answer \(AppInfo.productName) could read"
    }
    return "Not asked yet"
  }

  private var capabilityAnswerCaption: LocalizedStringKey {
    if capabilities != nil {
      return "\(AppInfo.productName) asks each display to describe itself once after it is plugged in."
    }
    if model.volumeSupport[persistenceKey] != nil {
      // "Once this session" would be wider than the cache's real window:
      // `AppModel.performRefresh` evicts both `volumeSupport` and
      // `capabilityString` for any display that is no longer live, because a
      // replug hands out a fresh `IOAVService` and an old answer is not
      // evidence about the new wire. So the window is the plug, not the
      // session, and unplugging re-asks.
      return "\(AppInfo.productName) asked once since this display was plugged in. Either the display sent nothing or it sent something that could not be put back together — from here the two look the same."
    }
    // The one skip that is not "hasn't got round to it yet": DDC is dead under
    // HDR, so `CapabilityProbePolicy` refuses to probe and refuses to cache a
    // verdict that would outlive its cause.
    if state.controller.isHDREngaged {
      return "\(AppInfo.productName) does not ask a display that is in HDR mode — hardware commands do not reach it — and will ask once HDR turns off."
    }
    return "\(AppInfo.productName) asks each display to describe itself once after it is plugged in. It has not asked this one yet."
  }

  /// nil means the description did not parse end to end (D24), which is a
  /// DIFFERENT answer from "the display listed no codes". A partially parsed
  /// list must never be shown as though it were the display's advertised list.
  private var advertisedCodes: Set<UInt8>? {
    capabilities.flatMap { CapabilityString.codes(in: $0) }
  }

  @ViewBuilder private var whatTheDisplaySaidGroup: some View {
    SettingsCaption("What the display told us")

    SettingRow(capabilityAnswerCaption) {
      LabeledContent("Capability request") {
        Text(verbatim: capabilityAnswerText).foregroundStyle(.secondary)
      }
    }
    .help("VCP 0xF3 · MCCS capabilities request")

    if let capabilities {
      LabeledContent("MCCS version") {
        Text(verbatim: CapabilityString.tag("mccs_ver", in: capabilities) ?? "Not stated")
          .foregroundStyle(.secondary)
      }
      LabeledContent("Model") {
        Text(verbatim: CapabilityString.tag("model", in: capabilities) ?? "Not stated")
          .foregroundStyle(.secondary)
      }
      LabeledContent("Panel type") {
        Text(verbatim: CapabilityString.tag("type", in: capabilities) ?? "Not stated")
          .foregroundStyle(.secondary)
      }

      SettingRow(advertisedCaption) {
        LabeledContent("Advertised commands") {
          Text(verbatim: advertisedText).foregroundStyle(.secondary)
        }
      }

      // Collapsed, and a plain block of text rather than a list with
      // affordances (R12): it is the wire's own words, kept for copying into a
      // bug report, not a thing to browse.
      DisclosureGroup("What the display sent, exactly") {
        Text(verbatim: capabilities)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    SettingRow(readEvidenceCaption) {
      LabeledContent("Reading values back") {
        Text(verbatim: readEvidenceText).foregroundStyle(.secondary)
      }
    }

    LabeledContent("Brightness scale") {
      Text(verbatim: brightnessScaleText).foregroundStyle(.secondary)
    }
  }

  /// Three answers, because `didReadMaxDDC` being false is not one fact.
  /// `BrightnessController.refreshFromHardware` returns before it reads for a
  /// display on the native path or with the brightness command turned off, and
  /// the pass may simply not have run yet — in all of those it leaves the flag
  /// false without ever having asked. "The display did not report one" there is
  /// an absence claim about a probe that never ran, and it rendered directly
  /// above this same group's "\(AppInfo.productName) has not read from this
  /// display".
  ///
  /// The brightness controller's OWN evidence, not the folded `readEvidence`:
  /// the maximum comes from the brightness read alone, so a volume read that
  /// answered must not be allowed to speak for it.
  private var brightnessScaleText: String {
    if state.controller.didReadMaxDDC {
      return "This display reported a maximum of \(state.controller.maxDDCValue)"
    }
    if state.controller.readEvidence == .notAttempted {
      return "Assumed 100 — \(AppInfo.productName) has not asked this display for its scale"
    }
    return "Assumed 100 — the display did not report one"
  }

  /// The four commands this app speaks, and which of them this display
  /// advertises. Never a claim about what macOS hides (DT30 rule d) — only
  /// about what the display itself listed.
  private var advertisedText: String {
    guard let advertisedCodes else {
      return "The description did not parse, so \(AppInfo.productName) makes no claim about it"
    }
    let spoken: [(UInt8, String)] = [
      (VCP.brightness, "brightness"),
      (VCP.contrast, "contrast"),
      (VCP.audioSpeakerVolume, "volume"),
      (VCP.audioMuteScreenBlank, "mute"),
    ]
    let listed = spoken.filter { advertisedCodes.contains($0.0) }.map(\.1)
    if listed.isEmpty {
      return "None of the four \(AppInfo.productName) uses, out of \(advertisedCodes.count) listed"
    }
    return listed.joined(separator: ", ") + " (of \(advertisedCodes.count) commands listed)"
  }

  private var advertisedCaption: LocalizedStringKey {
    "\(AppInfo.productName) uses four commands: brightness, contrast, volume and mute. A display can advertise a command it ignores, or ignore one it advertises."
  }

  /// Worst evidence across this display's three controllers. One `allZeros` is
  /// never cancelled by a later `notAttempted`.
  private var readEvidence: DDCReadEvidence {
    DDCReadEvidence.worst([
      state.controller.readEvidence,
      state.volume.readEvidence,
      state.contrast.readEvidence,
    ])
  }

  /// The write-only panel is NAMED. It is a real and permanent property of
  /// some hardware, it explains every other value on this page, and a user who
  /// has it needs the words to search for.
  private var readEvidenceText: String {
    switch readEvidence {
    case .notAttempted: "\(AppInfo.productName) has not read from this display"
    case .answered: "This display answers reads"
    case .allZeros: "Write-only — this display takes commands but never answers a read"
    case .noReply: "This display did not reply to a read"
    }
  }

  private var readEvidenceCaption: LocalizedStringKey {
    switch readEvidence {
    case .notAttempted:
      notAttemptedCaption
    case .answered:
      "The values shown elsewhere in this window come from the display itself."
    case .allZeros, .noReply:
      "The values shown elsewhere in this window are what \(AppInfo.productName) last wrote, not what the display reports."
    }
  }

  /// The old sentence — "startup behaviour for THIS DISPLAY is not set to read
  /// values back" — asserted a cause it could not know, at a scope that does
  /// not exist. `startupAction` is app-level (`DisplayPrefs` reads it straight
  /// off the `startupAction` default, unkeyed), and `.notAttempted` also
  /// arises from Safe Mode, from all three commands being turned off for this
  /// display, and simply from the first read not having happened yet.
  ///
  /// So the two causes that ARE knowable from here are named, in the order
  /// that matches how they mask each other — under Safe Mode the
  /// `startupAction` getter reports `.doNothing` regardless of what is stored
  /// (D11), so reading it first would report the pref rather than the session.
  /// Everything else falls through to a sentence that states the consequence
  /// and claims no cause.
  private var notAttemptedCaption: LocalizedStringKey {
    if model.isSafeMode {
      return "Safe Mode is on for this session, so nothing is read back from any display. The values shown elsewhere in this window come from your saved settings, not from the display."
    }
    if prefs.startupAction != .read {
      return "\(AppInfo.productName) is not set to read values back from displays at startup. The values shown elsewhere in this window come from your saved settings, not from the display."
    }
    return "Nothing has been read from this display yet. The values shown elsewhere in this window come from your saved settings, not from the display."
  }

  // MARK: - 4. What is unavailable, and why

  /// DT30 rule (a) lives here: no row in this group may read just
  /// "Unavailable" or "Not supported". Every one of them names the thing that
  /// took the feature away, and every reason comes off a typed value rather
  /// than being composed from prefs at the point of display.
  ///
  /// Volume, contrast and mute are the DDC audio and picture commands, and the
  /// built-in has no wire to carry them — nothing in this app ever offers them
  /// for it. HDR is likewise external-only: `BrightnessController` builds the
  /// built-in slot with no HDR backend at all, so `supportsHDR` there is a
  /// hardwired false that would render as "this display reports no HDR modes"
  /// about a panel whose HDR macOS drives perfectly well. Both are omitted
  /// rather than answered wrongly.
  @ViewBuilder private var unavailableGroup: some View {
    SettingsCaption("What is unavailable, and why")

    LabeledContent("Brightness") {
      Text(verbatim: brightnessAvailabilityText).foregroundStyle(.secondary)
    }

    if !isBuiltIn {
      LabeledContent("Volume") {
        Text(verbatim: volumeAvailabilityText).foregroundStyle(.secondary)
      }
      .help("VCP 0x62")

      LabeledContent("Contrast") {
        Text(verbatim: contrastAvailabilityText).foregroundStyle(.secondary)
      }
      .help("VCP 0x12")

      LabeledContent("Mute") {
        Text(verbatim: muteAvailabilityText).foregroundStyle(.secondary)
      }
      .help("VCP 0x8D")

      LabeledContent("HDR") {
        Text(verbatim: hdrAvailabilityText).foregroundStyle(.secondary)
      }
    }
  }

  /// Three answers, because there are three outcomes. `.softwareOnly` is the
  /// one where PART of the slider works, and reporting it as either available
  /// or unavailable would be false in the half that matters.
  private var brightnessAvailabilityText: String {
    switch path {
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Unavailable — combined dimming is off for this display and its hardware brightness command is turned off"
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      "Partly available — the hardware brightness command is turned off, so only the part of the slider below \(percent(dimsBelow)) moves anything"
    case .native, .software, .hardware, .combined:
      "Available"
    }
  }

  /// DT30 rule (b), the row that rule exists for. `.unknown` is NOT
  /// "unsupported": `.unsupported` is reachable ONLY from a description that
  /// parsed cleanly end to end and did not list the code. A pane that
  /// flattened three states to two would grey a working control on a display
  /// that merely stayed silent — D24's doctrine is that unknown resolves to
  /// enabled, and this is that doctrine said out loud.
  private var volumeAvailabilityText: String {
    switch prefs.audioSinkOverride {
    case .forceNone:
      return "Unavailable — you set this display's volume slider to always off"
    case .forcePresent:
      return "Available — you set this display's volume slider to always on"
    case .auto:
      break
    }
    if !state.volume.isAvailable { return ddcOffReason(command: "volume") }
    // ABSENT is not `.unknown`. A stored `.unknown` means the probe ran and
    // the display said nothing usable; an absent entry means nobody has asked
    // yet. Folding the two with `?? .unknown` put "this display did not
    // answer" against a display that was never spoken to — the same
    // never-looked-reported-as-nothing-found defect this section exists to
    // remove, one row away from the row that states it.
    guard let support = model.volumeSupport[persistenceKey] else {
      return "Available — \(AppInfo.productName) has not asked this display yet, so the control stays on"
    }
    switch support {
    case .supported:
      return "Available — this display lists the volume command"
    case .unsupported:
      return "Unavailable — this display's description parsed cleanly and does not list the volume command"
    case .unknown:
      // A stored `.unknown` has TWO producers
      // (`AppModel.probeVolumeCapabilities`): `readCapabilityString()` came
      // back nil, OR a string arrived and `CapabilityString.support(forVCP:in:)`
      // fell through to `.unknown` because it was unbalanced, carried no
      // top-level `vcp(` tag, or listed no codes. Only the first is silence.
      //
      // In the second, `capabilityString` IS populated — and saying "this
      // display did not answer" there contradicts, three rows apart, this same
      // group's "The display answered", its verbatim copy of what the display
      // sent, and "The description did not parse, so \(AppInfo.productName)
      // makes no claim about it" (`codes(in:)` fails on exactly the same three
      // gates, in the same order). The capability row above already draws this
      // distinction; the row that decides whether a control stays on has more
      // reason to draw it, not less.
      return capabilities == nil
        ? "Available — this display sent no answer \(AppInfo.productName) could read, so the control stays on"
        : "Available — \(AppInfo.productName) could not read a command list out of this display's description, so the control stays on"
    }
  }

  private var contrastAvailabilityText: String {
    state.contrast.isAvailable ? "Available" : ddcOffReason(command: "contrast")
  }

  private var muteAvailabilityText: String {
    if !prefs.enableMuteUnmute {
      return "Unavailable — muting with the display's own mute command is turned off"
    }
    return state.volume.isAvailable ? "Available" : ddcOffReason(command: "volume")
  }

  /// `DDCValueController.isAvailable` is `!unavailableDDC && !forceSoftware`,
  /// and the two settings behind it are DIFFERENT things a user can act on
  /// differently — one is this command, the other is every command on this
  /// display. Naming them apart is the difference between a row that explains
  /// and a row that shrugs.
  private func ddcOffReason(command: String) -> String {
    if prefs.forceSoftware {
      return "Unavailable — hardware control is turned off for this display"
    }
    return "Unavailable — the \(command) command is turned off for this display"
  }

  /// `supportsHDR` is `cachedSupportsHDR`, and it is false in three different
  /// situations: the display really lists no HDR modes, the async
  /// `refreshHDRCaches()` has not landed yet, and `MonitorPanelService`'s
  /// manager is nil because MonitorPanel.framework did not load ("nil when the
  /// framework failed to load; every entry point then degrades"). Blaming the
  /// panel for the last two is the same defect as reporting an unasked display
  /// as unsupported, so the sentence names both possibilities and says they
  /// are indistinguishable from here — the shape the capability row above
  /// already uses.
  ///
  /// The DisplayServices check runs FIRST. It is a different framework — the
  /// one that carries native brightness, which is the only path that reaches a
  /// display in HDR mode — and it is knowable regardless of what MonitorPanel
  /// answered. Behind the `supportsHDR` guard it could never fire for the case
  /// it describes, because a machine with no private frameworks at all fails
  /// the guard first.
  private var hdrAvailabilityText: String {
    guard DisplayServices.isAvailable else {
      return "Unavailable — macOS did not load the framework \(AppInfo.productName) needs for HDR brightness"
    }
    guard state.controller.supportsHDR else {
      return "Unavailable — \(AppInfo.productName) has no HDR answer for this display: either it lists no HDR modes, or macOS did not load the framework \(AppInfo.productName) asks. From here the two look the same."
    }
    return "Available"
  }

  // MARK: - 5. Right now

  /// State, not settings. Everything here can be different a second from now,
  /// and every one of them has words — nothing in this group is carried by a
  /// colour or an icon alone.
  ///
  /// The HDR and sound-output rows are external-only for the same reasons as
  /// in group 4: the built-in has no HDR backend in this app and no volume
  /// command, so both would answer from a hardwired default rather than from
  /// anything observed.
  @ViewBuilder private var rightNowGroup: some View {
    SettingsCaption("Right now")

    if !isBuiltIn {
      LabeledContent("HDR") {
        Text(verbatim: state.controller.isHDREngaged ? "Engaged" : "Off").foregroundStyle(.secondary)
      }

      // `hdrMode` is the POLICY and `isHDREngaged` the STATE, so the two
      // disagreeing is not a bug — it is somebody having turned HDR on in
      // System Settings, and it explains why the hardware commands stopped.
      if state.controller.isHDREngaged, state.controller.hdrMode == .off {
        SettingsCaption("HDR was turned on outside \(AppInfo.productName). Hardware commands do not reach a display while it is in HDR mode.")
      }
    }

    LabeledContent(writeGateLabel) {
      Text(verbatim: model.displayManager.isEpochCurrent(model.displayManager.currentEpoch())
        ? "Being sent"
        : "Paused while displays are changing or asleep")
        .foregroundStyle(.secondary)
    }

    if model.isSafeMode {
      SettingRow("Shift was held at launch. Saved values are not restored, nothing is read back, and nothing is written at quit. Sliders and keys still work.") {
        LabeledContent("Safe Mode") {
          Text(verbatim: "On for this session").foregroundStyle(.secondary)
        }
      }
    }

    // The caption is attached only to the empty case, which is the state a
    // single-display rig is actually in: the not-running sibling gives its
    // reason in the value, and a bare "None" gave none at all. It states the
    // gates rather than picking one — which of them is holding is not visible
    // from here, and all of them are necessary conditions.
    if watchedKeyFamilies.isEmpty, model.lastArmedTapConfig != nil {
      SettingRow("\(AppInfo.productName) watches a family of keys only while something can act on it: brightness while an external display is connected, volume while the sound output matches a display it controls — and either one only while that family is set to use the media keys. Keys it does not watch go straight to macOS.") {
        LabeledContent("Keys being watched") {
          Text(verbatim: watchedKeysText).foregroundStyle(.secondary)
        }
      }
    } else {
      LabeledContent("Keys being watched") {
        Text(verbatim: watchedKeysText).foregroundStyle(.secondary)
      }
    }

    if model.accessibility.isWarningWarranted {
      SettingsCaption("\(AppInfo.productName) does not have Accessibility permission, so the media keys it is set to use are not reaching it.")
    }

    if !isBuiltIn {
      LabeledContent("Sound output") {
        Text(verbatim: audioMatchText).foregroundStyle(.secondary)
      }
    }

    LabeledContent("Last brightness command") {
      Text(verbatim: lastWriteText).foregroundStyle(.secondary)
    }

    if let report = model.displayModes.reapplyReports[state.id] {
      LabeledContent("Last resolution problem") {
        Text(verbatim: reapplyText(report.notice)).foregroundStyle(.secondary)
      }
      .modifier(ReapplyDiagnostic(notice: report.notice))
    }

    LabeledContent("Mirroring") {
      Text(verbatim: mirrorText).foregroundStyle(.secondary)
    }
  }

  /// The epoch gate stops every submit, native and DDC alike — but the
  /// built-in has no hardware command to stop, so calling its row "Hardware
  /// commands" would name a wire it does not have.
  private var writeGateLabel: LocalizedStringKey {
    isBuiltIn ? "Brightness commands" : "Hardware commands"
  }

  /// Reads the LAST ARMED config, not a freshly computed one. The two differ
  /// exactly when a rearm failed — which is the case this row is for (B9).
  private var watchedKeysText: String {
    guard model.lastArmedTapConfig != nil else {
      return "None — the media-key tap is not running"
    }
    let families = watchedKeyFamilies
    return families.isEmpty
      ? "None — every media key is going straight to macOS"
      : families.joined(separator: ", ")
  }

  /// Split out so the row can tell "watching nothing" from "not running" and
  /// caption the first without recomputing the words.
  private var watchedKeyFamilies: [String] {
    guard let config = model.lastArmedTapConfig else { return [] }
    var families: [String] = []
    if config.watchedKeys.contains(.brightnessUp) || config.watchedKeys.contains(.brightnessDown) {
      families.append("brightness")
    }
    if config.watchedKeys.contains(.volumeUp) || config.watchedKeys.contains(.volumeDown)
      || config.watchedKeys.contains(.mute) {
      families.append("volume and mute")
    }
    return families
  }

  private var audioMatchText: String {
    guard let device = model.audioDevices.defaultOutputDevice() else {
      return "macOS reports no default output device"
    }
    let matches = AudioRoutingPolicy.displayMatchesDevice(
      deviceName: device.name,
      rawDisplayName: state.display.name,
      nameOverride: prefs.audioDeviceNameOverride
    )
    return matches
      ? "\(device.name) — matched to this display"
      : "\(device.name) — not matched to this display"
  }

  private var lastWriteText: String {
    guard let target = state.controller.lastAppliedTarget() else {
      return state.controller.lastApplyFailed()
        ? "The last command was not accepted"
        : "Nothing has been sent to this display yet"
    }
    let value: String = switch target {
    case let .ddc(raw): "value \(raw) over the data cable"
    case let .native(level): "\(percent(Double(level))) through macOS"
    }
    return state.controller.lastApplyFailed()
      ? "Last accepted: \(value). The most recent command was not accepted."
      : "Accepted: \(value)"
  }

  private func reapplyText(_ notice: ModeReapplyNotice) -> String {
    switch notice {
    case let .substituted(mode):
      "\(AppInfo.productName) could not restore your saved resolution and used \(modeText(mode)) instead"
    case .unavailable:
      "Your saved resolution is not offered by this display right now"
    case .failed:
      "Restoring your saved resolution failed"
    }
  }

  /// `CGDisplayMirrorsDisplay` names the display whose contents this one is
  /// SHOWING. It is not a membership test — a mirror MASTER reports null, and
  /// so does a standalone display — so this row claims only what that call can
  /// actually support. Mirror-set membership arrives with #12, and this row
  /// should be revisited then: it will be able to tell a master from a
  /// standalone display, which it cannot today.
  private var mirrorText: String {
    guard let configured = model.displayModes.catalogs[state.id]?.display else {
      return "Not enumerated yet"
    }
    return configured.isMirrorSlave
      ? "Showing another display's contents"
      : "Showing its own contents"
  }
}
