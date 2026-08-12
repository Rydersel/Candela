import CandelaKit
import SwiftUI

/// The half of the diagnostics page's copy that cannot leave the app target.
///
/// The split with `DiagnosticsCopy` (CandelaKit) is exactly the split
/// `PanelHealthCopy` and `OledCareCopy` already draw, for the same reason: a
/// sentence derived from values returns `String` and gets a test, and a sentence
/// that is a `LocalizedStringKey` cannot, because CandelaKit imports no SwiftUI
/// and there is no app test target. So the VALUES on the right of every row live
/// in Kit and the CAPTIONS explaining them live here.
///
/// Moved out of `DiagnosticsPage` (#127) with no word changed. These are the
/// page's explanations, and several of them are load-bearing: the caption under
/// "Reading values back" names the two causes that are knowable and claims no
/// others, and the caption under "Capability request" tells four states apart.
/// Read the comment on each before rewording it.
///
/// `LocalizedStringKey` is not `Sendable`, so these are computed `static var`s
/// rather than `static let`s, matching `MirroringCopy`.
enum DiagnosticsPageCopy {

  // MARK: - This Display

  static var connection: LocalizedStringKey {
    "Which cable this display is connected through."
  }

  /// Shown ONLY when it applies, and only once the facts have actually arrived:
  /// a caveat raised while we still know nothing would claim the display
  /// reported no serial before it reported anything at all. A standing caveat
  /// about a hazard the user does not have is noise, and noise is what makes
  /// real warnings ignorable.
  static var noSerialNumber: LocalizedStringKey {
    "This display reports no serial number. Two identical units would share one set of saved settings."
  }



  /// The caption has to survive the case where the two keys are IDENTICAL,
  /// which is what the built-in shows (`builtIn` / `builtIn`). The original
  /// sentence explained the mechanism and left the user staring at two equal
  /// values under text implying a distinction they could not see.
  static func identityKeys(keysMatch: Bool) -> LocalizedStringKey {
    if keysMatch {
      return "Settings are saved under the first key and resolution under the second. They are the same here: this display has no DDC identity for resolution to key off, so both fall back to the same name."
    }
    return "Settings are saved under the first key. Resolution is saved under the second, because the built-in and virtual displays have no DDC identity to use."
  }

  // MARK: - Brightness Control

  static func brightnessPath(_ path: BrightnessPath) -> LocalizedStringKey {
    switch path {
    case .native:
      "macOS sets this display's brightness directly. No hardware commands are sent over the cable."
    case .hardware:
      "Every brightness change is a command sent to the display over its data cable."
    case .software:
      "The display's own backlight is not touched. \(AppInfo.productName) darkens what is drawn on it."
    case let .combined(switching, _):
      "Below \(SliderSnap.percentText(switching)) this display dims in software while the cable holds at its lowest level; above it, the cable carries the whole range."
    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      "The hardware brightness command is turned off for this display, so only the part of the slider below \(SliderSnap.percentText(dimsBelow)) dims. Above that, nothing moves."
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Combined dimming is off for this display and its hardware brightness command is turned off, so nothing is left to carry the value."
    }
  }

  static var nativeBrightness: LocalizedStringKey {
    "Native brightness is what macOS itself uses. It is the only path that works while a display is in HDR mode."
  }

  static var builtInHardwareControl: LocalizedStringKey {
    "macOS drives the built-in display's backlight itself, so there is nothing for \(AppInfo.productName) to send and nothing that can be turned back on."
  }

  /// Both limits of the number are stated, because neither is guessable from it:
  /// WHEN the count restarts, and that it only counts what was looked at.
  static var gammaConflicts: LocalizedStringKey {
    "\(AppInfo.productName) only looks while it is dimming this display through its color profile, and the count starts again whenever your displays are reconfigured: a resolution change, a display plugged or unplugged, or the Mac waking."
  }

  static var gammaWatchSuspended: LocalizedStringKey {
    "\(AppInfo.productName) has stopped watching for these until it is relaunched."
  }

  // MARK: - Reported Capabilities

  /// The caption side of `DiagnosticsCopy.capabilityAnswer`, which is why it
  /// takes the same three facts plus one the value does not need. Four states,
  /// and the HDR arm is the one skip that is not "hasn't got round to it yet":
  /// DDC is dead under HDR, so `CapabilityProbePolicy` refuses to probe and
  /// refuses to cache a verdict that would outlive its cause.
  static func capabilityAnswer(
    hasDescription: Bool, parsedACommandList: Bool, wasAsked: Bool, isHDREngaged: Bool
  ) -> LocalizedStringKey {
    if hasDescription {
      if !parsedACommandList {
        return "The display's description is shown below exactly as it arrived. It is unbalanced, carries no command list, or lists no codes, so nothing on this page claims what the display supports."
      }
      return "\(AppInfo.productName) asks each display to describe itself once after it is plugged in."
    }
    if wasAsked {
      // "Once this session" would be wider than the cache's real window:
      // `AppModel.performRefresh` evicts both the volume verdict and the
      // capability string for any display that is no longer live, because a
      // replug hands out a fresh `IOAVService` and an old answer is not evidence
      // about the new wire. So the window is the plug, not the session, and
      // unplugging re-asks.
      return "\(AppInfo.productName) asked once since this display was plugged in. Either the display sent nothing or it sent something that could not be put back together. From here the two look the same."
    }
    if isHDREngaged {
      return "\(AppInfo.productName) does not ask a display that is in HDR mode (hardware commands do not reach it) and will ask once HDR turns off."
    }
    return "\(AppInfo.productName) asks each display to describe itself once after it is plugged in. It has not asked this one yet."
  }

