import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The engine half of the wire degradation: what the controller does with
/// `DDCWireHealth`, which applies reach it, and every route back.
///
/// `DDCWireHealthTests` pins the counting rule itself. The two defects these
/// guard are a demotion no route undoes, and one that fires on an HDR window.
@Suite("DDC wire degradation (WD1, WD3, WD4)")
@MainActor
struct DDCWireDegradationTests {
  /// Drives the wire until it has failed `count` applies, then waits for the
  /// verdict. Distinct values on purpose: a repeat of the target already on the
  /// wire is duplicate-skipped, and a skip asks the panel nothing.
  private func failWrites(_ harness: Harness, count: Int, from start: Double = 0.9) async {
    for step in 0 ..< count {
      harness.controller.setBrightness(start - Double(step) * 0.05)
      await harness.controller.waitForPendingWrites()
    }
    await harness.controller.wireHealthWatch?.value
  }

  @Test func aWireThatKeepsAnsweringIsNeverDemoted() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    for step in 0 ..< 10 {
      harness.controller.setBrightness(0.9 - Double(step) * 0.05)
      await harness.controller.waitForPendingWrites()
    }
    await harness.controller.wireHealthWatch?.value
    #expect(!harness.controller.isWireUnresponsive)
  }

  /// The MAG341C's shape, and why WD1 keys on writes: it answers every read with
  /// zeros and honours every write. The read verdict is asserted beside the
  /// health to show they are separate facts.
  @Test func aWriteOnlyPanelWhoseWritesLandIsNeverDemoted() async {
    let harness = Harness(ddcRead: (current: 0, max: 0), withHDR: false)
    await harness.prime()
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)
    for step in 0 ..< 10 {
      harness.controller.setBrightness(0.9 - Double(step) * 0.05)
      await harness.controller.waitForPendingWrites()
    }
    await harness.controller.wireHealthWatch?.value
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .combined(switchingValue: 0.5, backend: .gamma))
  }

  @Test func twoFailedWritesAreNotEnoughToDemote() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 2)
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .combined(switchingValue: 0.5, backend: .gamma))
  }

  /// The slider stops claiming a hardware leg; the software leg carries what it
  /// can.
  @Test func threeFailedWritesDemoteTheDisplayToTheSoftwareLeg() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath
      == .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.5))
  }

  /// A success in between means the wire is carrying commands, so the count
  /// starts again. Pinned through the engine, not only the value type.
  @Test func aSuccessBetweenFailuresKeepsTheDisplayOnItsHardwareLeg() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 2)
    await harness.ddc.setWritesSucceed(true)
    harness.controller.setBrightness(0.7)
    await harness.controller.waitForPendingWrites()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 2, from: 0.65)
    #expect(!harness.controller.isWireUnresponsive)
  }

  /// WD4 and D28. Pure-DDC configuration is where the shortcut shows: a
  /// `handleReconfigure` returns before applying anything, so a display demoted
  /// through that door keeps a slider that moves nothing.
  @Test func theTransitionRunsTheFullReEvaluationEvenInPureDDCMode() async {
    let harness = Harness(withHDR: false) { prefs, _ in
      prefs.disableCombinedBrightness = true
    }
    await harness.prime()
    harness.controller.setBrightness(0.6)
    await harness.controller.waitForPendingWrites()
    #expect(harness.gamma.scales.isEmpty) // pure DDC writes no software leg

    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3, from: 0.55)
    #expect(harness.controller.isWireUnresponsive)
    // Full range, not a partial band: there is no combined split to respect.
    #expect(harness.controller.brightnessPath == .software(.gamma))
    // The software leg is actually installed, which is the half a bare
    // `handleReconfigure` would have skipped.
    #expect(harness.gamma.scales.last != nil)
    #expect(harness.gamma.scales.last != 1.0)
  }

  /// WD3, route one: a reconfiguration rebuilt the display's state, so the wire
  /// is asked again rather than staying demoted on writes made before it.
  @Test func aReconfigurationGivesTheWireAFreshHearing() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)

    await harness.ddc.setWritesSucceed(true)
    await harness.controller.handleReconfigure()
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .combined(switchingValue: 0.5, backend: .gamma))
  }

  /// WD3, route two: no replug and no relaunch, which is the whole difference
  /// from the implementation this design is specified against.
  @Test func wakeGivesTheWireAFreshHearing() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)

    await harness.ddc.setWritesSucceed(true)
    harness.controller.noteWake()
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .combined(switchingValue: 0.5, backend: .gamma))
  }

  /// WD3, route three, through the door somebody else opens: HDR switched on in
  /// System Settings and off again. A display must not be left demoted by a
  /// failure inside that window.
  @Test func anHDRRoundTripInSystemSettingsGivesTheWireAFreshHearing() async {
    let harness = Harness(settle: .milliseconds(5))
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)

    // The measured read is how the backend's cache catches up with a toggle it
    // did not make; without it the mirror is stale by design.
    await harness.hdr?.stubEnabled(true)
    _ = await harness.hdr?.measuredHDREnabled(displayID: Harness.displayID)
    await harness.controller.noteHDRStateMayHaveChanged()
    #expect(harness.controller.brightnessPath == .native)

    await harness.ddc.setWritesSucceed(true)
    await harness.hdr?.stubEnabled(false)
    _ = await harness.hdr?.measuredHDREnabled(displayID: Harness.displayID)
    await harness.controller.noteHDRStateMayHaveChanged()
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .combined(switchingValue: 0.5, backend: .gamma))
  }

  /// The same round trip through Candela's own HDR door, where the observer sees
  /// no edge: the mirror moves with the call, so the transition resets.
  @Test func ourOwnHDRRoundTripGivesTheWireAFreshHearing() async {
    let harness = Harness(settle: .milliseconds(5))
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)

    await harness.controller.setHDRMode(.alwaysOn)
    #expect(harness.controller.brightnessPath == .native)

    await harness.ddc.setWritesSucceed(true)
    await harness.controller.setHDRMode(.off)
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .combined(switchingValue: 0.5, backend: .gamma))
  }

  /// Two failures before an HDR window and two after are not a run: the register
  /// was locked in the middle, so nobody could write to the wire.
  @Test func anHDRWindowClearsWhatTheWireHadEarnedBeforeIt() async {
    let harness = Harness(settle: .milliseconds(5))
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 2)

    await harness.controller.setHDRMode(.alwaysOn)
    await harness.controller.setHDRMode(.off)

    await failWrites(harness, count: 2, from: 0.75)
    #expect(!harness.controller.isWireUnresponsive)
  }

  /// The built-in routes native, so nothing it does is evidence about a cable it
  /// does not have.
  @Test func theBuiltInPanelIsNeverDemoted() async {
    let harness = Harness(withHDR: false, role: .builtIn)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 5)
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .native)
  }

  /// WD2's ordering, asserted through the engine so the pane cannot be told the
  /// other story: a command the user turned off is reported as turned off.
  @Test func theUsersOwnSwitchStillOutranksTheWireInTheEngine() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)

    harness.prefs.setTuning(
      CommandTuning(
        unavailableDDC: true, minDDCOverride: 0, maxDDCOverride: 0,
        curveIndex: 0, invert: false, remapCodes: []
      ),
      for: .brightness
    )
    #expect(harness.controller.brightnessPath
      == .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.5))
  }
}

