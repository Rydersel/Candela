import Foundation
import Testing
@testable import CandelaKit

@Suite("Per-display prefs")
struct DisplayPrefsTests {
  /// A throwaway in-memory store per test, so nothing touches the user's defaults.
  private func withSuite(_ body: (UserDefaults) -> Void) {
    let defaults = InMemoryDefaults()
    body(defaults)
  }

  @Test func defaultsOnAnEmptySuite() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "AAAA-BBBB")
      #expect(prefs.hdrMode == .off)
      #expect(prefs.forceSoftware == false)
      #expect(prefs.avoidGamma == false)
      #expect(prefs.combinedSwitchingPoint == 0)
    }
  }

  /// The escape hatch defaults ON, so absence must read as guarded: the one bug
  /// that would make the hatch a hazard.
  @Test func theWireTimingGuardIsOnUntilExplicitlyTurnedOff() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "app")
      #expect(prefs.wireTimingGuard)

      prefs.wireTimingGuard = false
      #expect(prefs.wireTimingGuard == false)
      // App-level: stored unsuffixed, so every display sees the same answer.
      #expect(defaults.object(forKey: "wireTimingGuard") as? Bool == false)

      prefs.wireTimingGuard = true
      #expect(prefs.wireTimingGuard)
    }
  }

  /// A `defaults write` is the only way in, and it has to reach the same
  /// accessor the engine reads.
  @Test func theWireTimingGuardHonoursAnExternallyWrittenKey() {
    withSuite { defaults in
      defaults.set(false, forKey: "wireTimingGuard")
      #expect(DisplayPrefs(defaults: defaults, persistenceKey: "app").wireTimingGuard == false)
      // Read through a per-display instance too: it is not display-scoped.
      #expect(DisplayPrefs(defaults: defaults, persistenceKey: "AAAA").wireTimingGuard == false)
    }
  }

  /// `defaults write … NO` stores a STRING. An escape hatch that ignores the
  /// commonest spelling of itself is worse than none: the user believes the guard
  /// is off while it is still on.
  @Test func theWireTimingGuardAcceptsEveryFalseSpellingDefaultsWriteProduces() {
    for stored in ["NO", "no", "false", "0"] as [Any] + [0, false] {
      withSuite { defaults in
        defaults.set(stored, forKey: "wireTimingGuard")
        #expect(
          DisplayPrefs(defaults: defaults, persistenceKey: "app").wireTimingGuard == false,
          "\(stored) should read as guard-off")
      }
    }
    // And the true spellings stay guarded.
    for stored in ["YES", "1"] as [Any] + [1, true] {
      withSuite { defaults in
        defaults.set(stored, forKey: "wireTimingGuard")
        #expect(DisplayPrefs(defaults: defaults, persistenceKey: "app").wireTimingGuard)
      }
    }
  }

  @Test func hdrModeRoundTrips() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.hdrMode = .alwaysOn
      #expect(prefs.hdrMode == .alwaysOn)
      prefs.hdrMode = .off
      #expect(prefs.hdrMode == .off)
    }
  }

  @Test func boolPrefsRoundTrip() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.forceSoftware = true
      prefs.avoidGamma = true
      #expect(prefs.forceSoftware == true)
      #expect(prefs.avoidGamma == true)
      prefs.forceSoftware = false
      prefs.avoidGamma = false
      #expect(prefs.forceSoftware == false)
      #expect(prefs.avoidGamma == false)
    }
  }

  @Test func combinedSwitchingPointRoundTrips() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.combinedSwitchingPoint = -3
      #expect(prefs.combinedSwitchingPoint == -3)
      prefs.combinedSwitchingPoint = 5
      #expect(prefs.combinedSwitchingPoint == 5)
    }
  }

  @Test func combinedSwitchingPointClampsToTheSliderRange() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.combinedSwitchingPoint = 9
      #expect(prefs.combinedSwitchingPoint == 7)
      prefs.combinedSwitchingPoint = -12
      #expect(prefs.combinedSwitchingPoint == -8)
    }
  }

  @Test func keysAreSuffixedWithThePersistenceKey() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "AAAA-BBBB")
      prefs.hdrMode = .alwaysOn
      prefs.forceSoftware = true
      prefs.avoidGamma = true
      prefs.combinedSwitchingPoint = 3
      #expect(defaults.object(forKey: "hdrMode.AAAA-BBBB") as? Int == HDRMode.alwaysOn.rawValue)
      #expect(defaults.object(forKey: "forceSw.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "avoidGamma.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "combinedSwitchingPoint.AAAA-BBBB") as? Int == 3)
    }
  }

  @Test func displaysWithDifferentKeysDoNotShareValues() {
    withSuite { defaults in
      let first = DisplayPrefs(defaults: defaults, persistenceKey: "one")
      let second = DisplayPrefs(defaults: defaults, persistenceKey: "two")
      first.hdrMode = .alwaysOn
      first.combinedSwitchingPoint = 4
      #expect(second.hdrMode == .off)
      #expect(second.combinedSwitchingPoint == 0)
    }
  }

  @Test func unknownStoredHDRModeFallsBackToOff() {
    withSuite { defaults in
      defaults.set(42, forKey: "hdrMode.pk")
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.hdrMode == .off)
    }
  }

  /// HDR Boost was removed 2026-07-30; its raw value 1 is retired, so a display
  /// that stored it decodes to `.off` through the unknown-value fallback.
  @Test func storedBoostRawValueMigratesToOff() {
    withSuite { defaults in
      defaults.set(1, forKey: "hdrMode.pk")
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.hdrMode == .off)
    }
  }

  /// The counterpart the migration has to preserve: raw values stayed stable,
  /// so a stored `alwaysOn` survives the removal untouched.
  @Test func storedAlwaysOnRawValueSurvivesTheBoostRemoval() {
    withSuite { defaults in
      defaults.set(2, forKey: "hdrMode.pk")
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.hdrMode == .alwaysOn)
    }
  }

  @Test func hdrModeIsExhaustivelyEnumerated() {
    #expect(HDRMode.allCases == [.off, .alwaysOn])
    #expect(HDRMode.off.rawValue == 0)
    #expect(HDRMode.alwaysOn.rawValue == 2) // 1 is the retired `boost`
  }

  @Test func storedSwitchingPointFeedsTheSwitchingValue() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint) == 0.5)
      prefs.combinedSwitchingPoint = -8
      #expect(DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint) == 0.0)
    }
  }

  // MARK: - M4 tuning schema

  @Test func tuningDefaultsAreTheForkZeroValues() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      let tuning = prefs.tuning(for: .volume)
      #expect(tuning.unavailableDDC == false)
      #expect(tuning.minDDCOverride == 0)
      #expect(tuning.maxDDCOverride == 0)
      #expect(tuning.curveIndex == 0)
      #expect(tuning.curveMultiplier == 1.0) // 0 (unset) is linear
      #expect(tuning.invert == false)
      #expect(tuning.remapCodes.isEmpty)
    }
  }

  @Test func tuningKeysCarryTheCommandComponentAndPersistenceKey() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "AAAA-BBBB")
      var tuning = prefs.tuning(for: .volume)
      tuning.unavailableDDC = true
      tuning.minDDCOverride = 10
      tuning.maxDDCOverride = 90
      tuning.curveIndex = 7
      tuning.invert = true
      tuning.remapCodes = [0x10, 0x2F]
      prefs.setTuning(tuning, for: .volume)
      #expect(defaults.object(forKey: "unavailableDDC.volume.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "minDDCOverride.volume.AAAA-BBBB") as? Int == 10)
      #expect(defaults.object(forKey: "maxDDCOverride.volume.AAAA-BBBB") as? Int == 90)
      #expect(defaults.object(forKey: "curveDDC.volume.AAAA-BBBB") as? Int == 7)
      #expect(defaults.object(forKey: "invertDDC.volume.AAAA-BBBB") as? Bool == true)
      #expect(defaults.string(forKey: "remapDDC.volume.AAAA-BBBB") == "10, 2f")
      // Commands don't bleed into each other
      #expect(prefs.tuning(for: .contrast).minDDCOverride == 0)
      #expect(prefs.tuning(for: .brightness).invert == false)
    }
  }

  @Test func remapCodesParseTheForkFormat() {
    // Fork getRemapControlCodes: comma-separated hex, whitespace trimmed,
    // empty/zero/non-hex tokens dropped.
    #expect(DisplayPrefs.parseRemapCodes("10, 2f") == [0x10, 0x2F])
    #expect(DisplayPrefs.parseRemapCodes("2F") == [0x2F])
    #expect(DisplayPrefs.parseRemapCodes("00, 10") == [0x10]) // 0x00 dropped
    #expect(DisplayPrefs.parseRemapCodes("zz, , 12") == [0x12])
    #expect(DisplayPrefs.parseRemapCodes("") == [])
  }

  @Test func effectiveMaxResolvesLikeTheFork() {
    var tuning = CommandTuning(
      unavailableDDC: false, minDDCOverride: 0, maxDDCOverride: 0,
      curveIndex: 0, invert: false, remapCodes: []
    )
    #expect(tuning.effectiveMaxDDC(readMax: nil) == 100) // assumed max
    #expect(tuning.effectiveMaxDDC(readMax: 255) == 100) // clamped to DDC_MAX_DETECT_LIMIT
    #expect(tuning.effectiveMaxDDC(readMax: 60) == 60)
    tuning.maxDDCOverride = 80
    #expect(tuning.effectiveMaxDDC(readMax: 60) == 80) // override wins only when > minOverride
    tuning.minDDCOverride = 90
    #expect(tuning.effectiveMaxDDC(readMax: 60) == 60) // 80 !> 90 → override ignored
  }

  @Test func perDisplayAudioPrefsRoundTripWithExactKeys() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "AAAA-BBBB")
      #expect(prefs.enableMuteUnmute == false)
      #expect(prefs.muted == false)
      #expect(prefs.audioDeviceNameOverride == "")
      #expect(prefs.hideVolumeSlider == false)
      #expect(prefs.audioSinkOverride == .auto)
      #expect(prefs.isDisabled == false)
      #expect(prefs.hideOsd == false)
      prefs.enableMuteUnmute = true
      prefs.muted = true
      prefs.audioDeviceNameOverride = "MAG 341C"
      prefs.hideVolumeSlider = true
      prefs.audioSinkOverride = .forcePresent
      prefs.isDisabled = true
      prefs.hideOsd = true
      #expect(defaults.object(forKey: "enableMuteUnmute.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "muted.AAAA-BBBB") as? Bool == true)
      #expect(defaults.string(forKey: "audioDeviceNameOverride.AAAA-BBBB") == "MAG 341C")
      #expect(defaults.object(forKey: "hideVolumeSlider.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "audioSinkOverride.AAAA-BBBB") as? Int == 2)
      #expect(defaults.object(forKey: "isDisabled.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "hideOsd.AAAA-BBBB") as? Bool == true)
    }
  }

  @Test func audioSinkOverrideRoundTripsBothWaysAndFallsBackToAuto() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.audioSinkOverride = .forceNone
      #expect(prefs.audioSinkOverride == .forceNone)
      prefs.audioSinkOverride = .forcePresent
      #expect(prefs.audioSinkOverride == .forcePresent)
      // A stray raw must not strand the slider in a state with no UI to undo
      // it — unknown means "trust detection", never "stay disabled".
      defaults.set(99, forKey: "audioSinkOverride.pk")
      #expect(prefs.audioSinkOverride == .auto)
    }
  }

  @Test func pollingTriesMapModesToTheForkCounts() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.pollingMode == .normal) // unset raw 0
      #expect(prefs.pollingTries == 5)
      prefs.pollingMode = .none
      #expect(prefs.pollingTries == 0)
      prefs.pollingMode = .minimal
      #expect(prefs.pollingTries == 1)
      prefs.pollingMode = .heavy
      #expect(prefs.pollingTries == 20)
      prefs.pollingMode = .custom
      prefs.pollingCount = 12
      #expect(prefs.pollingTries == 12)
      #expect(defaults.object(forKey: "pollingMode.pk") as? Int == PollingMode.custom.rawValue)
      #expect(defaults.object(forKey: "pollingCount.pk") as? Int == 12)
      prefs.pollingCount = -3
      #expect(prefs.pollingTries == 0) // never a negative try count
      defaults.set(99, forKey: "pollingMode.pk")
      #expect(prefs.pollingMode == .normal) // unknown raw falls back to the default
    }
  }

  @Test func appLevelM4PrefsAreUnsuffixed() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.showContrast == false) // fork parity default
      #expect(prefs.startupAction == .doNothing) // raw 0
      #expect(prefs.multiKeyboardVolume == .mouse) // raw 0
      prefs.showContrast = true
      prefs.startupAction = .write
      prefs.multiKeyboardVolume = .audioDeviceNameMatching
      #expect(defaults.object(forKey: "showContrast") as? Bool == true)
      #expect(defaults.object(forKey: "startupAction") as? Int == 1)
      #expect(defaults.object(forKey: "multiKeyboardVolume") as? Int == 2)
      defaults.set(42, forKey: "startupAction")
      #expect(prefs.startupAction == .doNothing) // unknown raw → safe default
      defaults.set(42, forKey: "multiKeyboardVolume")
      #expect(prefs.multiKeyboardVolume == .mouse)
    }
  }

  // These raws compose on-disk key strings and stored values, so a rename or
  // renumber is a silent migration.
  @Test func persistedRawValuesNeverDrift() {
    #expect(DDCCommand.allCases.map(\.rawValue) == ["brightness", "volume", "contrast"])
    #expect(PollingMode.allCases.map(\.rawValue) == [-2, -1, 0, 1, 2])
    #expect(StartupAction.allCases.map(\.rawValue) == [0, 1, 2])
    #expect(MultiKeyboardVolume.allCases.map(\.rawValue) == [0, 1, 2])
  }

  @Test func commandTuningRoundTripsWholeStruct() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      let tuning = CommandTuning(
        unavailableDDC: true, minDDCOverride: 5, maxDDCOverride: 90,
        curveIndex: 7, invert: true, remapCodes: [0x10, 0x2F]
      )
      prefs.setTuning(tuning, for: .contrast)
      #expect(prefs.tuning(for: .contrast) == tuning)
    }
  }

  // MARK: - M5 settings schema

  @Test func m5PerDisplayKeysComposeAndDefault() {
    let d = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "PK")
    #expect(prefs.friendlyName == "")
    #expect(!prefs.hideDisplay)
    #expect(!prefs.longerDelay)
    prefs.friendlyName = "Desk"
    prefs.hideDisplay = true
    prefs.longerDelay = true
    // 1. setter key strings
    #expect(d.string(forKey: "friendlyName.PK") == "Desk")
    #expect(d.bool(forKey: "hideDisplay.PK"))
    #expect(d.bool(forKey: "longerDelay.PK"))
    // 2. the getter reads the SAME key
    #expect(prefs.friendlyName == "Desk")
    #expect(prefs.hideDisplay)
    #expect(prefs.longerDelay)
    // 3. a fresh instance sees them (no in-object memoization)
    let reread = DisplayPrefs(defaults: d, persistenceKey: "PK")
    #expect(reread.friendlyName == "Desk")
    #expect(reread.hideDisplay)
    #expect(reread.longerDelay)
    // and they do not bleed across displays
    let other = DisplayPrefs(defaults: d, persistenceKey: "OTHER")
    #expect(other.friendlyName == "")
    #expect(!other.hideDisplay)
  }

  @Test func m5AppLevelKeysAreUnsuffixedWithForkDefaults() {
    let d = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "irrelevant")
    #expect(prefs.menuIcon == .show)
    #expect(prefs.menuItemStyle == .icon)
    #expect(prefs.keyboardBrightness == .media)
    #expect(prefs.keyboardVolume == .media)
    #expect(prefs.multiKeyboardBrightness == .mouse)
    #expect(!prefs.showTickMarks)
    #expect(!prefs.enableSliderSnap)
    #expect(!prefs.enableSliderPercent)
    #expect(!prefs.hideBuiltInDisplay)

    prefs.menuIcon = .externalOnly
    prefs.menuItemStyle = .text
    prefs.keyboardBrightness = .disabled
    prefs.keyboardVolume = .custom
    prefs.multiKeyboardBrightness = .focusInsteadOfMouse
    prefs.showTickMarks = true
    prefs.enableSliderSnap = true
    prefs.enableSliderPercent = true
    prefs.hideBuiltInDisplay = true

    // 1. setter keys — unsuffixed, raw values as stored
    #expect(d.integer(forKey: "menuIcon") == 3)
    #expect(d.integer(forKey: "menuItemStyle") == 1)
    #expect(d.integer(forKey: "keyboardBrightness") == 3)
    #expect(d.integer(forKey: "keyboardVolume") == 1)
    #expect(d.integer(forKey: "multiKeyboardBrightness") == 2)
    #expect(d.bool(forKey: "showTickMarks"))
    #expect(d.bool(forKey: "enableSliderSnap"))
    #expect(d.bool(forKey: "enableSliderPercent"))
    #expect(d.bool(forKey: "hideBuiltInDisplay"))
    // no per-display suffix leaked in
    #expect(d.object(forKey: "menuIcon.irrelevant") == nil)

    // 2 + 3. getters read the same keys, from this instance and a fresh one
    let reread = DisplayPrefs(defaults: d, persistenceKey: "different-display")
    for p in [prefs, reread] {
      #expect(p.menuIcon == .externalOnly)
      #expect(p.menuItemStyle == .text)
      #expect(p.keyboardBrightness == .disabled)
      #expect(p.keyboardVolume == .custom)
      #expect(p.multiKeyboardBrightness == .focusInsteadOfMouse)
      #expect(p.showTickMarks)
      #expect(p.enableSliderSnap)
      #expect(p.enableSliderPercent)
      #expect(p.hideBuiltInDisplay)
    }
  }

  @Test func hudPositionsAreAppLevelAndDefaultToTheShippedTopCenter() {
    let d = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "irrelevant")
    // The shipped default is top center (KMR amendment).
    #expect(prefs.hudPositionBrightness == .topCenter)
    #expect(prefs.hudPositionVolume == .topCenter)

    // Top right stores raw 0, indistinguishable from absent through
    // `integer(forKey:)`: the accessor reads key PRESENCE, so an explicit
    // top-right choice survives the default moving away from it.
    prefs.hudPositionBrightness = .topRight
    #expect(prefs.hudPositionBrightness == .topRight)

    prefs.hudPositionBrightness = .topLeft
    prefs.hudPositionVolume = .topCenter
    #expect(d.integer(forKey: "hudPositionBrightness") == 1)
    #expect(d.integer(forKey: "hudPositionVolume") == 2)
    // App-level: no per-display suffix, so one choice covers every display.
    #expect(d.object(forKey: "hudPositionBrightness.irrelevant") == nil)

    // The two are genuinely independent, which is the whole point of shipping
    // two keys: setting one must not move the other.
    let reread = DisplayPrefs(defaults: d, persistenceKey: "another-display")
    #expect(reread.hudPositionBrightness == .topLeft)
    #expect(reread.hudPositionVolume == .topCenter)
  }

  @Test func unknownStoredRawValuesFallBackRatherThanTrap() {
    // Raw 0 is a valid case for most of these enums, so the default-value assertions
    // above never reach the `?? fallback`. D13's downgrade story rests on it.
    let d = InMemoryDefaults()
    for key in ["menuIcon", "menuItemStyle", "keyboardBrightness",
                "keyboardVolume", "multiKeyboardBrightness",
                "hudPositionBrightness", "hudPositionVolume"] {
      d.set(99, forKey: key)
    }
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "x")
    #expect(prefs.menuIcon == .show)
    #expect(prefs.menuItemStyle == .icon)
    #expect(prefs.keyboardBrightness == .media)
    #expect(prefs.keyboardVolume == .media)
    #expect(prefs.multiKeyboardBrightness == .mouse)
    // Raw 0 is a valid case for these two as well, so only an out-of-range
    // value reaches their fallback: the shipped default, top center.
    #expect(prefs.hudPositionBrightness == .topCenter)
    #expect(prefs.hudPositionVolume == .topCenter)
  }

  @Test func hudStyleIsAppLevelDefaultsToSystemAndFallsBackOnUnknownRaw() {
    let d = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "irrelevant")
    // Raw 0 IS the shipped default, so absent and default agree and the plain
    // integer read is correct here, unlike the position keys.
    #expect(prefs.hudStyle == .system)

    prefs.hudStyle = .segments
    #expect(d.integer(forKey: "hudStyle") == 1)
    // App-level: no per-display suffix.
    #expect(d.object(forKey: "hudStyle.irrelevant") == nil)
    let reread = DisplayPrefs(defaults: d, persistenceKey: "another-display")
    #expect(reread.hudStyle == .segments)

    d.set(99, forKey: "hudStyle")
    #expect(prefs.hudStyle == .system)
  }

  @Test func foldedRawKeysKeepTheirExactKeyStrings() {
    let d = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "PK")
    #expect(!prefs.enableBrightnessSync)
    #expect(!prefs.useFineScaleBrightness)
    #expect(!prefs.useFineScaleVolume)
    #expect(!prefs.disableAltBrightnessKeys)
    prefs.enableBrightnessSync = true
    prefs.useFineScaleBrightness = true
    prefs.useFineScaleVolume = true
    prefs.disableAltBrightnessKeys = true
    // These keys are read by name in `AppModel.tapConfig`, the tap's
    // `KeyRouterConfig` and the poller fan-out, so drift silently unhooks the engine.
    #expect(d.bool(forKey: "enableBrightnessSync"))
    #expect(d.bool(forKey: "useFineScaleBrightness"))
    #expect(d.bool(forKey: "useFineScaleVolume"))
    #expect(d.bool(forKey: "disableAltBrightnessKeys"))
    // 2 + 3. getters agree, from this instance and a fresh one
    let reread = DisplayPrefs(defaults: d, persistenceKey: "PK")
    for p in [prefs, reread] {
      #expect(p.enableBrightnessSync)
      #expect(p.useFineScaleBrightness)
      #expect(p.useFineScaleVolume)
      #expect(p.disableAltBrightnessKeys)
    }
  }

  @Test func positiveAccessorsInvertAtTheBindingLayerOnly() {
    let d = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: d, persistenceKey: "PK")
    // D1: unset reads as the fork default (ON), stored key stays inverted.
    #expect(prefs.combinedBrightness)
    #expect(prefs.interceptAlternateBrightnessKeys)

    prefs.combinedBrightness = false
    prefs.interceptAlternateBrightnessKeys = false
    #expect(d.bool(forKey: "disableCombinedBrightness"))
    #expect(d.bool(forKey: "disableAltBrightnessKeys"))
    #expect(!prefs.combinedBrightness) // read back through the positive
    #expect(!prefs.interceptAlternateBrightnessKeys)
    #expect(prefs.disableCombinedBrightness) // and through the negative
    #expect(prefs.disableAltBrightnessKeys)

    // The `= true` leg: the inverted key must be cleared, not just left alone.
    prefs.combinedBrightness = true
    prefs.interceptAlternateBrightnessKeys = true
    #expect(!d.bool(forKey: "disableCombinedBrightness"))
    #expect(!d.bool(forKey: "disableAltBrightnessKeys"))
    let reread = DisplayPrefs(defaults: d, persistenceKey: "PK")
    #expect(reread.combinedBrightness)
    #expect(reread.interceptAlternateBrightnessKeys)
  }

  @Test func m5RawValuesNeverDrift() {
    // Per case, not per multiset: `case show = 0, hide = 1, sliderOnly = 2` also
    // satisfies `allCases.map(\.rawValue) == [0, 1, 2, 3]`, and under D22 the
    // case-to-value binding is the shipped on-disk schema.
    #expect(MenuIcon.show.rawValue == 0)
    #expect(MenuIcon.sliderOnly.rawValue == 1)
    #expect(MenuIcon.hide.rawValue == 2)
    #expect(MenuIcon.externalOnly.rawValue == 3)
    #expect(MenuIcon.allCases.count == 4)

    #expect(MenuItemStyle.icon.rawValue == 0)
    #expect(MenuItemStyle.text.rawValue == 1)
    #expect(MenuItemStyle.hide.rawValue == 2)
    #expect(MenuItemStyle.allCases.count == 3)

    #expect(KeyMode.media.rawValue == 0)
    #expect(KeyMode.custom.rawValue == 1)
    #expect(KeyMode.both.rawValue == 2)
    #expect(KeyMode.disabled.rawValue == 3)
    #expect(KeyMode.allCases.count == 4)

    #expect(MultiKeyboardBrightness.mouse.rawValue == 0)
    #expect(MultiKeyboardBrightness.allScreens.rawValue == 1)
    #expect(MultiKeyboardBrightness.focusInsteadOfMouse.rawValue == 2)
    #expect(MultiKeyboardBrightness.allCases.count == 3)
  }

  @Test func safeModeGatesStartupTrafficWithoutTouchingStoredPrefs() {
    // D11: session-only hardware gate. One flag passed at construction, never a
    // global and never a UserDefaults lookup buried in the engine.
    let d = InMemoryDefaults()
    let normal = DisplayPrefs(defaults: d, persistenceKey: "app")
    normal.startupAction = .write
    normal.pollingMode = .heavy
    let safe = DisplayPrefs(defaults: d, persistenceKey: "app", safeMode: true)
    #expect(safe.isSafeMode)
    #expect(!normal.isSafeMode)
    #expect(safe.startupAction == .doNothing)
    #expect(safe.pollingTries == 0)
    // Stored values untouched; next normal launch behaves as configured.
    #expect(normal.startupAction == .write)
    #expect(normal.pollingTries == 20)
  }

  @Test func safeModeSettersStillPersistForTheNextNormalSession() {
    // Both gated getters, both directions: a safe-mode write has to survive into
    // the next normal session.
    let d = InMemoryDefaults()
    let normal = DisplayPrefs(defaults: d, persistenceKey: "app")
    let safe = DisplayPrefs(defaults: d, persistenceKey: "app", safeMode: true)
    safe.startupAction = .read
    safe.pollingMode = .heavy
    #expect(normal.startupAction == .read)
    #expect(normal.pollingTries == 20)
    // …while the safe session itself still sees the gate.
    #expect(safe.startupAction == .doNothing)
    #expect(safe.pollingTries == 0)
  }

  // MARK: - First-sight (SO22)

  @Test func anEmptyDomainHasNoStoredValue() {
    withSuite { defaults in
      #expect(!DisplayPrefs.hasAnyStoredValue(forKey: "AAAA-BBBB", defaults: defaults))
    }
  }

  @Test func anySeededKeyCountsAsStored() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "AAAA-BBBB")
      prefs.friendlyName = "Desk"
      #expect(DisplayPrefs.hasAnyStoredValue(forKey: "AAAA-BBBB", defaults: defaults))
      // Suffix match, not substring: another display's domain stays fresh.
      #expect(!DisplayPrefs.hasAnyStoredValue(forKey: "BBBB", defaults: defaults))
      #expect(!DisplayPrefs.hasAnyStoredValue(forKey: "CCCC-DDDD", defaults: defaults))
    }
  }

  // MARK: - OLED care (W3a)

  @Test func oledDefaultsAreTheRecommendedPreset() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.oledCareEnrolled == false)
      #expect(prefs.oledIdleDimSeconds == 300)
      #expect(prefs.oledIdleDimBrightness == 0.5)
      #expect(prefs.oledLockDim == true)
      #expect(prefs.oledBlackoutEnabled == false)
      #expect(prefs.oledBlackoutSeconds == 1200)
      #expect(prefs.oledUnfocusedDimEnabled == false)
      #expect(prefs.oledUnfocusedDimSeconds == 600)
      // Lighter than the idle dim's 0.5, because the level IS the black
      // overlay's opacity — higher is darker — and an unfocused display is
      // still in view.
      #expect(prefs.oledUnfocusedDimBrightness == 0.7)
      #expect(prefs.oledHoursTracking == true)
    }
  }

  // MARK: - OLED care (W3b-1)

  @Test func oledTelemetryDefaultsOffAndWindowObservationDefaultsOn() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      // Telemetry needs Screen Recording; enrolling must never turn it on.
      #expect(prefs.oledTelemetry == false)
      // Observation needs nothing, and is the degraded mode's only source.
      #expect(prefs.oledWindowObservation == true)
      #expect(prefs.oledDetectionDimming == false)
    }
  }

  @Test func oledWindowObservationStoresInverted() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.oledWindowObservation = false
      #expect(defaults.bool(forKey: "oledWindowObservationOff.pk") == true)
      #expect(prefs.oledWindowObservation == false)
      prefs.oledWindowObservation = true
      #expect(prefs.oledWindowObservation == true)
    }
  }

  @Test func resetOledCareRestoresTelemetryDefaults() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.oledTelemetry = true
      prefs.oledWindowObservation = false
      prefs.resetOledCare()
      #expect(prefs.oledTelemetry == false)
      // The inverted key is the one that must be cleared; clearing
      // "oledWindowObservation" would leave this false forever.
      #expect(prefs.oledWindowObservation == true)
      #expect(prefs.oledDetectionDimming == false)
    }
  }

  @Test func w3bOledPrefsArePerDisplay() {
    withSuite { defaults in
      let a = DisplayPrefs(defaults: defaults, persistenceKey: "a")
      let b = DisplayPrefs(defaults: defaults, persistenceKey: "b")
      a.oledTelemetry = true
      a.oledWindowObservation = false
      #expect(b.oledTelemetry == false)
      #expect(b.oledWindowObservation == true)
    }
  }

  @Test func oledPrefsArePerDisplay() {
    withSuite { defaults in
      let a = DisplayPrefs(defaults: defaults, persistenceKey: "a")
      let b = DisplayPrefs(defaults: defaults, persistenceKey: "b")
      a.oledCareEnrolled = true
      a.oledIdleDimSeconds = 120
      #expect(b.oledCareEnrolled == false)
      #expect(b.oledIdleDimSeconds == 300)
    }
  }

  @Test func trueDefaultOledBoolsStoreInverted() {
    // Absence must read as ON, so these two persist under `…Off` keys. A
    // straight `bool(forKey:)` would silently ship lock dimming disabled on
    // every fresh install, and the getter alone cannot show the round trip.
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.oledLockDim = false
      prefs.oledHoursTracking = false
      #expect(prefs.oledLockDim == false)
      #expect(prefs.oledHoursTracking == false)
      #expect(defaults.bool(forKey: "oledLockDimOff.pk"))
      #expect(defaults.bool(forKey: "oledHoursTrackingOff.pk"))
      #expect(defaults.object(forKey: "oledLockDim.pk") == nil)
      prefs.oledLockDim = true
      prefs.oledHoursTracking = true
      #expect(prefs.oledLockDim == true)
      #expect(prefs.oledHoursTracking == true)
    }
  }

  @Test func resetOledCareRemovesTheKeysRatherThanRewritingThem() {
    // Removal, not a write-back of today's numbers: an absent key follows the
    // preset, and a reset that pinned the current values would quietly opt the
    // display out of every later preset change. Checking the accessors alone
    // could not tell the two apart.
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.oledCareEnrolled = true
      prefs.oledIdleDimSeconds = 60
      prefs.oledIdleDimBrightness = 0.9
      prefs.oledLockDim = false
      prefs.oledBlackoutEnabled = true
      prefs.oledBlackoutSeconds = 3000
      prefs.oledUnfocusedDimEnabled = true
      prefs.oledUnfocusedDimSeconds = 900
      prefs.oledUnfocusedDimBrightness = 0.4
      prefs.oledHoursTracking = false
      prefs.oledTelemetry = true
      prefs.oledWindowObservation = false
      prefs.oledDetectionDimming = true
      // Panel hours are not prefs: they live under `PanelHoursTracker`'s own keys
      // and the reset leaves them alone. Written directly because the tracker owns
      // them, and the sweep below needs them to tell "kept" from "wiped".
      defaults.set(3600.0, forKey: "oledPanelSeconds.pk")
      defaults.set(120.0, forKey: "oledStandbySeconds.pk")
      defaults.set(true, forKey: "oledStandbyNoteDismissed.pk")
      // OC20's histogram is the same shape of thing: wear data about the glass,
      // reset by the coordinator alongside the hours tracker, never by this.
      defaults.set([Double](repeating: 1, count: 60), forKey: "oledWearSeconds.pk")
      defaults.set(1, forKey: "oledWearSchema.pk")

      prefs.resetOledCare()

      #expect(prefs.oledCareEnrolled == false)
      #expect(prefs.oledIdleDimSeconds == 300)
      #expect(prefs.oledIdleDimBrightness == 0.5)
      #expect(prefs.oledLockDim == true)
      #expect(prefs.oledBlackoutEnabled == false)
      #expect(prefs.oledBlackoutSeconds == 1200)
      #expect(prefs.oledUnfocusedDimEnabled == false)
      #expect(prefs.oledUnfocusedDimSeconds == 600)
      #expect(prefs.oledUnfocusedDimBrightness == 0.7)
      #expect(prefs.oledHoursTracking == true)
      #expect(prefs.oledTelemetry == false)
      #expect(prefs.oledWindowObservation == true)
      #expect(prefs.oledDetectionDimming == false)

      // The sweep only sees keys something wrote above, so the population is pinned
      // first: a new OLED pref fails here, which is the prompt to add its write.
      let oledPrefNames = PrefName.allCases.filter { $0.rawValue.hasPrefix("oled") }
      #expect(oledPrefNames.count == 13, "a new OLED pref needs a write above")

      // A sweep of the store, not a third hand-written key list: the keys are already
      // enumerated by hand as `PrefName` cases in the reset's fan-out and as strings
      // in `resetOledCare`, where the inverted `…Off` spelling differs. Any such list
      // lets a new pref compile clean and survive the reset; asking the store cannot.
      let keptHoursKeys: Set<String> = [
        "oledPanelSeconds.pk", "oledStandbySeconds.pk", "oledStandbyNoteDismissed.pk",
        "oledWearSeconds.pk", "oledWearSchema.pk",
      ]
      let survivors = defaults.dictionaryRepresentation().keys
        .filter { $0.hasPrefix("oled") && $0.hasSuffix(".pk") && !keptHoursKeys.contains($0) }
        .sorted()
      #expect(survivors.isEmpty, "survived the reset: \(survivors.joined(separator: ", "))")
      // …and the wear data is still there, so "nothing left" above is not
      // passing because the reset wiped everything.
      #expect(keptHoursKeys.allSatisfy { defaults.object(forKey: $0) != nil })
    }
  }

  @Test func resetOledCareLeavesOtherDisplaysAlone() {
    withSuite { defaults in
      let a = DisplayPrefs(defaults: defaults, persistenceKey: "a")
      let b = DisplayPrefs(defaults: defaults, persistenceKey: "b")
      a.oledCareEnrolled = true
      b.oledCareEnrolled = true
      a.resetOledCare()
      #expect(a.oledCareEnrolled == false)
      #expect(b.oledCareEnrolled == true)
    }
  }

  // MARK: - Synthesized sizes (SS4)

  @Test func synthesisIsOffWithNothingStoredUntilItIsAskedFor() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(prefs.offerSyntheticSizes == false)
      #expect(prefs.storedSyntheticSize == nil)
      // Nothing was written by the reads: a display nobody has opted in stays
      // absent from the domain, which is what `hasAnyStoredValue` reads.
      #expect(DisplayPrefs.hasAnyStoredValue(forKey: "pk", defaults: defaults) == false)
    }
  }

  @Test func synthesisPrefsRoundTripUnderTheSuffixedKeys() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "AAAA-BBBB")
      prefs.setOfferSyntheticSizes(true)
      prefs.setStoredSyntheticSize(SyntheticSizeDescriptor(logicalWidth: 3096, logicalHeight: 1296))

      #expect(prefs.offerSyntheticSizes)
      #expect(prefs.storedSyntheticSize
        == SyntheticSizeDescriptor(logicalWidth: 3096, logicalHeight: 1296))
      // The exact key strings: shipped schema, same `<name>.<pk>` composition
      // every other per-display pref uses.
      #expect(defaults.object(forKey: "offerSyntheticSizes.AAAA-BBBB") as? Bool == true)
      let stored = try? JSONDecoder().decode(
        SyntheticSizeDescriptor.self,
        from: defaults.data(forKey: "storedSyntheticSize.AAAA-BBBB") ?? Data()
      )
      #expect(stored == SyntheticSizeDescriptor(logicalWidth: 3096, logicalHeight: 1296))
    }
  }

  @Test func clearingTheStoredSyntheticSizeRemovesTheKeyAndLeavesTheOptInAlone() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      prefs.setOfferSyntheticSizes(true)
      prefs.setStoredSyntheticSize(SyntheticSizeDescriptor(logicalWidth: 2752, logicalHeight: 1152))

      prefs.setStoredSyntheticSize(nil)
      #expect(prefs.storedSyntheticSize == nil)
      // REMOVED, not written as an empty value: an absent key is what the
      // resolver reads as "no stored choice".
      #expect(defaults.object(forKey: "storedSyntheticSize.pk") == nil)
      // Two separate answers, as with the remembered display mode: forgetting
      // the size must not opt the display back out.
      #expect(prefs.offerSyntheticSizes)
    }
  }

  @Test func anUndecodableStoredSyntheticSizeReadsAsNone() {
    withSuite { defaults in
      defaults.set(Data([0x7B, 0x7B]), forKey: "storedSyntheticSize.pk")
      #expect(DisplayPrefs(defaults: defaults, persistenceKey: "pk").storedSyntheticSize == nil)
    }
  }

  /// The opt-in reads through the COERCING accessor, so the shell spelling of a
  /// bool reaches it. `defaults write … offerSyntheticSizes YES` stores the
  /// STRING "YES", which `object(forKey:) as? Bool` rejects silently.
  @Test func theSynthesisOptInAcceptsTheSpellingsDefaultsWriteProduces() {
    for stored in ["YES", "yes", "true", "1"] as [Any] + [1, true] {
      withSuite { defaults in
        defaults.set(stored, forKey: "offerSyntheticSizes.pk")
        #expect(
          DisplayPrefs(defaults: defaults, persistenceKey: "pk").offerSyntheticSizes,
          "stored \(stored) should read as opted in"
        )
      }
    }
  }

  @Test func synthesisPrefsArePerDisplay() {
    withSuite { defaults in
      let a = DisplayPrefs(defaults: defaults, persistenceKey: "a")
      let b = DisplayPrefs(defaults: defaults, persistenceKey: "b")
      a.setOfferSyntheticSizes(true)
      a.setStoredSyntheticSize(SyntheticSizeDescriptor(logicalWidth: 3096, logicalHeight: 1296))
      #expect(b.offerSyntheticSizes == false)
      #expect(b.storedSyntheticSize == nil)
    }
  }

  @Test func synthesisKeyStringsNeverDrift() {
    #expect(PrefName.offerSyntheticSizes.rawValue == "offerSyntheticSizes")
    #expect(PrefName.storedSyntheticSize.rawValue == "storedSyntheticSize")
  }
}
