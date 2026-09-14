import Foundation
import Testing

@Suite("Update relaunch mark")
struct UpdateRelaunchTests {
  let defaults = UserDefaults(suiteName: "update-relaunch-tests-\(UUID().uuidString)")!

  @Test func aPlainLaunchConsumesNothing() {
    #expect(UpdateRelaunch.consume(in: defaults) == false)
  }

  @Test func aMarkedRelaunchIsConsumedExactlyOnce() {
    UpdateRelaunch.mark(in: defaults)
    #expect(UpdateRelaunch.consume(in: defaults) == true)
    #expect(UpdateRelaunch.consume(in: defaults) == false)
    #expect(defaults.object(forKey: UpdateRelaunch.defaultsKey) == nil)
    #expect(defaults.object(forKey: UpdateRelaunch.previousVersionKey) == nil)
  }

  @Test func onlyAKnownPredecessorUpgradeAllowsLegacyBrightnessRecovery() {
    #expect(!UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: "1.0.4"))
    UpdateRelaunch.mark(in: defaults, version: "1.0.3")
    #expect(UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: "1.0.4"))
    #expect(UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: "1.1.0"))
    // Reading the hint must not consume the update-completion notice.
    #expect(defaults.bool(forKey: UpdateRelaunch.defaultsKey))
    for version in ["1.0.3", "1.0.2", "?", "", "garbage", "1.0.4-beta", "1..4", "1.0.4."] {
      #expect(!UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: version))
    }
    for previous in ["1.0.2", "1.0.4", "1.0.5", "?", "", "garbage"] {
      UpdateRelaunch.mark(in: defaults, version: previous)
      #expect(!UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: "1.0.4"))
    }
    defaults.removeObject(forKey: UpdateRelaunch.previousVersionKey)
    #expect(!UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: "1.0.4"))
    defaults.set("1.0.3", forKey: UpdateRelaunch.previousVersionKey)
    defaults.removeObject(forKey: UpdateRelaunch.defaultsKey)
    #expect(!UpdateRelaunch.needsLegacyBrightnessRecovery(in: defaults, version: "1.0.4"))
  }

}