/// The coalescer's half: which applies reach the health at all. Here rather than
/// in the coalescer suite because the rule being pinned is WD1's, not the queue's.
@Suite("What counts against the wire (WD1)")
struct WireHealthEvidenceTests {
  @Test func aFailedDDCApplyCountsAgainstTheWire() async {
    let applier = RecordingApplier(scriptedResults: [false, false, false])
    let coalescer = BrightnessWriteCoalescer()
    for generation in UInt64(1) ... 3 {
      coalescer.submit(.init(
        target: .ddc(raw: UInt16(generation)), applier: applier,
        epoch: 0, generation: generation
      ))
      await coalescer.waitUntilCompleted(through: generation)
    }
    #expect(coalescer.wireHealth().isUnresponsive)
    coalescer.finishSubmissions()
  }

  /// The HDR stamp drops the attempt. Crisp fires here, on a register that is
  /// locked by design and unlocks itself.
  @Test func aFailedApplyStampedHDRExcludedNeverReachesTheHealth() async {
    let applier = RecordingApplier(scriptedResults: [false, false, false, false, false])
    let coalescer = BrightnessWriteCoalescer()
    for generation in UInt64(1) ... 5 {
      coalescer.submit(.init(
        target: .ddc(raw: UInt16(generation)), applier: applier,
        epoch: 0, generation: generation, hdrExcluded: true
      ))
      await coalescer.waitUntilCompleted(through: generation)
    }
    #expect(coalescer.wireHealth().consecutiveFailures == 0)
    coalescer.finishSubmissions()
  }

