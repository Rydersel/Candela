import Foundation
import Testing
@testable import CandelaKit

@Suite("Per-display prefs")
struct DisplayPrefsTests {
  /// Each test gets a throwaway suite so nothing leaks into the user's defaults.
  private func withSuite(_ body: (UserDefaults) -> Void) {
    let suiteName = "com.rydersel.Candela.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
      #expect(prefs.isDisabled == false)
      #expect(prefs.hideOsd == false)
      prefs.enableMuteUnmute = true
      prefs.muted = true
      prefs.audioDeviceNameOverride = "MAG 341C"
      prefs.hideVolumeSlider = true
      prefs.isDisabled = true
      prefs.hideOsd = true
      #expect(defaults.object(forKey: "enableMuteUnmute.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "muted.AAAA-BBBB") as? Bool == true)
      #expect(defaults.string(forKey: "audioDeviceNameOverride.AAAA-BBBB") == "MAG 341C")
      #expect(defaults.object(forKey: "hideVolumeSlider.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "isDisabled.AAAA-BBBB") as? Bool == true)
      #expect(defaults.object(forKey: "hideOsd.AAAA-BBBB") as? Bool == true)
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
}
