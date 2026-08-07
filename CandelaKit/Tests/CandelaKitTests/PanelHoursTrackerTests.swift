import Foundation
import Testing
@testable import CandelaKit

@Suite("Panel hours tracking")
struct PanelHoursTrackerTests {
  /// `PrefsSchemaTests` has its own private write spy keyed on `writes: [String]`;
  /// it is nested and unreachable from here. A count is all this suite needs —
  /// asserting on the stored seconds cannot tell "did not write" from "wrote the
  /// same value", which is the entire claim the debounce makes.
  ///
  /// `@unchecked Sendable` restates the superclass conformance. The counter is
  /// unsynchronized, unlike `InMemoryDefaults`' locked storage: each instance is
  /// created and read inside one synchronous test body and never escapes it, so
  /// there is no second thread to race.
  private final class WriteCountingDefaults: InMemoryDefaults, @unchecked Sendable {
    private(set) var writeCount = 0
    override func set(_ value: Any?, forKey key: String) {
      writeCount += 1
      super.set(value, forKey: key)
    }
  }

  @Test func accumulatesOnlyWhileAwake() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 3600)
    t.noteTick(displayAwake: false, secondsSinceLastTick: 3600)
    #expect(t.totalHours == 1.0)
  }

  @Test func standbyResetsTheSinceCounterNotTheTotal() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 7200)
    t.noteStandby()
    #expect(t.totalHours == 2.0)
    #expect(t.hoursSinceStandby == 0.0)
  }

  @Test func persistsAcrossInstancesPerDisplay() {
    let defaults = InMemoryDefaults()
    let a = PanelHoursTracker(defaults: defaults, persistenceKey: "a")
    a.noteTick(displayAwake: true, secondsSinceLastTick: 3600)
    a.noteStandby()  // forces write-through
    let a2 = PanelHoursTracker(defaults: defaults, persistenceKey: "a")
    let b = PanelHoursTracker(defaults: defaults, persistenceKey: "b")
    #expect(a2.totalHours == 1.0)
    #expect(b.totalHours == 0.0)
  }

  @Test func debouncesWrites() {
    let defaults = WriteCountingDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    let before = defaults.writeCount
    for _ in 0..<30 { t.noteTick(displayAwake: true, secondsSinceLastTick: 1) }
    #expect(defaults.writeCount == before)          // 30 s unwritten: below debounce
    for _ in 0..<31 { t.noteTick(displayAwake: true, secondsSinceLastTick: 1) }
    #expect(defaults.writeCount > before)           // crossed 60 s: wrote through
  }

  @Test func debounceRestartsAfterAWriteThrough() {
    // The counter has to be CLEARED by the write, not just compared against a
    // rising total — leaving it set would write on every subsequent tick, which
    // is the failure mode the debounce exists to prevent and which the
    // crossing-only assertion above cannot see.
    let defaults = WriteCountingDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 61)
    let afterFirstWrite = defaults.writeCount
    #expect(afterFirstWrite > 0)
    for _ in 0..<30 { t.noteTick(displayAwake: true, secondsSinceLastTick: 1) }
    #expect(defaults.writeCount == afterFirstWrite)
  }

  @Test func standbyNoteThreshold() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 8 * 3600 - 1)
    #expect(t.shouldShowStandbyNote == false)
    t.noteTick(displayAwake: true, secondsSinceLastTick: 1)
    #expect(t.shouldShowStandbyNote == true)
    t.noteStandby()
    #expect(t.shouldShowStandbyNote == false)
  }

  @Test func dismissingTheNoteSuppressesItUntilTheNextStandby() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    #expect(t.shouldShowStandbyNote == true)
    t.dismissStandbyNote()
    #expect(t.shouldShowStandbyNote == false)
    t.noteTick(displayAwake: true, secondsSinceLastTick: 3600)
    #expect(t.shouldShowStandbyNote == false)  // still dismissed; no re-nag
    t.noteStandby()
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    #expect(t.shouldShowStandbyNote == true)   // a fresh run earns a fresh note
  }

  @Test func dismissalSurvivesInstanceRecreation() {
    // The counter is persisted, so an in-memory-only dismissal re-shows the
    // note on every relaunch — the recurring reminder the spec forbids.
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    t.dismissStandbyNote()
    let relaunched = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    #expect(relaunched.hoursSinceStandby == 9.0)  // still over the threshold
    #expect(relaunched.shouldShowStandbyNote == false)
  }

  @Test func aDismissalIsScopedToItsDisplay() {
    let defaults = InMemoryDefaults()
    let a = PanelHoursTracker(defaults: defaults, persistenceKey: "a")
    let b = PanelHoursTracker(defaults: defaults, persistenceKey: "b")
    a.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    b.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    a.dismissStandbyNote()
    #expect(a.shouldShowStandbyNote == false)
    #expect(b.shouldShowStandbyNote == true)
  }

  @Test func standbyClearsThePersistedDismissalSoTheNextCrossingShows() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    t.dismissStandbyNote()
    t.noteStandby()
    #expect(defaults.object(forKey: "oledStandbyNoteDismissed.pk") == nil)
    let relaunched = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    relaunched.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    #expect(relaunched.shouldShowStandbyNote == true)
  }

  @Test func resetClearsThePersistedDismissal() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    t.dismissStandbyNote()
    t.reset()
    let relaunched = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    relaunched.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    #expect(relaunched.shouldShowStandbyNote == true)
  }

  @Test func resetRemovesKeysRatherThanZeroingThem() {
    // A settings reset should leave no key behind; zeroed keys resurrect the
    // display's entry in the domain for a display that may never return.
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    t.dismissStandbyNote()
    t.reset()
    #expect(defaults.object(forKey: "oledPanelSeconds.pk") == nil)
    #expect(defaults.object(forKey: "oledStandbySeconds.pk") == nil)
    #expect(defaults.object(forKey: "oledStandbyNoteDismissed.pk") == nil)
  }

  @Test func sleepWakeWalkKeepsTheTotalContinuous() {
    // Spec §9: the total is lifetime panel-on time and must survive a standby
    // untouched, while the since-counter restarts from it. Asleep ticks add to
    // neither — that is the whole point of `displayAwake`.
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    for _ in 0..<3 { t.noteTick(displayAwake: true, secondsSinceLastTick: 3600) }
    #expect(t.totalHours == 3.0)
    #expect(t.hoursSinceStandby == 3.0)

    t.noteStandby()
    #expect(t.totalHours == 3.0)         // standby does not spend the lifetime total
    #expect(t.hoursSinceStandby == 0.0)

    for _ in 0..<5 { t.noteTick(displayAwake: false, secondsSinceLastTick: 3600) }
    #expect(t.totalHours == 3.0)         // five hours asleep count for nothing
    #expect(t.hoursSinceStandby == 0.0)

    for _ in 0..<2 { t.noteTick(displayAwake: true, secondsSinceLastTick: 3600) }
    #expect(t.totalHours == 5.0)         // continuous across the whole walk
    #expect(t.hoursSinceStandby == 2.0)  // restarted at the standby
  }

  @Test func resetClearsBoth() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 3600)
    t.reset()
    #expect(t.totalHours == 0.0)
    #expect(t.hoursSinceStandby == 0.0)
  }

  @Test func resetIsPersistedAndClearsADismissal() {
    // Settings reset must not leave the note permanently suppressed: a wiped
    // counter that can never speak again is worse than one that never counted.
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    t.dismissStandbyNote()
    t.reset()
    #expect(PanelHoursTracker(defaults: defaults, persistenceKey: "pk").totalHours == 0.0)
    t.noteTick(displayAwake: true, secondsSinceLastTick: 9 * 3600)
    #expect(t.shouldShowStandbyNote == true)
  }

  @Test func ignoresNonFiniteAndNonPositiveDeltas() {
    // The caller derives the delta from wall-clock timestamps, so a clock step
    // backwards produces a negative one. NaN and infinity are the ones that
    // matter: either poisons the totals irrecoverably, because it persists and
    // every later comparison against it reads false. NaN happens to fail the
    // `> 0` test on its own; infinity does not, and is what `isFinite` is for.
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 3600)
    t.noteTick(displayAwake: true, secondsSinceLastTick: 0)
    t.noteTick(displayAwake: true, secondsSinceLastTick: -7200)
    t.noteTick(displayAwake: true, secondsSinceLastTick: .nan)
    t.noteTick(displayAwake: true, secondsSinceLastTick: .infinity)
    #expect(t.totalHours == 1.0)
    #expect(t.hoursSinceStandby == 1.0)
  }

  @Test func storageKeysAreNamespacedPerDisplay() {
    let defaults = InMemoryDefaults()
    let t = PanelHoursTracker(defaults: defaults, persistenceKey: "abc")
    t.noteTick(displayAwake: true, secondsSinceLastTick: 120)
    t.noteStandby()
    #expect(defaults.double(forKey: "oledPanelSeconds.abc") == 120)
    #expect(defaults.double(forKey: "oledStandbySeconds.abc") == 0)
  }
}
