import Foundation

/// Accumulated panel-on time for one display, split by dim state and by how
/// bright the panel was left (OC20).
///
/// Ships before the two features that consume it, because neither can start
/// accumulating until this exists: OC17's effect-size gate (what fraction of
/// panel-on time is spent in a wear-weightable dim state) and the
/// modelled-vs-measured comparison (what drive level the panel actually ran at).
/// `PanelHoursTracker` answers neither.
///
/// **Both axes are load-bearing and neither derives from the other.** The state
/// axis answers OC17's gate as a count of seconds, with nothing in it that can
/// be wrong. The level axis is what a wear model integrates, and it carries a
/// proxy caveat the state axis does not (see `noteTick`).
///
/// **A histogram rather than an integral, deliberately.** `sum(level * dt)` is
/// smaller and is exactly what a linear wear model wants, which is the objection
/// to it: it bakes linearity into the *storage*. Brightness setting to OLED
/// drive current is not linear, is panel-dependent, and is not something we
/// know. A histogram lets any monotone function of level be recovered from the
/// same soak afterwards; an integral commits to one and cannot be un-committed
/// without re-soaking for weeks.
///
/// Deliberately not `Sendable`, matching `PanelHoursTracker`: confined to
/// whichever actor owns the display's controllers (the main actor today).
public final class WearSignalTracker {
  /// Level buckets across 0...1. Ten is fine enough to separate the settings a
  /// person actually picks and coarse enough that a multi-week soak fills every
  /// occupied bucket with a meaningful count.
  public static let bucketCount = 10

  /// **On-disk schema: append only, never reorder.** The stored array is indexed
  /// by position in this table, so deriving it from `CaseIterable` would let a
  /// new `OledDimState` case silently renumber every user's history. "Add keys,
  /// never renumber" applies to array positions as much as to enum raw values.
  static let stateOrder: [OledDimState] = [
    .active, .idleDim, .blackout, .lockDim, .unfocusedDim, .suspended,
  ]

  /// Spelled out, not derived from the enum: these travel in exported files, so a
  /// case rename must not rename them. Same positions as `stateOrder`.
  public static let stateNames: [String] = [
    "active", "idleDim", "blackout", "lockDim", "unfocusedDim", "suspended",
  ]

  /// The states OC17's mask would apply to. Blackout is excluded because there
  /// is no luminance left to redistribute; `active` and `suspended` because
  /// nothing is dimming.
  static let wearWeightableStates: Set<OledDimState> = [.idleDim, .lockDim, .unfocusedDim]

  static var slotCount: Int { stateOrder.count * bucketCount }

  /// Ticks arrive on the order of seconds; writing each one would put a
  /// defaults write on a permanent timer for every attached display.
  private static let debounceSeconds: Double = 60

  private let defaults: UserDefaults
  private let secondsKey: String
  private let versionKey: String
  private var slots: [Double]
  private var unwrittenSeconds: Double = 0

  public init(defaults: UserDefaults = .standard, persistenceKey: String) {
    self.defaults = defaults
    self.secondsKey = "oledWearSeconds.\(persistenceKey)"
    self.versionKey = "oledWearSchema.\(persistenceKey)"

    // A stored version we do not understand, or an array of the wrong shape, is
    // discarded rather than reinterpreted. Unlike the exposure map this is NOT
    // quarantined: it is a derived timing histogram with no per-cell meaning, so
    // there is nothing here a later build could migrate that re-soaking would
    // not also produce.
    let storedVersion = defaults.object(forKey: versionKey) as? Int ?? OledStoreSchema.currentVersion
    // `object(forKey:)`, not `array(forKey:)`: the latter is not among the
    // primitives the test double overrides, so it falls through to the real
    // defaults domain and a test starts reading a developer's own preferences.
    let stored = defaults.object(forKey: secondsKey) as? [Double]
    if storedVersion <= OledStoreSchema.currentVersion, let stored,
      stored.count == Self.slotCount, stored.allSatisfy({ $0.isFinite && $0 >= 0 }) {
      self.slots = stored
    } else {
      self.slots = [Double](repeating: 0, count: Self.slotCount)
    }
  }

  // MARK: - Accumulation

  /// Books one tick's elapsed seconds against a state and a level.
  ///
  /// `effectiveLevel` is the fraction of full output the panel is left at:
  /// `brightness` for `.active`, `brightness * idleDimBrightness` for `.idleDim`,
  /// `brightness * lockDimFactor` for `.lockDim`, 0 for `.blackout`. The caller
  /// computes it because only the caller has the display's config; `lockDim` in
  /// particular must use the factor explicitly, since the wire-level lock dim
  /// never writes `controller.brightness`.
  ///
  /// **It is a proxy for drive level, never a measured luminance.** It assumes a
  /// black overlay at alpha a leaves `1 - a` of the light and that this
  /// multiplies the brightness setting, ignoring the display's own EOTF and any
  /// local dimming. Nothing derived from the level axis may be called measured,
  /// which is why the state axis exists as an independent answer.
  public func noteTick(
    dimState: OledDimState, effectiveLevel: Double, secondsSinceLastTick: Double
  ) {
    // The caller derives the delta from wall-clock timestamps, so a clock step
    // backwards yields a negative one. `isFinite` is explicit: a NaN in a slot is
    // unrecoverable once persisted, because every later comparison against it
    // reads false and the counter stops meaning anything.
    guard secondsSinceLastTick.isFinite, secondsSinceLastTick > 0 else { return }
    guard effectiveLevel.isFinite else { return }
    guard let slot = Self.slot(for: dimState, level: effectiveLevel) else { return }

    slots[slot] += secondsSinceLastTick
    unwrittenSeconds += secondsSinceLastTick
    if unwrittenSeconds > Self.debounceSeconds { writeThrough() }
  }