  /// A native apply says nothing about a wire the native path does not use.
  @Test func failedNativeAppliesAreNotEvidenceAboutTheWire() async {
    // A real native applier over a closure that refuses: `RecordingApplier`
    // only accepts DDC, so a mismatched pairing fails for the wrong reason.
    let applier = NativeBrightnessApplier(displayID: 1) { _, _ in false }
    let coalescer = BrightnessWriteCoalescer()
    for generation in UInt64(1) ... 3 {
      coalescer.submit(.init(
        target: .native(Float(generation) / 10), applier: applier,
        epoch: 0, generation: generation
      ))
      await coalescer.waitUntilCompleted(through: generation)
    }
    #expect(coalescer.wireHealth().consecutiveFailures == 0)
    coalescer.finishSubmissions()
  }

  /// A duplicate skip asks the panel nothing, so a run of them must not clear a
  /// count the wire earned.
  @Test func aDuplicateSkipIsNotASuccess() async {
    let applier = RecordingApplier(scriptedResults: [true, false, false])
    let coalescer = BrightnessWriteCoalescer()
    coalescer.submit(.init(target: .ddc(raw: 9), applier: applier, epoch: 0, generation: 1))
    await coalescer.waitUntilCompleted(through: 1)
    coalescer.submit(.init(target: .ddc(raw: 4), applier: applier, epoch: 0, generation: 2))
    await coalescer.waitUntilCompleted(through: 2)
    coalescer.submit(.init(target: .ddc(raw: 4), applier: applier, epoch: 0, generation: 3))
    await coalescer.waitUntilCompleted(through: 3)
    // Raw 9 landed, raw 4 failed twice; the third submit repeats a target that
    // never landed, so it is applied rather than skipped. No skip cleared the count.
    #expect(coalescer.wireHealth().consecutiveFailures == 2)
    coalescer.finishSubmissions()
  }

  /// The duplicate memo resets on every re-apply and dim step, where the hardware
  /// state is unknown but the wire's record is not.
  @Test func aDuplicateMemoResetLeavesTheWiresRecordAlone() async {
    let applier = RecordingApplier(scriptedResults: [false, false, false])
    let coalescer = BrightnessWriteCoalescer()
    for generation in UInt64(1) ... 3 {
      coalescer.submit(.init(
        target: .ddc(raw: UInt16(generation)), applier: applier,
        epoch: 0, generation: generation
      ))
      await coalescer.waitUntilCompleted(through: generation)
    }
    coalescer.resetDuplicateState()
    #expect(coalescer.wireHealth().isUnresponsive)
    coalescer.resetWireHealth()
    #expect(!coalescer.wireHealth().isUnresponsive)
    coalescer.finishSubmissions()
  }
}
