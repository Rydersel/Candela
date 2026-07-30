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
      prefs.hdrMode = .boost
      #expect(prefs.hdrMode == .boost)
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
      first.hdrMode = .boost
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

  @Test func hdrModeIsExhaustivelyEnumerated() {
    #expect(HDRMode.allCases == [.off, .boost, .alwaysOn])
    #expect(HDRMode.off.rawValue == 0)
    #expect(HDRMode.boost.rawValue == 1)
    #expect(HDRMode.alwaysOn.rawValue == 2)
  }

  @Test func storedSwitchingPointFeedsTheSwitchingValue() {
    withSuite { defaults in
      let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      #expect(DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint) == 0.5)
      prefs.combinedSwitchingPoint = -8
      #expect(DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint) == 0.0)
    }
  }
}