  static func bucket(forLevel level: Double) -> Int {
    guard level.isFinite else { return 0 }
    let scaled = Int((max(0, min(1, level)) * Double(bucketCount)).rounded(.down))
    return min(bucketCount - 1, max(0, scaled))
  }

  static func slot(for state: OledDimState, level: Double) -> Int? {
    guard let stateIndex = stateOrder.firstIndex(of: state) else { return nil }
    return stateIndex * bucketCount + bucket(forLevel: level)
  }

  // MARK: - Reading

  public var totalSeconds: Double { slots.reduce(0, +) }

  public func seconds(inState state: OledDimState) -> Double {
    guard let index = Self.stateOrder.firstIndex(of: state) else { return 0 }
    let start = index * Self.bucketCount
    return slots[start..<(start + Self.bucketCount)].reduce(0, +)
  }

  /// Seconds per level bucket, marginalized over every state. Index `i` covers
  /// levels `i/10 ..< (i+1)/10`, with the top bucket closed at 1.0.
  public func secondsByBucket() -> [Double] {
    var out = [Double](repeating: 0, count: Self.bucketCount)
    for (index, seconds) in slots.enumerated() {
      out[index % Self.bucketCount] += seconds
    }
    return out
  }

  /// Seconds per state, marginalized over every bucket, in `stateOrder`.
  public func secondsByState() -> [(state: OledDimState, seconds: Double)] {
    Self.stateOrder.map { ($0, seconds(inState: $0)) }
  }

  /// Both axes where `secondsByState` gives one marginal. Seconds are copied.
  public func histogram() -> WearHistogram {
    let rows = Self.stateOrder.indices.map { index -> [Double] in
      let start = index * Self.bucketCount
      return Array(slots[start..<(start + Self.bucketCount)])
    }
    return WearHistogram(stateNames: Self.stateNames, levelBuckets: Self.bucketCount, seconds: rows)
  }

  /// **OC17's effect-size gate, as one number.** The share of
  /// MASK-COULD-APPLY time spent in a state the wear mask would apply to.
  ///
  /// The denominator is a ruling, not an artifact of the arithmetic: suspended
  /// seconds are excluded because the mask cannot apply during them, so counting
  /// them measures the gate against time it was never eligible to act in.
  ///
  /// Suspended time is real, and under synthesis it is common (SS8): a
  /// synthesized size mirrors the panel onto a virtual display, and OLED care
  /// keeps booking that panel's time as `.suspended` rather than stopping the
  /// clock. It belongs in the histogram, not in this ratio.
  ///
  /// Nil rather than zero when nothing has accumulated: "0% of no time" is not
  /// an answer and reads as a verdict.
  ///
  /// A count of seconds, carrying none of the level axis's proxy caveat.
  public var wearWeightableFraction: Double? {
    let denominator = totalSeconds - seconds(inState: .suspended)
    guard denominator > 0 else { return nil }
    let numerator = Self.wearWeightableStates.reduce(0.0) { $0 + seconds(inState: $1) }
    return numerator / denominator
  }

  // MARK: - Persistence

  public func reset() {
    slots = [Double](repeating: 0, count: Self.slotCount)
    unwrittenSeconds = 0
    // Removed rather than zeroed, matching `PanelHoursTracker`: a settings
    // reset should leave no key behind, and every read here treats absence as
    // a fresh histogram.
    defaults.removeObject(forKey: secondsKey)
    defaults.removeObject(forKey: versionKey)
  }

  /// The undebounced write, for termination and sleep.
  public func flush() { writeThrough() }

  private func writeThrough() {
    defaults.set(slots, forKey: secondsKey)
    defaults.set(OledStoreSchema.currentVersion, forKey: versionKey)
    unwrittenSeconds = 0
  }
}

/// States named as strings for readers with no `OledDimState` to index by. Derived
/// and never persisted, so `Codable` needs no declared keys here, unlike the exported
/// `ProvenanceWearHistogram`.
public struct WearHistogram: Codable, Equatable, Sendable {
  public let stateNames: [String]
  public let levelBuckets: Int
  public let seconds: [[Double]]

  public init(stateNames: [String], levelBuckets: Int, seconds: [[Double]]) {
    self.stateNames = stateNames
    self.levelBuckets = levelBuckets
    self.seconds = seconds
  }

  public var totalSeconds: Double { seconds.flatMap { $0 }.reduce(0, +) }
}
