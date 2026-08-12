import CoreGraphics
import Testing

@testable import CandelaKit

/// Measured ambient-hunting deltas (2026-08-11, twelve minutes of unified log
/// with no user input): 84% of the fan-out traffic sat between 0.005 and 0.011,
/// and the sensor HUNTS around a point rather than drifting one way. This is
/// one cycle of that: every step is in the measured band and the cycle nets
/// close to zero, so repeating it walks the running sum around a centre.
private let huntingCycle: [Double] = [
  -0.0094, 0.0050, 0.0094, -0.0111, -0.0050, 0.0087,
  0.0094, -0.0060, -0.0094, 0.0111, 0.0050, -0.0094,
]

/// Three cycles: long enough that a per-delta threshold would look fine while
/// an accumulator that never re-centres would drift out of the band.
private let huntingSequence = huntingCycle + huntingCycle + huntingCycle

/// One press of a brightness key: the smallest DELIBERATE change the app can
/// see on the source.
private let keyStep = 1.0 / 16

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
  abs(a - b) <= tolerance
}

@Suite("Sync deadband (ambient hunting)")
struct SyncDeadbandTests {
  @Test func thresholdSitsAboveTheHuntingEnvelopeAndBelowHalfAKeyStep() {
    // Above: measured hunting accumulates to roughly 0.02 around its centre,
    // so the band has to be wider than that to swallow all of it.
    #expect(SyncDeadband.threshold > 0.02)
    // Below: a residual can sit anywhere inside the band, so a deliberate step
    // is only GUARANTEED to cross when threshold < step - threshold.
    #expect(SyncDeadband.threshold < keyStep / 2)
  }

  /// The premise of the hunting fixture, checked rather than assumed: if the
  /// running sum left ±0.02 this sequence would be a drift, not a hunt, and
  /// suppressing it would be wrong.
  @Test func theHuntingFixtureStaysInsideTheMeasuredEnvelope() {
    var sum = 0.0
    var peak = 0.0
    for delta in huntingSequence {
      sum += delta
      peak = max(peak, abs(sum))
    }
    #expect(peak <= 0.02)
  }

  @Test func huntingNeverEscapesTheBand() {
    var band = SyncDeadband()
    let sent = huntingSequence.compactMap { band.admit($0) }
    #expect(sent.isEmpty)
  }

  @Test func aSingleKeyStepCrossesTheBandFromAnywhereInsideIt() {
    // Worst case: the residual is parked at the far edge of the band, against
    // the direction of the move. 0.0625 - 0.03 = 0.0325, still over 0.03.
    var band = SyncDeadband()
    #expect(band.admit(-(SyncDeadband.threshold - 1e-6)) == nil)
    let sent = band.admit(keyStep)
    #expect(sent != nil)
    #expect((sent ?? 0) > SyncDeadband.threshold)
  }

  @Test func aRampInSubThresholdStepsTracksToItsDestination() {
    var band = SyncDeadband()
    let step = 0.01
    let ticks = 20
    let sent = (0..<ticks).compactMap { _ in band.admit(step) }
    let travelled = Double(ticks) * step

    // It tracks: the band can hold back at most one band's worth, never more.
    #expect(sent.reduce(0, +) > travelled - SyncDeadband.threshold)
    // And it re-centres, so a long ramp arrives as repeated band-sized steps
    // rather than one send and then silence.
    #expect(sent.count >= 6)
    for delta in sent {
      #expect(delta >= SyncDeadband.threshold)
      #expect(delta < SyncDeadband.threshold + step)
    }
  }

  /// Conservation: what was sent plus what is still held equals the source's
  /// whole movement. This is the invariant that keeps repeated ramps honest.
  @Test func whatIsSentPlusWhatIsHeldEqualsTheMovementObserved() {
    var band = SyncDeadband()
    let deltas = huntingSequence + Array(repeating: 0.01, count: 20) + huntingSequence
    var sentTotal = 0.0
    for delta in deltas {
      sentTotal += band.admit(delta) ?? 0
    }
    #expect(close(sentTotal + band.held, deltas.reduce(0, +), 1e-12))
    #expect(abs(band.held) < SyncDeadband.threshold)
  }

  @Test func aReversalUnwindsTheResidualInsteadOfLatchingIt() {
    var band = SyncDeadband()
    #expect(band.admit(0.02) == nil)
    #expect(band.admit(-0.02) == nil)
    #expect(band.held == 0)
  }

  @Test func resetDropsWhatWasHeld() {
    var band = SyncDeadband()
    #expect(band.admit(0.02) == nil)
    band.reset()
    #expect(band.held == 0)
    #expect(band.admit(0.02) == nil) // the dropped 0.02 is not replayed
  }
}

// MARK: - Fan-out with the deadband in place