  static var capabilityRequestHelp: LocalizedStringKey {
    "VCP 0xF3 · MCCS capabilities request"
  }

  static var advertisedCommands: LocalizedStringKey {
    "\(AppInfo.productName) uses four commands: brightness, contrast, volume and mute. A display can advertise a command it ignores, or ignore one it advertises."
  }

  /// Collapsed, and a plain block of text rather than a list with affordances
  /// (R12): it is the wire's own words, kept for copying into a bug report, not
  /// a thing to browse.
  static var rawDescriptionDisclosure: LocalizedStringKey {
    "What the display sent, exactly"
  }

  static func readEvidence(
    _ evidence: DDCReadEvidence, isSafeMode: Bool, readsBackAtStartup: Bool
  ) -> LocalizedStringKey {
    switch evidence {
    case .notAttempted:
      notAttempted(isSafeMode: isSafeMode, readsBackAtStartup: readsBackAtStartup)
    case .answered:
      "The values shown elsewhere in this window come from the display itself."
    case .allZeros, .noReply:
      "The values shown elsewhere in this window are what \(AppInfo.productName) last wrote, not what the display reports."
    }
  }

  /// An earlier sentence, "startup behaviour for THIS DISPLAY is not set to read
  /// values back", asserted a cause it could not know, at a scope that does not
  /// exist. `startupAction` is app-level (`DisplayPrefs` reads it straight off
  /// the `startupAction` default, unkeyed), and `.notAttempted` also arises from
  /// Safe Mode, from all three commands being turned off for this display, and
  /// simply from the first read not having happened yet.
  ///
  /// So the two causes that ARE knowable from here are named, in the order that
  /// matches how they mask each other: under Safe Mode the `startupAction`
  /// getter reports `.doNothing` regardless of what is stored (D11), so reading
  /// it first would report the pref rather than the session. Everything else
  /// falls through to a sentence that states the consequence and claims no
  /// cause.
  static func notAttempted(isSafeMode: Bool, readsBackAtStartup: Bool) -> LocalizedStringKey {
    if isSafeMode {
      return "Safe Mode is on for this session, so nothing is read back from any display. The values shown elsewhere in this window come from your saved settings, not from the display."
    }
    if !readsBackAtStartup {
      return "\(AppInfo.productName) is not set to read values back from displays at startup. The values shown elsewhere in this window come from your saved settings, not from the display."
    }
    return "Nothing has been read from this display yet. The values shown elsewhere in this window come from your saved settings, not from the display."
  }

  // MARK: - Availability
  //
  // The VCP codes are tooltips, not row text: they are what a bug report needs
  // and what nobody else should have to read.

  static var volumeHelp: LocalizedStringKey { "VCP 0x62" }
  static var contrastHelp: LocalizedStringKey { "VCP 0x12" }
  static var muteHelp: LocalizedStringKey { "VCP 0x8D" }

  // MARK: - Right Now

  /// `hdrMode` is the POLICY and `isHDREngaged` the STATE, so the two
  /// disagreeing is not a bug: it is somebody having turned HDR on in System
  /// Settings, and it explains why the hardware commands stopped.
  static var hdrTurnedOnOutside: LocalizedStringKey {
    "HDR was turned on outside \(AppInfo.productName). Hardware commands do not reach a display while it is in HDR mode."
  }

  /// The epoch gate stops every submit, native and DDC alike, but the built-in
  /// has no hardware command to stop, so calling its row "Hardware commands"
  /// would name a wire it does not have.
  static func writeGateLabel(isBuiltIn: Bool) -> LocalizedStringKey {
    isBuiltIn ? "Brightness commands" : "Hardware commands"
  }

  /// One of the three safe-mode summaries, and the words are `SafeModeCopy`'s
  /// (#147): this row named three suppressions while the app performed four.
  /// `String` rather than `LocalizedStringKey` for the same reason the rest of
  /// `DiagnosticsCopy` is: the shared list lives in Kit, which imports no
  /// SwiftUI. The call site takes it through `SettingsCaption(verbatim:)`.
  static var safeMode: String {
    SafeModeCopy.diagnosticsRow(app: AppInfo.productName)
  }

  /// Attached only to the empty case, which is the state a single-display rig is
  /// actually in: the not-running sibling gives its reason in the value, and a
  /// bare "None" gave none at all. It states the gates rather than picking one:
  /// which of them is holding is not visible from here, and all of them are
  /// necessary conditions.
  static var watchedKeys: LocalizedStringKey {
    "\(AppInfo.productName) watches a family of keys only while something can act on it: brightness while an external display is connected, volume while a display it controls can take a volume command and the sound output leaves those keys to it, and either one only while that family is set to use the media keys. Keys it does not watch go straight to macOS."
  }

  static var accessibilityMissing: LocalizedStringKey {
    "\(AppInfo.productName) does not have Accessibility permission, so the media keys it is set to use are not reaching it."
  }

  // MARK: - Actions

  static var reportScope: LocalizedStringKey {
    "Covers every display. The report doesn't include serial numbers."
  }

  /// `NavigationRow` takes plain strings, so these are not `LocalizedStringKey`.
  static let controlMethodTitle = "Hardware control not responding?"
  static let controlMethodValue = "Control Method"

  static var copyReport: LocalizedStringKey { "Copy Report" }
  static var saveReport: LocalizedStringKey { "Save Report…" }
  static var copied: LocalizedStringKey { "Copied" }
  static var copiedAccessibly: LocalizedStringKey { "Report copied to the clipboard" }
  static var saveFailed: LocalizedStringKey { "The report could not be saved." }
  static var acknowledge: LocalizedStringKey { "OK" }
  static var reportFileName: String { "\(AppInfo.productName) Diagnostics.txt" }
}
