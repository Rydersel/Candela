import CandelaKit
import Testing

// The app half of the propagation seam: `PrefPropagation` decides which effects a
// pref carries and the engine suite pins that table; this asserts `SettingsActions`
// actually runs them. `.restartBrightnessPoll` rebuilds a job nothing here can
// read, so it is a hardware leg: turn sync on with nothing open and watch an
// external follow the built-in without waiting out the slow interval.
@Suite("Settings actions fan-out") @MainActor
struct SettingsActionsFanOutTests {
  private final class Counts {
    var rearmTap = 0
    var recheckPermissions = 0
    var updateStatusItem = 0
  }

  private func makeActions(_ model: AppModel) -> (SettingsActions, Counts) {
    let counts = Counts()
    let actions = SettingsActions(model: model)
    actions.rearmTap = { counts.rearmTap += 1 }
    actions.recheckPermissions = { counts.recheckPermissions += 1 }
    actions.updateStatusItem = { counts.updateStatusItem += 1 }
    return (actions, counts)
  }

  @Test func aKeyModeWriteRearmsTheTapAndRechecksTheGrant() {
    let model = TestFixtures.appModel()
    let (actions, counts) = makeActions(model)
    actions.prefDidChange(.keyboardBrightness)
    #expect(counts.rearmTap == 1)
    #expect(counts.recheckPermissions == 1)
    #expect(counts.updateStatusItem == 0)
  }

  /// The control: a presentation-only pref must reach neither the tap nor the
  /// permission check, or the assertions above pass for everything.
  @Test func aPresentationPrefReachesNeitherOfThem() {
    let model = TestFixtures.appModel()
    let (actions, counts) = makeActions(model)
    actions.prefDidChange(.showContrast)
    #expect(counts.rearmTap == 0)
    #expect(counts.recheckPermissions == 0)
  }

  /// A batch fans out the UNION, which is no single member's row.
  @Test func aBatchFansOutEveryMembersEffects() {
    let model = TestFixtures.appModel()
    let (actions, counts) = makeActions(model)
    actions.prefsDidChange([.keyboardBrightness, .hideDisplay])
    #expect(counts.rearmTap == 1)
    #expect(counts.recheckPermissions == 1)
    #expect(counts.updateStatusItem == 1)
  }

  /// Turning brightness sync on carries the poll restart and nothing that writes
  /// hardware. What is observable here is that it goes through the seam at all and
  /// invalidates the surfaces; the restart itself is the hardware leg above.
  @Test func turningSyncOnGoesThroughTheSeam() {
    let model = TestFixtures.appModel()
    let (actions, counts) = makeActions(model)
    let before = model.prefsRevision
    actions.prefDidChange(.enableBrightnessSync)
    #expect(model.prefsRevision > before)
    #expect(counts.rearmTap == 0)
    #expect(counts.recheckPermissions == 0)
  }
}
