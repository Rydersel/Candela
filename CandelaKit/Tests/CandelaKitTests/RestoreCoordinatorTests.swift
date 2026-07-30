import Foundation
import Testing
@testable import CandelaKit

@Suite("Restore coordinator (D5)")
@MainActor
struct RestoreCoordinatorTests {
  private func makeCoordinator(
    action: StartupAction,
    soberDelay: Duration = .milliseconds(5),
    repeatInterval: Duration = .milliseconds(2),
    repeatCount: Int = 10
  ) -> (RestoreCoordinator, Counter) {
    let counter = Counter()
    let coordinator = RestoreCoordinator(
      startupAction: { action },
      soberDelay: soberDelay,
      repeatInterval: repeatInterval,
      repeatCount: repeatCount
    )
    coordinator.restorePass = { counter.count += 1 }
    return (coordinator, counter)
  }

  @MainActor
  private final class Counter {
    var count = 0
  }

  @Test func doNothingNeverRestores() async {
    let (coordinator, counter) = makeCoordinator(action: .doNothing)
    coordinator.noteLaunchOrReconfigure()
    coordinator.noteWake()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(counter.count == 0)
  }

  @Test func readActionNeverRunsTheWritePass() async {
    let (coordinator, counter) = makeCoordinator(action: .read)
    coordinator.noteLaunchOrReconfigure()
    coordinator.noteWake()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(counter.count == 0)
  }

  @Test func launchOrReconfigureRestoresExactlyOnce() {
    let (coordinator, counter) = makeCoordinator(action: .write)
    coordinator.noteLaunchOrReconfigure()
    #expect(counter.count == 1)
  }

  @Test func wakeRunsSoberDelayThenTenRepeats() async {
    let (coordinator, counter) = makeCoordinator(action: .write)
    coordinator.noteWake()
    // Nothing before the sober delay elapses. Deterministic ONLY because the
    // coordinator's plain `Task {}` inherits the main actor and cannot run
    // before this test suspends — see the why-comment in noteWake.
    #expect(counter.count == 0)
    for _ in 0 ..< 400 { // ~2 s ceiling at 5 ms polls
      if counter.count == 10 { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(counter.count == 10)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(counter.count == 10) // chain ends at exactly repeatCount
  }

  @Test func aNewerWakeSupersedesTheOlderChain() async {
    // Timing bounds per concurrency F6: supersede at the FIRST observed pass
    // and keep the old chain's interval wide (50 ms) so a CI stall can never
    // fit a full double-run inside the poll budget.
    let (coordinator, counter) = makeCoordinator(
      action: .write, soberDelay: .milliseconds(1), repeatInterval: .milliseconds(50), repeatCount: 10
    )
    coordinator.noteWake()
    for _ in 0 ..< 200 {
      if counter.count >= 1 { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    let observedAtSupersession = counter.count
    coordinator.noteWake() // fork parity: the counter token orphans the old chain
    for _ in 0 ..< 800 {
      if counter.count >= observedAtSupersession + 10 { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    try? await Task.sleep(for: .milliseconds(120))
    // Old chain stopped at its supersession check — at most ONE extra pass of
    // guard-before-sleep slack — and only the new chain ran to completion.
    #expect(counter.count <= observedAtSupersession + 1 + 10)
    #expect(counter.count >= 10)
  }
}

@Suite("Restore methods on the controllers")
@MainActor
struct ControllerRestoreTests {
  @Test func restoreFullRangeDDCWritesThePublishedValueOnTheFullRange() async {
    // Combined mode default: published 0.3 sits below s=0.5, so the combined
    // DDC leg is 0 — but the quit restore must write the FULL-RANGE
    // equivalent (30) so the monitor isn't left at the DDC floor.
    let suiteName = "com.rydersel.Candela.tests.quitrestore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let fake = FakeDDC(readResult: nil)
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "qr")
    prefs.forceSoftware = true // keeps setBrightness off the DDC wire for setup…
    let controller = BrightnessController(
      writer: fake,
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(displayID: 3) { _, _ in false },
        hdr: nil, shade: nil, gamma: nil
      ),
      prefs: prefs,
      displayID: 3
    )
    controller.setBrightness(0.3)
    prefs.forceSoftware = false // …then re-enable hardware for the quit path
    controller.restoreFullRangeDDC()
    await controller.waitForPendingWrites()
    let writes = await fake.recordedWrites()
    #expect(writes.last?.command == VCP.brightness)
    #expect(writes.last?.value == 30)
  }

  @Test func reassertHardwareRewritesAfterAMemoReset() async {
    let suiteName = "com.rydersel.Candela.tests.reassert.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "disableCombinedBrightness")
    let fake = FakeDDC(readResult: nil)
    let controller = BrightnessController(
      writer: fake,
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(displayID: 4) { _, _ in false },
        hdr: nil, shade: nil, gamma: nil
      ),
      prefs: DisplayPrefs(defaults: defaults, persistenceKey: "ra"),
      displayID: 4
    )
    controller.setBrightness(0.5)
    await controller.waitForPendingWrites()
    controller.reassertHardware() // same target → duplicate-skipped
    await controller.waitForPendingWrites()
    #expect((await fake.recordedWrites()).count == 1)
    controller.resetWriteMemo() // the D5 wake-pass prerequisite
    controller.reassertHardware()
    await controller.waitForPendingWrites()
    #expect((await fake.recordedWrites()).count == 2)
    #expect((await fake.recordedWrites()).last?.value == 50)
  }

  @Test func hasStoredValueIsTheEverTouchedGate() {
    // D5's "stored (= ever-touched)" gate for the restore pass's brightness
    // leg (fork isTouched; planner flag 4 OVERTURNED, review R4): a fresh
    // display publishes the assumed default 1.0 with an EMPTY store, and a
    // restore pass must never write that — full blast on an OLED at night.
    // AppModel.performRestorePass checks this accessor instead of reaching
    // into the store.
    let suiteName = "com.rydersel.Candela.tests.evertouched.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = PathMemoryStore()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(displayID: 6) { _, _ in false },
        hdr: nil, shade: nil, gamma: nil
      ),
      prefs: DisplayPrefs(defaults: defaults, persistenceKey: "et"),
      displayID: 6,
      store: store,
      storageKey: "combinedBrightness.et"
    )
    #expect(controller.hasStoredValue == false) // never touched — restore must skip
    controller.setBrightness(0.5)
    #expect(controller.hasStoredValue) // published once — restore may re-assert
  }
}
