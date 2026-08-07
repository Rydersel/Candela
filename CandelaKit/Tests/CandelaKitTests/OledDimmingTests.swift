import Testing
@testable import CandelaKit

@Suite("OLED idle dimming state machine")
struct OledDimmingTests {
  private func config(
    idle: Double = 300, level: Double = 0.5, lock: Bool = true,
    blackout: Bool = false, blackoutAt: Double = 1200,
    unfocused: Bool = false, unfocusedAt: Double = 600, unfocusedLevel: Double = 0.7
  ) -> OledDimConfig {
    OledDimConfig(idleDimSeconds: idle, idleDimLevel: level, lockDim: lock,
                  blackoutEnabled: blackout, blackoutSeconds: blackoutAt,
                  unfocusedDimEnabled: unfocused, unfocusedDimSeconds: unfocusedAt,
                  unfocusedDimLevel: unfocusedLevel)
  }
  private func signals(
    idle: Double, assertion: Bool = false, locked: Bool = false,
    mirrored: Bool = false, settling: Bool = false, unfocused: Double? = nil
  ) -> OledDimSignals {
    OledDimSignals(idleSeconds: idle, assertionHeld: assertion, isLocked: locked,
                   isMirrored: mirrored, isHDRSettling: settling, unfocusedSeconds: unfocused)
  }

