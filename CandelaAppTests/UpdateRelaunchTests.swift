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
  }
}
