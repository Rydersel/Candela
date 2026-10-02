import CandelaKit
import Foundation
import Testing

@Suite("Custom end time") @MainActor
struct EndTimeSelectionTests {
  @Test func customPauseRevalidatesEnrollmentAndDisplayIdentityAtConfirmation() async {
    let key = "custom-pause"
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: key)
    prefs.oledCareEnrolled = true
    let discovery = ScriptedDiscovery([(id: 7, key: key, name: "First")])
    let model = TestFixtures.appModel(discovery: discovery)
    model.oledCare.prefsDefaults = defaults
    await model.refresh()
    let deadline = Date().addingTimeInterval(120)
    #expect(model.applyDimmingPause(until: deadline, for: key) == nil)
    #expect(model.oledCare.dimmingPauseDeadline(for: key) == deadline)
    model.oledCare.resumeDimming(for: key)
    prefs.oledCareEnrolled = false
    #expect(model.applyDimmingPause(until: deadline, for: key) != nil)
    #expect(model.oledCare.dimmingPauseDeadline(for: key) == nil)
    prefs.oledCareEnrolled = true
    // A different panel taking the same numeric ID must not inherit this dialog.
    discovery.topology = [(id: 7, key: "replacement-\(UUID())", name: "Second")]
    await model.refresh()
    #expect(model.applyDimmingPause(until: deadline, for: key) != nil)
    #expect(model.oledCare.dimmingPauseDeadline(for: key) == nil)
  }

  @Test func customPauseRefusesSafeModeAndASettingsReset() async {
    let key = "custom-pause-blocked"
    let defaults = InMemoryDefaults()
    DisplayPrefs(defaults: defaults, persistenceKey: key).oledCareEnrolled = true
    let discovery = ScriptedDiscovery([(id: 7, key: key, name: "Display")])
    let safe = TestFixtures.appModel(discovery: discovery, safeMode: true)
    safe.oledCare.prefsDefaults = defaults
    await safe.refresh()
    let deadline = Date().addingTimeInterval(120)
    #expect(safe.applyDimmingPause(until: deadline, for: key) != nil)
    #expect(safe.oledCare.dimmingPauseDeadline(for: key) == nil)
    let model = TestFixtures.appModel(discovery: discovery)
    model.oledCare.prefsDefaults = defaults
    await model.refresh()
    // The control: the same model accepts the pause before the reset begins.
    #expect(model.applyDimmingPause(until: deadline, for: key) == nil)
    model.oledCare.resumeDimming(for: key)
    #expect(await model.beginReset())
    #expect(model.applyDimmingPause(until: deadline, for: key) != nil)
    #expect(model.oledCare.dimmingPauseDeadline(for: key) == nil)
    await model.endReset()
  }

  @Test func editingAndCancellingDoNotApplyAndConfirmationUsesTheSelectedInstant() {
    let now = Date(timeIntervalSince1970: 1_000)
    var applied: [Date] = []
    let selection = EndTimeSelection(currentDeadline: nil, now: { now }) {
      applied.append($0)
      return nil
    }
    selection.deadline = Date(timeIntervalSince1970: 1_200)
    #expect(applied.isEmpty)
    selection.cancel()
    #expect(!selection.confirm())
    #expect(applied.isEmpty)
    let next = EndTimeSelection(currentDeadline: nil, now: { now }) {
      applied.append($0)
      return nil
    }
    next.deadline = Date(timeIntervalSince1970: 1_234)
    #expect(next.confirm())
    #expect(applied == [Date(timeIntervalSince1970: 1_234)])
    #expect(!next.confirm())
    #expect(applied.count == 1)
  }

  @Test func validatingAnEditedMinuteDoesNotApplyOrChangeTheExistingDeadline() {
    let now = Date(timeIntervalSince1970: 1_030)
    var applied = false
    let existing = now.addingTimeInterval(600)
    let selection = EndTimeSelection(currentDeadline: existing, now: { now }) { _ in
      applied = true; return nil
    }
    #expect(selection.canConfirm)
    #expect(!selection.canConfirm(deadline: Date(timeIntervalSince1970: 1_020)))
    #expect(selection.canConfirm(deadline: now.addingTimeInterval(120)))
    #expect(!selection.canConfirm(deadline: now.addingTimeInterval(TimedControlDeadline.maximumInterval + 1)))
    #expect(selection.deadline == existing && !applied)
    selection.cancel()
    #expect(!selection.canConfirm(deadline: now.addingTimeInterval(120)))
  }

  @Test func timePassingWhileDialogIsOpenCannotStartAnExpiredTimer() {
    var now = Date(timeIntervalSince1970: 1_000)
    var applied = false
    let selection = EndTimeSelection(currentDeadline: nil, now: { now }) { _ in
      applied = true
      return nil
    }
    selection.deadline = Date(timeIntervalSince1970: 1_100)
    now = Date(timeIntervalSince1970: 1_100)
    #expect(!selection.confirm())
    #expect(!applied)
    #expect(selection.errorMessage != nil)
  }

  @Test func refusedTargetKeepsDialogOpenAndDoesNotReportSuccess() {
    let now = Date(timeIntervalSince1970: 1_000)
    var available = false
    let selection = EndTimeSelection(currentDeadline: now.addingTimeInterval(600), now: { now }) { _ in
      available ? nil : "Display disconnected"
    }
    #expect(selection.deadline == Date(timeIntervalSince1970: 1_600))
    #expect(!selection.confirm())
    #expect(selection.errorMessage != nil)
    available = true
    #expect(selection.confirm())
  }

  @Test func aNewChoiceClearsARefusalSoLiveValidationShowsThrough() {
    let now = Date(timeIntervalSince1970: 1_000)
    var refusal: String? = "Wait for the settings reset to finish."
    let selection = EndTimeSelection(currentDeadline: now.addingTimeInterval(600), now: { now }) { _ in
      refusal
    }
    #expect(!selection.confirm())
    #expect(selection.errorMessage == "Wait for the settings reset to finish.")
    selection.deadline = now.addingTimeInterval(900)
    #expect(selection.errorMessage == nil)
    #expect(selection.canConfirm)
    refusal = nil
    #expect(selection.confirm())
  }
}
