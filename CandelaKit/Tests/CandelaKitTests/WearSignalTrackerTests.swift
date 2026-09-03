import Foundation
import Testing

@testable import CandelaKit

@Suite("Wear signal tracking")
struct WearSignalTrackerTests {

  private func tracker(_ defaults: UserDefaults, _ key: String = "panel-a") -> WearSignalTracker {
    WearSignalTracker(defaults: defaults, persistenceKey: key)
  }

  // MARK: - The state axis

  @Test func secondsAccumulatePerState() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 60)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 30)
    t.noteTick(dimState: .idleDim, effectiveLevel: 0.4, secondsSinceLastTick: 10)

    #expect(t.seconds(inState: .active) == 90)
    #expect(t.seconds(inState: .idleDim) == 10)
    #expect(t.seconds(inState: .blackout) == 0)
    #expect(t.totalSeconds == 100)
  }

  /// Same seconds, different levels: the state total must not depend on which
  /// bucket they landed in, or the state axis stops being the model-free answer
  /// the wear-signal gate needs.
  @Test func aStateTotalIsIndependentOfHowItsTimeSplitsAcrossBuckets() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    for level in [0.05, 0.15, 0.35, 0.55, 0.75, 0.95] {
      t.noteTick(dimState: .idleDim, effectiveLevel: level, secondsSinceLastTick: 10)
    }
    #expect(t.seconds(inState: .idleDim) == 60)
  }

  // MARK: - The level axis

  @Test func levelsLandInTenthWideBuckets() {
    #expect(WearSignalTracker.bucket(forLevel: 0.0) == 0)
    #expect(WearSignalTracker.bucket(forLevel: 0.09) == 0)
    #expect(WearSignalTracker.bucket(forLevel: 0.1) == 1)
    #expect(WearSignalTracker.bucket(forLevel: 0.55) == 5)
    #expect(WearSignalTracker.bucket(forLevel: 0.99) == 9)
  }

  /// The top bucket is closed, not open: a display at full brightness is the
  /// single most common state there is, and dropping it or trapping on it would
  /// be the defect that empties the soak.
  @Test func fullBrightnessLandsInTheTopBucketRatherThanOffTheEnd() {
    #expect(WearSignalTracker.bucket(forLevel: 1.0) == WearSignalTracker.bucketCount - 1)
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 1.0, secondsSinceLastTick: 60)
    #expect(t.secondsByBucket()[WearSignalTracker.bucketCount - 1] == 60)
    #expect(t.totalSeconds == 60)
  }

  @Test func outOfRangeLevelsClampRatherThanVanish() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 1.5, secondsSinceLastTick: 10)
    t.noteTick(dimState: .active, effectiveLevel: -0.5, secondsSinceLastTick: 10)
    #expect(t.totalSeconds == 20)
    #expect(t.secondsByBucket()[WearSignalTracker.bucketCount - 1] == 10)
    #expect(t.secondsByBucket()[0] == 10)
  }

  @Test func bucketsMarginalizeOverEveryState() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.85, secondsSinceLastTick: 100)
    t.noteTick(dimState: .idleDim, effectiveLevel: 0.85, secondsSinceLastTick: 50)
    #expect(t.secondsByBucket()[8] == 150)
  }

  // MARK: - The wear-signal gate

  @Test func theGateIsTheShareOfTimeInAWeightableDimState() throws {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 700)
    t.noteTick(dimState: .idleDim, effectiveLevel: 0.4, secondsSinceLastTick: 200)
    t.noteTick(dimState: .lockDim, effectiveLevel: 0.3, secondsSinceLastTick: 50)
    t.noteTick(dimState: .unfocusedDim, effectiveLevel: 0.6, secondsSinceLastTick: 50)

    let fraction = try #require(t.wearWeightableFraction)
    #expect(abs(fraction - 0.3) < 1e-9)
  }

  /// Blackout is excluded from the numerator: the wear-signal gate's mask does not apply to it,
  /// so counting it would overstate the case for the feature.
  @Test func blackoutIsNotWeightable() throws {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 500)
    t.noteTick(dimState: .blackout, effectiveLevel: 0, secondsSinceLastTick: 500)
    let fraction = try #require(t.wearWeightableFraction)
    #expect(fraction == 0)
  }

  /// Suspended time leaves the denominator rather than counting against the
  /// feature. A mirrored display is not showing what we would dim, so a
  /// projector plugged in for a day must not dilute the ratio.
  @Test func suspendedTimeIsExcludedFromTheDenominator() throws {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 50)
    t.noteTick(dimState: .idleDim, effectiveLevel: 0.4, secondsSinceLastTick: 50)
    t.noteTick(dimState: .suspended, effectiveLevel: 0.8, secondsSinceLastTick: 86_400)

    let fraction = try #require(t.wearWeightableFraction)
    #expect(abs(fraction - 0.5) < 1e-9)
  }

  /// "0% of no time" is not an answer and reads as a verdict against the
  /// feature. The gate must be able to say it does not know yet.
  @Test func theGateIsNilBeforeAnythingAccumulates() {
    let defaults = InMemoryDefaults()
    #expect(tracker(defaults).wearWeightableFraction == nil)
  }

  @Test func theGateIsNilWhenEverythingRecordedWasSuspended() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .suspended, effectiveLevel: 0.8, secondsSinceLastTick: 3600)
    #expect(t.wearWeightableFraction == nil)
  }

  // MARK: - Rejected ticks

  @Test func nonFiniteAndNonPositiveDeltasAreRejected() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: .nan)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: .infinity)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 0)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: -60)
    #expect(t.totalSeconds == 0)
  }

  /// A NaN level would otherwise book real seconds into an arbitrary bucket. It
  /// is rejected whole rather than clamped: unlike an out-of-range level, a NaN
  /// carries no information about where the time belongs.
  @Test func aNonFiniteLevelIsRejectedWholesale() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: .nan, secondsSinceLastTick: 60)
    #expect(t.totalSeconds == 0)
  }

  // MARK: - Persistence

  @Test func accumulationSurvivesARelaunch() {
    let defaults = InMemoryDefaults()
    let first = tracker(defaults)
    first.noteTick(dimState: .idleDim, effectiveLevel: 0.45, secondsSinceLastTick: 120)
    first.flush()

    let second = tracker(defaults)
    #expect(second.seconds(inState: .idleDim) == 120)
    #expect(second.secondsByBucket()[4] == 120)
  }

  /// Constructing a tracker is how a settings pane READS a display's histogram,
  /// so a visit to the Health pane creates one for a display nothing is
  /// measuring. Flushing that at sleep or quit wrote an all-zero array and
  /// created the key.
  @Test func aTrackerThatBookedNothingWritesNothingAtFlush() {
    let defaults = InMemoryDefaults()
    tracker(defaults).flush()
    #expect(defaults.object(forKey: "oledWearSeconds.panel-a") == nil)
    #expect(defaults.object(forKey: "oledWearSchema.panel-a") == nil)
  }

  @Test func oneAccumulatedSecondIsEnoughToFlush() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 1)
    t.flush()
    #expect(defaults.object(forKey: "oledWearSeconds.panel-a") != nil)
    #expect(tracker(defaults).totalSeconds == 1)
  }

  /// The guard is accumulation, never `unwrittenSeconds`: a tracker past its
  /// debounce has written through and holds nothing unwritten, and it still has
  /// to flush at quit or every later tick's tail is lost.
  @Test func aTrackerWrittenThroughAndThenIdleStillFlushes() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    // Past `debounceSeconds`, so `noteTick` itself wrote through.
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 90)
    defaults.removeObject(forKey: "oledWearSeconds.panel-a")
    t.flush()
    #expect(defaults.object(forKey: "oledWearSeconds.panel-a") != nil)
    #expect(tracker(defaults).totalSeconds == 90)
  }

  /// A tracker kept alive past a reset must not re-create the keys the reset
  /// removed, which is the whole of `resetLeavesNoKeyBehind`'s promise.
  @Test func aFlushAfterAResetLeavesNoKeyBehind() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 60)
    t.flush()
    t.reset()
    t.flush()
    #expect(defaults.object(forKey: "oledWearSeconds.panel-a") == nil)
    #expect(defaults.object(forKey: "oledWearSchema.panel-a") == nil)
  }

  @Test func displaysDoNotShareAHistogram() {
    let defaults = InMemoryDefaults()
    let a = tracker(defaults, "panel-a")
    a.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 60)
    a.flush()

    #expect(tracker(defaults, "panel-b").totalSeconds == 0)
    #expect(tracker(defaults, "panel-a").totalSeconds == 60)
  }

  @Test func resetLeavesNoKeyBehind() {
    let defaults = InMemoryDefaults()
    let t = tracker(defaults)
    t.noteTick(dimState: .active, effectiveLevel: 0.8, secondsSinceLastTick: 60)
    t.flush()
    t.reset()

    #expect(t.totalSeconds == 0)
    #expect(defaults.object(forKey: "oledWearSeconds.panel-a") == nil)
    #expect(defaults.object(forKey: "oledWearSchema.panel-a") == nil)
    #expect(tracker(defaults).totalSeconds == 0)
  }

  /// A stored array of the wrong length is discarded rather than indexed into.
  /// Unlike the exposure map this is NOT quarantined: a timing histogram has no
  /// per-cell meaning a later build could migrate, and re-soaking reproduces it.
  @Test func aStoredHistogramOfTheWrongShapeIsDiscarded() {
    let defaults = InMemoryDefaults()
    defaults.set([1.0, 2.0, 3.0], forKey: "oledWearSeconds.panel-a")
    defaults.set(OledStoreSchema.currentVersion, forKey: "oledWearSchema.panel-a")
    #expect(tracker(defaults).totalSeconds == 0)
  }

  @Test func aStoredHistogramFromANewerSchemaIsDiscarded() {
    let defaults = InMemoryDefaults()
    defaults.set(
      [Double](repeating: 5, count: WearSignalTracker.slotCount),
      forKey: "oledWearSeconds.panel-a")
    defaults.set(OledStoreSchema.currentVersion + 1, forKey: "oledWearSchema.panel-a")
    #expect(tracker(defaults).totalSeconds == 0)
  }

  @Test func aStoredHistogramCarryingANonFiniteValueIsDiscarded() {
    let defaults = InMemoryDefaults()
    var poisoned = [Double](repeating: 5, count: WearSignalTracker.slotCount)
    poisoned[7] = .nan
    defaults.set(poisoned, forKey: "oledWearSeconds.panel-a")
    #expect(tracker(defaults).totalSeconds == 0)
  }

  // MARK: - The on-disk shape

  /// The array is indexed by position in `stateOrder`. Reordering it, or
  /// deriving it from `CaseIterable`, reinterprets every user's accumulated
  /// history as different states.
  @Test func theStateOrderIsOnDiskSchema() {
    #expect(
      WearSignalTracker.stateOrder == [
        .active, .idleDim, .blackout, .lockDim, .unfocusedDim, .suspended,
      ])
    #expect(WearSignalTracker.slotCount == 60)
  }

  /// The concrete failure the order pins against: seconds written as `.idleDim`
  /// must still read back as `.idleDim`, not as whatever now sits at index 1.
  @Test func storedSecondsReadBackAgainstTheSameState() {
    let defaults = InMemoryDefaults()
    let first = tracker(defaults)
    first.noteTick(dimState: .lockDim, effectiveLevel: 0.25, secondsSinceLastTick: 300)
    first.flush()

    let stored = defaults.object(forKey: "oledWearSeconds.panel-a") as? [Double]
    let index = WearSignalTracker.stateOrder.firstIndex(of: .lockDim)! * 10 + 2
    #expect(stored?[index] == 300)
    #expect(tracker(defaults).seconds(inState: .lockDim) == 300)
  }

  @Test func everyStateHasASlot() {
    for state in WearSignalTracker.stateOrder {
      #expect(WearSignalTracker.slot(for: state, level: 0.5) != nil)
    }
  }

  // MARK: - The whole histogram

  @Test func histogramIsStateMajorAndNamesItsStates() {
    let defaults = InMemoryDefaults()
    let t = WearSignalTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(dimState: .active, effectiveLevel: 0.95, secondsSinceLastTick: 10)
    t.noteTick(dimState: .idleDim, effectiveLevel: 0.05, secondsSinceLastTick: 5)
    let h = t.histogram()
    #expect(
      h.stateNames == ["active", "idleDim", "blackout", "lockDim", "unfocusedDim", "suspended"])
    #expect(h.levelBuckets == 10)
    #expect(h.seconds.count == 6)
    #expect(h.seconds.allSatisfy { $0.count == 10 })
    #expect(h.seconds[0][9] == 10)
    #expect(h.seconds[1][0] == 5)
    #expect(h.seconds.flatMap { $0 }.reduce(0, +) == t.totalSeconds)
  }

  /// The names travel in exported files, so a renamed enum case must not
  /// silently drop a row out of one of the two tables.
  @Test func stateNamesTrackStateOrder() {
    #expect(WearSignalTracker.stateNames.count == WearSignalTracker.stateOrder.count)
    #expect(zip(WearSignalTracker.stateNames, WearSignalTracker.stateOrder).allSatisfy { $0 == String(describing: $1) })
  }

  @Test func aHistogramSumsItsOwnSeconds() {
    let defaults = InMemoryDefaults()
    let t = WearSignalTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(dimState: .lockDim, effectiveLevel: 0.35, secondsSinceLastTick: 20)
    t.noteTick(dimState: .suspended, effectiveLevel: 0.5, secondsSinceLastTick: 7)
    #expect(t.histogram().totalSeconds == 27)
  }

  /// The histogram travels inside exported records, so it has to survive a
  /// coding round trip whole.
  @Test func aHistogramRoundTripsThroughCoding() throws {
    let defaults = InMemoryDefaults()
    let t = WearSignalTracker(defaults: defaults, persistenceKey: "pk")
    t.noteTick(dimState: .idleDim, effectiveLevel: 0.2, secondsSinceLastTick: 12)
    let h = t.histogram()
    #expect(try JSONDecoder().decode(WearHistogram.self, from: JSONEncoder().encode(h)) == h)
  }
}
