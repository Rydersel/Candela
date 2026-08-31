import CandelaKit
import SwiftUI

/// The half of the diagnostics page's copy that cannot leave the app target.
///
/// The split with `DiagnosticsCopy` (CandelaKit) is the one `PanelHealthCopy`
/// and `OledCareCopy` already draw: a sentence derived from values returns
/// `String` and gets a test, and a `LocalizedStringKey` cannot, because
/// CandelaKit imports no SwiftUI. Values in Kit, captions here.
///
/// Several captions are load-bearing: the one under "Reading values back" names
/// only the causes that are knowable, and the one under "Capability request"
/// tells four states apart. Read each comment before rewording it.
///
/// `LocalizedStringKey` is not `Sendable`, so these are computed `static var`s.
enum DiagnosticsPageCopy {

  // MARK: - This Display

  static var connection: LocalizedStringKey {
    "Which cable this display is connected through."
  }

  /// Shown only once the facts have arrived: raised earlier it would claim the
  /// display reported no serial before it reported anything at all.
  static var noSerialNumber: LocalizedStringKey {
    "This display reports no serial number. Two identical units would share one set of saved settings."
  }



  /// Has to survive the two keys being IDENTICAL, which is what the built-in
  /// shows: text implying a distinction the user cannot see is worse than none.
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
    case let .softwareOnly(_, .ddcUnresponsive, dimsBelow):
      "This display stopped answering brightness commands, so \(AppInfo.productName) dims it in software instead. Only the part of the slider below \(SliderSnap.percentText(dimsBelow)) moves anything. It goes back to hardware commands when the display answers again, which is rechecked when your displays are reconfigured, when the Mac wakes, and when HDR is switched off."
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Combined dimming is off for this display and its hardware brightness command is turned off, so nothing is left to carry the value."
    case .unavailable(.ddcUnresponsiveWithNoSoftwareLeg):
      "This display stopped answering brightness commands, and dimming is set to hand off to software at a point with no software range below it, so nothing is left to carry the value."
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

  /// The caption side of `DiagnosticsCopy.capabilityAnswer`, so it takes the same
  /// facts plus one the value does not need. The HDR arm is the one skip that is
  /// not "hasn't got round to it yet": DDC is dead under HDR, so
  /// `CapabilityProbePolicy` refuses to probe and refuses to cache a verdict.
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
      // `AppModel.performRefresh` evicts the volume verdict and the capability
      // string for any display no longer live, because a replug hands out a fresh
      // `IOAVService`. The window is the plug, not the session.
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

  /// Collapsed, and plain text rather than a browsable list (R12): it is the
  /// wire's own words, kept for pasting into a bug report.
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

  /// Names only the two causes knowable from here. `startupAction` is app-level,
  /// not per-display, and `.notAttempted` also arises from Safe Mode, from all
  /// three commands being turned off, or from the first read not having happened.
  ///
  /// Safe Mode is checked first because under it the `startupAction` getter
  /// reports `.doNothing` whatever is stored (D11), so reading the pref first
  /// would report the pref rather than the session. Everything else falls through
  /// to a sentence that claims no cause.
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

  /// `hdrMode` is the POLICY and `isHDREngaged` the STATE, so the two disagreeing
  /// is not a bug: somebody turned HDR on in System Settings, which is why the
  /// hardware commands stopped.
  static var hdrTurnedOnOutside: LocalizedStringKey {
    "HDR was turned on outside \(AppInfo.productName). Hardware commands do not reach a display while it is in HDR mode."
  }

  /// The epoch gate stops every submit, but the built-in has no hardware command
  /// to stop, so calling its row "Hardware commands" would name a missing wire.
  static func writeGateLabel(isBuiltIn: Bool) -> LocalizedStringKey {
    isBuiltIn ? "Brightness commands" : "Hardware commands"
  }

  /// `SafeModeCopy`'s words, so this row cannot drift from what the app actually
  /// suppresses. `String` rather than `LocalizedStringKey` because the shared list
  /// lives in Kit; the call site takes it through `SettingsCaption(verbatim:)`.
  static var safeMode: String {
    SafeModeCopy.diagnosticsRow(app: AppInfo.productName)
  }

  /// Attached whenever a family is missing, partial states included. It states
  /// the gates rather than picking one: which is holding is not visible from
  /// here, and all of them are necessary.
  ///
  /// ONE consequence sentence (SO15); the conditions are a list on screen
  /// (`requirements` below), with the prose kept as each row's accessibility
  /// label (SO16).
  static var watchedKeys: LocalizedStringKey {
    "\(AppInfo.productName) watches a family of keys only while a press could land on something, and keys it does not watch go straight to macOS."
  }

  /// What each family needs before its keys are watched. The visible half states
  /// only what holds in every mode; the mode-dependent corners live in the spoken
  /// half (SO16), and the Keyboard pane states them in full.
  static var keyWatchRequirements: [(title: String, needs: String, spoken: String)] {
    [
      (
        "Brightness keys",
        "An external display",
        "The brightness keys are watched while an external display is connected and they are set to use the media keys. With only the built-in display, macOS handles them."
      ),
      (
        "Volume keys",
        "A display that takes a volume command",
        "The volume keys are watched while a display they would reach takes a volume command and they are set to use the media keys. Which displays they would reach follows the volume-key target: set to the display matching the audio output device, only a matched display counts. They also go to macOS whenever the current output device has a volume control of its own, and they stay here while macOS reports no output device at all."
      ),
      (
        "Mute key",
        "A display that takes the command it sends",
        "The mute key follows the same rule on the command it sends, which is the display's own mute command when that is switched on and its volume command otherwise. A display can take one and refuse the other, so the mute key and the volume keys are watched separately."
      ),
    ]
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