  @Test func idleThresholdDims() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.tick(signals(idle: 299)) == .active)
    #expect(e.tick(signals(idle: 300)) == .idleDim)
  }

  @Test func assertionSuppressesEveryGatedEntry() {
    var e = IdleDimmingEngine(config: config(blackout: true, unfocused: true))
    #expect(e.tick(signals(idle: 400, assertion: true)) == .active)
    #expect(e.tick(signals(idle: 2000, assertion: true)) == .active)
    #expect(e.tick(signals(idle: 10, assertion: true, unfocused: 700)) == .active)
  }

  @Test func inputRestoresInstantly() {
    var e = IdleDimmingEngine(config: config())
    _ = e.tick(signals(idle: 400))
    #expect(e.tick(signals(idle: 0)) == .active)
  }

  @Test func blackoutFollowsIdleDim() {
    var e = IdleDimmingEngine(config: config(blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 500)) == .idleDim)
    #expect(e.tick(signals(idle: 1200)) == .blackout)
    #expect(e.tick(signals(idle: 1)) == .active)
  }

  @Test func blackoutClampsAboveIdleThreshold() {
    var e = IdleDimmingEngine(config: config(idle: 300, blackout: true, blackoutAt: 100))
    // Sanitized: blackout cannot fire below idle threshold.
    #expect(e.tick(signals(idle: 300)) == .idleDim)
    #expect(e.tick(signals(idle: 359)) == .idleDim)
    #expect(e.tick(signals(idle: 360)) == .blackout)
  }

  @Test func lockEdgeDimsImmediately() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock(idleSeconds: 1)
    #expect(e.tick(signals(idle: 1, locked: true)) == .lockDim)
  }

  /// The live defect: a fresh engine has `lastIdleSeconds == 0`, so the old
  /// test could not see the fall that a real lock always produces. Locking is
  /// itself input (a shortcut, a menu click, a hot corner), so on a warm engine
  /// the idle counter DROPS at the lock edge, and reading that drop as "input
  /// while locked" lifted the dim on the same tick that armed it.
  @Test func lockEdgeDimsOnAWarmEngineWhoseIdleCounterJustFell() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.tick(signals(idle: 42)) == .active)  // user reading, engine warm
    e.noteLock(idleSeconds: 0.2)                   // the lock shortcut IS input
    #expect(e.tick(signals(idle: 0.3, locked: true)) == .lockDim)
  }

  /// The lift must still work for input that lands AFTER the lock, including
  /// input in the same window as the lock edge: the baseline is the reading at
  /// the lock, so a later, lower count is real.
  @Test func inputAfterTheLockEdgeStillLifts() {
    var e = IdleDimmingEngine(config: config())
    _ = e.tick(signals(idle: 42))
    e.noteLock(idleSeconds: 5)
    #expect(e.tick(signals(idle: 0.1, locked: true)) == .active)
  }

  @Test func inputWhileLockedLiftsThenRearms() {
    var e = IdleDimmingEngine(config: config(idle: 300))
    e.noteLock(idleSeconds: 5)
    _ = e.tick(signals(idle: 5, locked: true))
    #expect(e.tick(signals(idle: 1, locked: true)) == .active)     // typing password
    #expect(e.tick(signals(idle: 299, locked: true)) == .active)
    #expect(e.tick(signals(idle: 300, locked: true)) == .lockDim)  // re-armed by idle
  }

  @Test func wakeBeatsLock() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock(idleSeconds: 5)
    _ = e.tick(signals(idle: 5, locked: true))
    e.noteWake()
    #expect(e.tick(signals(idle: 6, locked: true)) == .active)
    // Re-arms 300 s after the WAKE, not 300 s on a counter that started before
    // it — the wake floor is 6 here (fix round 1, FINDING C).
    #expect(e.tick(signals(idle: 306, locked: true)) == .lockDim)
  }

  @Test func unlockReturnsToActive() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock(idleSeconds: 5)
    _ = e.tick(signals(idle: 5, locked: true))
    e.noteUnlock()
    #expect(e.tick(signals(idle: 6)) == .active)
  }

  @Test func lockDimRespectsItsToggle() {
    var e = IdleDimmingEngine(config: config(lock: false))
    e.noteLock(idleSeconds: 5)
    #expect(e.tick(signals(idle: 5, locked: true)) == .active)
  }

  @Test func unfocusedDimsAndExitsOnlyOnFocus() {
    var e = IdleDimmingEngine(config: config(unfocused: true, unfocusedAt: 600))
    #expect(e.tick(signals(idle: 10, unfocused: 599)) == .active)
    #expect(e.tick(signals(idle: 10, unfocused: 600)) == .unfocusedDim)
    // Global input alone does NOT exit unfocused dim:
    #expect(e.tick(signals(idle: 0, unfocused: 601)) == .unfocusedDim)
    // Focus arrival exits:
    #expect(e.tick(signals(idle: 0, unfocused: nil)) == .active)
  }

  @Test func idleDimOutranksUnfocusedDim() {
    var e = IdleDimmingEngine(config: config(unfocused: true))
    #expect(e.tick(signals(idle: 400, unfocused: 700)) == .idleDim)
  }

  @Test func mirroringSuspendsAndResumes() {
    var e = IdleDimmingEngine(config: config())
    _ = e.tick(signals(idle: 400))
    #expect(e.tick(signals(idle: 401, mirrored: true)) == .suspended)
    #expect(e.tick(signals(idle: 402)) == .idleDim)
  }

  @Test func lockedWhileMirroredStaysSuspended() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock(idleSeconds: 5)
    #expect(e.tick(signals(idle: 5, locked: true, mirrored: true)) == .suspended)
  }

  @Test func hdrSettleDefersEntryButNotExit() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.tick(signals(idle: 400, settling: true)) == .active)   // entry deferred
    _ = e.tick(signals(idle: 401))                                    // dims
    #expect(e.tick(signals(idle: 402, settling: true)) == .idleDim)  // no forced exit
  }

  @Test func alphaMapping() {
    let e = IdleDimmingEngine(config: config(level: 0.5, unfocusedLevel: 0.7))
    #expect(e.alpha(for: .idleDim) == 0.5)
    #expect(e.alpha(for: .lockDim) == 0.5)
    #expect(e.alpha(for: .blackout) == 1.0)
    #expect(e.alpha(for: .unfocusedDim) == 0.7)
    #expect(e.alpha(for: .active) == nil)
    #expect(e.alpha(for: .suspended) == nil)
  }

  /// All eight prefs get distinct values: with defaults left in place a
  /// transposed pair (blackout seconds ↔ unfocused seconds, either level into
  /// the other) reads correct. The two enable flags must DIFFER from each other
  /// here — both true, as this test first had it, is transposable against a
  /// defaults test where both are false.
  @Test func configFromPrefsReadsTask1Accessors() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    prefs.oledIdleDimSeconds = 120
    prefs.oledIdleDimLevel = 0.3
    prefs.oledLockDim = false
    prefs.oledBlackoutEnabled = true
    prefs.oledBlackoutSeconds = 900
    prefs.oledUnfocusedDimEnabled = false
    prefs.oledUnfocusedDimSeconds = 450
    prefs.oledUnfocusedDimLevel = 0.8

    let c = OledDimConfig(prefs: prefs)
    #expect(c.idleDimSeconds == 120)
    #expect(c.idleDimLevel == 0.3)
    #expect(c.lockDim == false)
    #expect(c.blackoutEnabled == true)
    #expect(c.blackoutSeconds == 900)
    #expect(c.unfocusedDimEnabled == false)
    #expect(c.unfocusedDimSeconds == 450)
    #expect(c.unfocusedDimLevel == 0.8)
  }

  /// The default prefs ARE the Recommended preset (Task 1), so an un-tuned
  /// display's config must survive every sanitization untouched.
  @Test func presetDefaultsSurviveSanitizationUnchanged() {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "pk")
    let c = OledDimConfig(prefs: prefs)
    #expect(c.idleDimSeconds == 300)
    #expect(c.idleDimLevel == 0.5)
    #expect(c.lockDim == true)
    #expect(c.blackoutEnabled == false)
    #expect(c.blackoutSeconds == 1200)
    #expect(c.unfocusedDimEnabled == false)
    #expect(c.unfocusedDimSeconds == 600)
    // Lighter than `idleDimLevel`: the level is the overlay's opacity, so
    // higher is darker, and an unfocused display is still in the user's view.
    #expect(c.unfocusedDimLevel == 0.3)
  }

  // MARK: - Additions beyond the brief

  /// Task 1 review carry-in: dim levels were unclamped through the whole chain
  /// (pref accessor → config → alpha → overlay). A 0.0 dim is a no-op and a 1.0
  /// dim is an unannounced blackout that does not swallow its waking click
  /// (OC15) — both are config errors, so the config is where they die.
  @Test func dimLevelsClampToUsableRange() {
    let tooDark = config(level: 1.0, unfocusedLevel: 4.2)
    #expect(tooDark.idleDimLevel == 0.9)
    #expect(tooDark.unfocusedDimLevel == 0.9)

    let tooLight = config(level: 0.0, unfocusedLevel: -1)
    #expect(tooLight.idleDimLevel == 0.1)
    #expect(tooLight.unfocusedDimLevel == 0.1)

    let inRange = config(level: 0.5, unfocusedLevel: 0.7)
    #expect(inRange.idleDimLevel == 0.5)
    #expect(inRange.unfocusedDimLevel == 0.7)

    // The clamp is only worth anything if it reaches the overlay's alpha.
    let e = IdleDimmingEngine(config: tooDark)
    #expect(e.alpha(for: .idleDim) == 0.9)
    #expect(e.alpha(for: .unfocusedDim) == 0.9)
  }

  /// A naive `min(max(…))` passes NaN straight through — and a NaN alpha is an
  /// undefined overlay, not a visible error.
  @Test func nonFiniteDimLevelsResolveInsideTheRange() {
    let nan = config(level: .nan, unfocusedLevel: .nan)
    #expect((0.1...0.9).contains(nan.idleDimLevel))
    #expect((0.1...0.9).contains(nan.unfocusedDimLevel))

    let infinite = config(level: .infinity, unfocusedLevel: -.infinity)
    #expect(infinite.idleDimLevel == 0.9)
    #expect(infinite.unfocusedDimLevel == 0.1)
  }

  /// `updateConfig` is how a pref change reaches a live engine (Task 7's
  /// `reapplyAfterPrefChange`); an engine that kept its original config would
  /// pass every other test here.
  @Test func updateConfigRetargetsThresholdAndLevel() {
    var e = IdleDimmingEngine(config: config(idle: 300, level: 0.5))
    #expect(e.tick(signals(idle: 200)) == .active)
    e.updateConfig(config(idle: 120, level: 0.4))
    #expect(e.tick(signals(idle: 200)) == .idleDim)
    #expect(e.alpha(for: .idleDim) == 0.4)
  }

  @Test func stateMirrorsTheLastTick() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.state == .active)
    let returned = e.tick(signals(idle: 400))
    #expect(e.state == returned)
    #expect(e.state == .idleDim)
  }

  // MARK: - Review round 1

  /// RULING A: the assertion gates ENTRY only, uniformly. An app taking
  /// `PreventUserIdleDisplaySleep` while a dim is already up must not make the
  /// display flash back to full brightness.
  @Test func anAssertionMidDimHoldsTheDimButBlocksEscalation() {
    var e = IdleDimmingEngine(config: config(blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 400)) == .idleDim)
    #expect(e.tick(signals(idle: 401, assertion: true)) == .idleDim)   // holds
    #expect(e.tick(signals(idle: 1300, assertion: true)) == .idleDim)  // no new entry
    #expect(e.tick(signals(idle: 1301)) == .blackout)                  // assertion gone
    #expect(e.tick(signals(idle: 1302, assertion: true)) == .blackout) // holds
  }

  @Test func anAssertionMidUnfocusedDimHoldsIt() {
    var e = IdleDimmingEngine(config: config(unfocused: true))
    #expect(e.tick(signals(idle: 10, unfocused: 700)) == .unfocusedDim)
    #expect(e.tick(signals(idle: 11, assertion: true, unfocused: 701)) == .unfocusedDim)
  }

  /// FINDING B: with the entry gate uniform, the sticky branch is gone — a
  /// dropped unfocused counter (focus arrived and left between two ticks) exits.
  @Test func unfocusedDimExitsWhenItsCounterDrops() {
    var e = IdleDimmingEngine(config: config(unfocused: true, unfocusedAt: 600))
    #expect(e.tick(signals(idle: 10, unfocused: 700)) == .unfocusedDim)
    #expect(e.tick(signals(idle: 11, unfocused: 3)) == .active)
  }

  /// FINDING B: turning the feature off while its overlay is up must remove it
  /// on the next tick, not on the next focus change.
  @Test func disablingUnfocusedDimExitsOnTheNextTick() {
    var e = IdleDimmingEngine(config: config(unfocused: true))
    #expect(e.tick(signals(idle: 10, unfocused: 700)) == .unfocusedDim)
    e.updateConfig(config(unfocused: false))
    #expect(e.tick(signals(idle: 11, unfocused: 701)) == .active)
  }

  /// FINDING C: the idle counter runs through system sleep, so a wake can
  /// deliver an hour of "idleness" the user never spent awake.
  @Test func wakeFloorsAStaleIdleCounterWhileLocked() {
    var e = IdleDimmingEngine(config: config(idle: 300))
    e.noteLock(idleSeconds: 400)
    #expect(e.tick(signals(idle: 400, locked: true)) == .lockDim)
    e.noteWake()
    #expect(e.tick(signals(idle: 3600, locked: true)) == .active)
    #expect(e.tick(signals(idle: 3600 + 299, locked: true)) == .active)
    #expect(e.tick(signals(idle: 3600 + 300, locked: true)) == .lockDim)
  }

  @Test func wakeFloorsAStaleIdleCounterUnlocked() {
    var e = IdleDimmingEngine(config: config(idle: 300))
    #expect(e.tick(signals(idle: 400)) == .idleDim)
    e.noteWake()
    #expect(e.tick(signals(idle: 3600)) == .active)
    #expect(e.tick(signals(idle: 3600 + 299)) == .active)
    #expect(e.tick(signals(idle: 3600 + 300)) == .idleDim)
  }

  @Test func wakeFloorAlsoDefersBlackout() {
    var e = IdleDimmingEngine(config: config(idle: 300, blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 1300)) == .blackout)
    e.noteWake()
    #expect(e.tick(signals(idle: 7200)) == .active)
    #expect(e.tick(signals(idle: 7200 + 1199)) == .idleDim)
    #expect(e.tick(signals(idle: 7200 + 1200)) == .blackout)
  }

  /// Real input after a wake makes the counter honest again, so the floor must
  /// not keep suppressing the dim for the rest of the session.
  @Test func inputAfterWakeClearsTheFloor() {
    var e = IdleDimmingEngine(config: config(idle: 300))
    e.noteWake()
    #expect(e.tick(signals(idle: 3600)) == .active)
    #expect(e.tick(signals(idle: 5)) == .active)     // a real event
    #expect(e.tick(signals(idle: 305)) == .idleDim)  // measured from it, not the wake
  }

  /// RULING D: locking never brightens. Dropping a blacked-out display to lock
  /// dim's lighter alpha is a brightness increase nobody asked for.
  @Test func lockingNeverBrightensABlackout() {
    var e = IdleDimmingEngine(config: config(blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 1300)) == .blackout)
    e.noteLock(idleSeconds: 1300)
    #expect(e.tick(signals(idle: 1301, locked: true)) == .blackout)
    #expect(e.tick(signals(idle: 2, locked: true)) == .active)  // input still lifts
  }

  /// Round 2: the hold re-checks its own condition, so a wake escapes it with no
  /// HID event at all — "wake always lands `.active`" outranks "never brightens".
  @Test func wakeEscapesAHeldBlackoutWhileLocked() {
    var e = IdleDimmingEngine(config: config(idle: 300, blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 1300)) == .blackout)
    e.noteLock(idleSeconds: 1300)
    #expect(e.tick(signals(idle: 1301, locked: true)) == .blackout)
    e.noteWake()
    // The counter still reads hours — sleep does not reset it — but none of it
    // was spent awake, so the lock screen comes up lit.
    #expect(e.tick(signals(idle: 7200, locked: true)) == .active)
    #expect(e.tick(signals(idle: 7200 + 299, locked: true)) == .active)
    #expect(e.tick(signals(idle: 7200 + 300, locked: true)) == .lockDim)
  }

  /// Round 2: the same re-check is what lets the toggle reach a locked screen.
  @Test func disablingBlackoutWhileLockedExitsTheHold() {
    var e = IdleDimmingEngine(config: config(blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 1300)) == .blackout)
    e.noteLock(idleSeconds: 1300)
    #expect(e.tick(signals(idle: 1301, locked: true)) == .blackout)
    e.updateConfig(config(blackout: false))
    #expect(e.tick(signals(idle: 1302, locked: true)) == .lockDim)
  }

  /// RULING F: lock dim is exempt from the HDR-settle deferral — a full-bright
  /// lock screen during a settle is the worse outcome, and locking is an
  /// explicit user action rather than an inferred idle.
  @Test func lockEdgeDimsEvenDuringHDRSettle() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock(idleSeconds: 1)
    #expect(e.tick(signals(idle: 1, locked: true, settling: true)) == .lockDim)
  }

  /// FINDING E: sub-30 s thresholds mean "dimmed always", and the blackout row
  /// derives from the idle one — so an unfloored idle threshold is how a
  /// display blacks out at zero idle with nothing to recover it.
  @Test func secondsThresholdsHaveFloors() {
    let c = OledDimConfig(idleDimSeconds: 0, idleDimLevel: 0.5, lockDim: true,
                          blackoutEnabled: true, blackoutSeconds: -100,
                          unfocusedDimEnabled: true, unfocusedDimSeconds: 5,
                          unfocusedDimLevel: 0.7)
    #expect(c.idleDimSeconds == 30)
    #expect(c.unfocusedDimSeconds == 30)
    #expect(c.blackoutSeconds == 90)  // floored idle + 60, not -100

    // Boundary: a threshold already above the floor is untouched.
    let ok = OledDimConfig(idleDimSeconds: 30, idleDimLevel: 0.5, lockDim: true,
                           blackoutEnabled: false, blackoutSeconds: 5000,
                           unfocusedDimEnabled: false, unfocusedDimSeconds: 31,
                           unfocusedDimLevel: 0.7)
    #expect(ok.idleDimSeconds == 30)
    #expect(ok.unfocusedDimSeconds == 31)
    #expect(ok.blackoutSeconds == 5000)
  }

  /// Round 2: `max(NaN, floor)` returns NaN, which reads as "floored" while
  /// disabling the row it belongs to — every `>=` against it is false.
  @Test func nonFiniteSecondsFallBackToTheFloor() {
    let c = OledDimConfig(idleDimSeconds: .nan, idleDimLevel: 0.5, lockDim: true,
                          blackoutEnabled: true, blackoutSeconds: .nan,
                          unfocusedDimEnabled: true, unfocusedDimSeconds: .nan,
                          unfocusedDimLevel: 0.7)
    #expect(c.idleDimSeconds == 30)
    #expect(c.blackoutSeconds == 90)  // the floored idle threshold + 60
    #expect(c.unfocusedDimSeconds == 30)
  }

  @Test func aNegativeBlackoutCannotFireAtZeroIdle() {
    var e = IdleDimmingEngine(config: OledDimConfig(
      idleDimSeconds: 0, idleDimLevel: 0.5, lockDim: true,
      blackoutEnabled: true, blackoutSeconds: -100,
      unfocusedDimEnabled: false, unfocusedDimSeconds: 600, unfocusedDimLevel: 0.7))
    #expect(e.tick(signals(idle: 0)) == .active)
    #expect(e.tick(signals(idle: 29)) == .active)
    #expect(e.tick(signals(idle: 30)) == .idleDim)
    #expect(e.tick(signals(idle: 89)) == .idleDim)
    #expect(e.tick(signals(idle: 90)) == .blackout)
  }
}
