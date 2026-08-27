import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The engine half of the wire degradation: what the controller does with
/// `DDCWireHealth`, which applies reach it, and every route back.
///
/// `DDCWireHealthTests` pins the counting rule on its own. These are about the
/// WIRING, which is where the two anti-patterns live: a demotion that no route
/// undoes, and a demotion that fires on an HDR window.
@Suite("DDC wire degradation (WD1, WD3, WD4)")
@MainActor
struct DDCWireDegradationTests {
  /// Drives the wire until it has failed `count` applies, and waits for the
  /// verdict the last one produces.
  ///
  /// Distinct values on purpose: a repeat of the target already on the wire is
  /// duplicate-skipped, and a skip asks the panel nothing.
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

  /// The MAG341C's whole shape, and the reason WD1 keys on writes: it answers
  /// every read with zeros and honours every write. A rule keyed on read
  /// evidence would demote the panel it looks worst on, so the read verdict is
  /// asserted here beside the health to show they are separate facts.
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

  /// The demotion itself: the slider stops claiming a hardware leg and the
  /// software leg carries what it can.
  @Test func threeFailedWritesDemoteTheDisplayToTheSoftwareLeg() async {
    let harness = Harness(withHDR: false)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath
      == .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.5))
  }

  /// A success between the failures means the wire is carrying commands, so the
  /// count starts again: this is the anti-pattern of a bare failure counter,
  /// pinned through the engine rather than only through the value type.
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

  /// WD4 and D28. The re-evaluation has to be the one `reapplyAfterPrefChange`
  /// performs, and pure-DDC configuration is where the difference shows: a
  /// `handleReconfigure` here returns before applying anything, so a display
  /// demoted through that door would keep a slider that moves nothing while the
  /// app reported software dimming.
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

  /// WD3, route one. A reconfiguration rebuilt the display's state, so the wire
  /// is asked again rather than staying demoted on the strength of writes made
  /// before it.
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
  /// System Settings and switched off again. A DDC failure inside that window is
  /// expected and temporary, and a display must not be left demoted by one.
  @Test func anHDRRoundTripInSystemSettingsGivesTheWireAFreshHearing() async {
    let harness = Harness(settle: .milliseconds(5))
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 3)
    #expect(harness.controller.isWireUnresponsive)

    // The measured read is how the backend's own cache catches up with a toggle
    // it did not make; without it the mirror is stale by design.
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

  /// The same round trip through Candela's own HDR door, where the observer
  /// above sees no edge at all: the mirror moves with the call, so the reset has
  /// to be made by the transition itself.
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

  /// The count does not survive an HDR window either: two failures before it and
  /// two after are four failures with a locked register in the middle, which is
  /// not three in a row on a wire anybody could have written to.
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

  /// The built-in panel has no DDC wire at all: it routes native, so nothing it
  /// does can be evidence about a cable it does not have.
  @Test func theBuiltInPanelIsNeverDemoted() async {
    let harness = Harness(withHDR: false, role: .builtIn)
    await harness.prime()
    await harness.ddc.setWritesSucceed(false)
    await failWrites(harness, count: 5)
    #expect(!harness.controller.isWireUnresponsive)
    #expect(harness.controller.brightnessPath == .native)
  }

  /// A display the user turned the brightness command off for is reported as
  /// turned off, whatever the wire is doing behind the switch (WD2's ordering,
  /// asserted through the engine so the pane cannot be told the other story).
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

/// The coalescer's half: which applies reach the health at all. Kept here rather
/// than in the coalescer suite because the rule being pinned is WD1's, not the
/// queue's.
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

  /// The HDR stamp drops the attempt entirely. Crisp's version of this feature
  /// fires here, on a register that is locked by design and unlocks itself.
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
    // only accepts DDC, and a mismatched pairing would be rejected for the
    // wrong reason.
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

  /// A duplicate skip asks the panel nothing, so it is not a success: a run of
  /// them must not clear a count the wire earned.
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
    // never landed, so it is applied rather than skipped. What is pinned is that
    // no skip ever cleared the count.
    #expect(coalescer.wireHealth().consecutiveFailures == 2)
    coalescer.finishSubmissions()
  }

  /// The duplicate memo is reset on every re-apply and every dim step, where the
  /// hardware state is unknown but the wire's record is not. Clearing the health
  /// there would promote a dead cable back on the strength of a memo reset.
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