@MainActor
@Suite("Brightness sync deadband fan-out")
struct BrightnessSyncDeadbandTests {
  private func makeTrio() -> (source: Harness, external: Harness, builtIn: Harness) {
    (
      Harness(),
      Harness(),
      Harness(withHDR: false, role: .builtIn, readNative: { _ in 0.6 })
    )
  }

  /// The acceptance contract: zero writes, not merely fewer.
  @Test func ambientHuntingOnTheSourceProducesNoFanOutAndNoWrites() async {
    let (source, external, builtIn) = makeTrio()
    external.controller.setBrightness(0.75)
    builtIn.controller.setBrightness(0.6)
    let controllers = [source.controller, external.controller, builtIn.controller]
    let externalWrites = external.submitted.count
    let builtInWrites = builtIn.submitted.count

    for delta in huntingSequence {
      BrightnessSync.fanOut(delta: delta, from: source.controller, to: controllers, isEnabled: true)
    }

    #expect(external.controller.brightness == 0.75)
    #expect(builtIn.controller.brightness == 0.6)
    #expect(external.submitted.count == externalWrites)
    #expect(builtIn.submitted.count == builtInWrites)
  }

  @Test func aDeliberateStepStillPropagates() async {
    let (source, external, _) = makeTrio()
    external.controller.setBrightness(0.75)
    let controllers = [source.controller, external.controller]
    let writes = external.submitted.count

    BrightnessSync.fanOut(delta: keyStep, from: source.controller, to: controllers, isEnabled: true)

    #expect(close(external.controller.brightness, 0.75 + keyStep))
    #expect(external.submitted.count == writes + 1)
  }

  /// A slow deliberate ramp arriving in steps that are each below the band
  /// still reaches its destination: the deadband holds back at most one band.
  @Test func aRampArrivingInSubThresholdStepsStillTracks() async {
    let (source, external, _) = makeTrio()
    external.controller.setBrightness(0.5)
    let controllers = [source.controller, external.controller]

    for _ in 0..<20 {
      BrightnessSync.fanOut(delta: 0.01, from: source.controller, to: controllers, isEnabled: true)
    }

    #expect(external.controller.brightness > 0.5 + 0.20 - SyncDeadband.threshold)
    #expect(external.controller.brightness <= 0.70 + 1e-9)
  }

  /// Hunting AROUND a deliberate change: the change lands, and the hunting
  /// that follows it does not, because the band re-centred on what was sent.
  @Test func theBandRecentresOnWhatWasFannedOut() async {
    let (source, external, _) = makeTrio()
    external.controller.setBrightness(0.5)
    let controllers = [source.controller, external.controller]

    for delta in huntingCycle {
      BrightnessSync.fanOut(delta: delta, from: source.controller, to: controllers, isEnabled: true)
    }
    BrightnessSync.fanOut(delta: keyStep, from: source.controller, to: controllers, isEnabled: true)
    let afterStep = external.controller.brightness
    let writes = external.submitted.count
    for delta in huntingSequence {
      BrightnessSync.fanOut(delta: delta, from: source.controller, to: controllers, isEnabled: true)
    }

    #expect(external.controller.brightness == afterStep)
    #expect(external.submitted.count == writes)
  }

  /// Toggled off mid-stream: movement observed while sync was off belongs to
  /// the period it happened in, so turning sync back on must not replay it.
  @Test func movementObservedWhileSyncIsOffIsNotReplayedWhenItReturns() async {
    let (source, external, _) = makeTrio()
    external.controller.setBrightness(0.5)
    let controllers = [source.controller, external.controller]

    // Enough movement while off to fill the band several times over.
    for _ in 0..<20 {
      BrightnessSync.fanOut(delta: 0.02, from: source.controller, to: controllers, isEnabled: false)
    }
    #expect(external.controller.brightness == 0.5)

    // Back on: only movement observed from here counts, and it is still
    // deadbanded rather than starting from a full band.
    BrightnessSync.fanOut(delta: 0.02, from: source.controller, to: controllers, isEnabled: true)
    #expect(external.controller.brightness == 0.5)
    BrightnessSync.fanOut(delta: 0.02, from: source.controller, to: controllers, isEnabled: true)
    #expect(close(external.controller.brightness, 0.54))
  }

  /// The band is the SOURCE's, so two sources hunting independently cannot
  /// pool their residuals into a fan-out neither of them earned.
  @Test func eachSourceCarriesItsOwnBand() async {
    let (first, external, _) = makeTrio()
    let second = Harness()
    external.controller.setBrightness(0.5)

    BrightnessSync.fanOut(
      delta: 0.02, from: first.controller,
      to: [first.controller, second.controller, external.controller], isEnabled: true
    )
    BrightnessSync.fanOut(
      delta: 0.02, from: second.controller,
      to: [first.controller, second.controller, external.controller], isEnabled: true
    )

    #expect(external.controller.brightness == 0.5)
  }
}
