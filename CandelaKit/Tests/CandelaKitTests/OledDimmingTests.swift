import Testing
@testable import CandelaKit

@Suite("OLED idle dimming state machine")
struct OledDimmingTests {
  private func config(
    idle: Double = 300, level: Double = 0.5, lock: Bool = true,
    blackout: Bool = false, blackoutAt: Double = 1200,
    unfocused: Bool = false, unfocusedAt: Double = 600, unfocusedLevel: Double = 0.7
  ) -> OledDimConfig {
    OledDimConfig(idleDimSeconds: idle, idleDimBrightness: level, lockDim: lock,
                  blackoutEnabled: blackout, blackoutSeconds: blackoutAt,
                  unfocusedDimEnabled: unfocused, unfocusedDimSeconds: unfocusedAt,
                  unfocusedDimBrightness: unfocusedLevel)
  }
  private func signals(
    idle: Double, assertion: Bool = false, locked: Bool = false,
    mirrored: Bool = false, settling: Bool = false, unfocused: Double? = nil,
    checkupField: Bool = false
  ) -> OledDimSignals {
    OledDimSignals(idleSeconds: idle, assertionHeld: assertion, isLocked: locked,
                   isMirrored: mirrored, isHDRSettling: settling, unfocusedSeconds: unfocused,
                   isCheckupFieldShowing: checkupField)
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

  /// A fresh engine has `lastIdleSeconds == 0`, so a cold fixture never sees the
  /// fall a real lock produces. Locking is itself input (a shortcut, a menu click,
  /// a hot corner), so on a warm engine the idle counter DROPS at the lock edge,
  /// and reading that drop as "input while locked" lifted the dim on the same tick
  /// that armed it.
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
    // Re-arms 300 s after the WAKE, not on a counter that started before it. The
    // wake floor is 6 here (FINDING C).
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

  /// Every overlay dim sits at the field's own window level, so the signal
  /// lands at mirroring's precedence: no dim reaches the panel by any route
  /// while a field is up.
  @Test func aCheckupFieldSuspendsFromEveryDimmedState() {
    var fromActive = IdleDimmingEngine(config: config())
    #expect(fromActive.tick(signals(idle: 10)) == .active)
    #expect(fromActive.tick(signals(idle: 11, checkupField: true)) == .suspended)

    var fromIdleDim = IdleDimmingEngine(config: config())
    #expect(fromIdleDim.tick(signals(idle: 400)) == .idleDim)
    #expect(fromIdleDim.tick(signals(idle: 401, checkupField: true)) == .suspended)

    var fromBlackout = IdleDimmingEngine(config: config(blackout: true, blackoutAt: 1200))
    #expect(fromBlackout.tick(signals(idle: 1200)) == .blackout)
    #expect(fromBlackout.tick(signals(idle: 1201, checkupField: true)) == .suspended)
  }

  /// The lock dim is delivered on the wire rather than by an overlay, so it is
  /// the one dim a field could not simply cover: it has to be refused outright.
  @Test func aCheckupFieldOutranksTheLockDim() {
    var e = IdleDimmingEngine(config: config(lock: true))
    e.noteLock(idleSeconds: 5)
    #expect(e.tick(signals(idle: 5, locked: true)) == .lockDim)
    #expect(e.tick(signals(idle: 6, locked: true, checkupField: true)) == .suspended)
  }

  /// The hold is a signal, not a latch: the tick after the field comes down
  /// answers from the other signals again, with no resume step to forget.
  @Test func clearingTheCheckupFieldResumesOnTheNextTick() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.tick(signals(idle: 400)) == .idleDim)
    #expect(e.tick(signals(idle: 401, checkupField: true)) == .suspended)
    #expect(e.tick(signals(idle: 402)) == .idleDim)
  }

  @Test func hdrSettleDefersEntryButNotExit() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.tick(signals(idle: 400, settling: true)) == .active)   // entry deferred
    _ = e.tick(signals(idle: 401))                                    // dims
    #expect(e.tick(signals(idle: 402, settling: true)) == .idleDim)  // no forced exit
  }

  /// The config carries BRIGHTNESS-while-dimmed; the overlay wants OPACITY, so
  /// every alpha here is the complement of the setting that produced it.
  @Test func alphaMapping() {
    let e = IdleDimmingEngine(config: config(level: 0.5, unfocusedLevel: 0.7))
    #expect(e.alpha(for: .idleDim) == 0.5)
    // `.lockDim` is no longer an overlay state: an overlay does not render
    // above the lock screen (MEASURED 2026-08-07), so lock dim is delivered on
    // the wire. `LockDimTests` owns the replacement.
    #expect(e.alpha(for: .lockDim) == nil)
    #expect(e.alpha(for: .blackout) == 1.0)
    // Dim TO 70% brightness is a 30% opaque overlay.
    #expect(abs(e.alpha(for: .unfocusedDim)! - 0.3) < 1e-9)
    #expect(e.alpha(for: .active) == nil)
    #expect(e.alpha(for: .suspended) == nil)
  }

  /// All eight prefs get distinct values: with defaults left in place a transposed
  /// pair (blackout seconds against unfocused seconds, either level into the other)
  /// reads correct. The two enable flags must DIFFER here, since both true is
  /// transposable against a defaults test where both are false.
  @Test func configFromPrefsReadsTask1Accessors() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    prefs.oledIdleDimSeconds = 120
    prefs.oledIdleDimBrightness = 0.3
    prefs.oledLockDim = false
    prefs.oledBlackoutEnabled = true
    prefs.oledBlackoutSeconds = 900
    prefs.oledUnfocusedDimEnabled = false
    prefs.oledUnfocusedDimSeconds = 450
    prefs.oledUnfocusedDimBrightness = 0.8

    let c = OledDimConfig(prefs: prefs)
    #expect(c.idleDimSeconds == 120)
    // Tolerance, not equality: the accessor stores the complement, so a
    // round trip through 1 - x lands a float ulp away from the input.
    #expect(abs(c.idleDimBrightness - 0.3) < 1e-9)
    #expect(c.lockDim == false)
    #expect(c.blackoutEnabled == true)
    #expect(c.blackoutSeconds == 900)
    #expect(c.unfocusedDimEnabled == false)
    #expect(c.unfocusedDimSeconds == 450)
    #expect(c.unfocusedDimBrightness == 0.8)
  }

  /// The whole chain, both ends, from the number the user sets to what reaches the
  /// screen: 10% is DARKEST and 90% is mildest, because a user setting 10% expects
  /// a dim display. Both ends are asserted because the midpoint is its own
  /// complement, so a mapping that is still inverted passes any test written at 50%.
  @Test func theDimSettingIsDarkestAtTenPercentAndMildestAtNinety() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")

    prefs.oledIdleDimBrightness = 0.1
    var engine = IdleDimmingEngine(config: OledDimConfig(prefs: prefs))
    #expect(abs(engine.alpha(for: .idleDim)! - 0.9) < 1e-9)  // nearly opaque
    #expect(abs(engine.lockDimFactor - 0.1) < 1e-9)          // a tenth of the user's brightness

    prefs.oledIdleDimBrightness = 0.9
    engine = IdleDimmingEngine(config: OledDimConfig(prefs: prefs))
    #expect(abs(engine.alpha(for: .idleDim)! - 0.1) < 1e-9)  // barely there
    #expect(abs(engine.lockDimFactor - 0.9) < 1e-9)

    prefs.oledUnfocusedDimBrightness = 0.2
    engine = IdleDimmingEngine(config: OledDimConfig(prefs: prefs))
    #expect(abs(engine.alpha(for: .unfocusedDim)! - 0.8) < 1e-9)
  }

  /// The on-disk half of the same flip, and why no migration is owed: the KEY still
  /// holds the overlay opacity it always held, and the inversion lives at the
  /// accessor. A stored 0.5 is a half-opaque overlay either way, so nothing on a
  /// user's disk changed meaning. Break this and every display flips its dim depth.
  @Test func theStoredValueIsStillTheOverlayOpacityNotTheBrightness() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")

    prefs.oledIdleDimBrightness = 0.1
    #expect(abs((defaults.object(forKey: "oledIdleDimLevel.pk") as! Double) - 0.9) < 1e-9)
    prefs.oledUnfocusedDimBrightness = 0.25
    #expect(abs((defaults.object(forKey: "oledUnfocusedDimLevel.pk") as! Double) - 0.75) < 1e-9)

    // And a value written under the OLD meaning still renders as it did: 0.5
    // opacity on disk is still a half-opaque overlay.
    defaults.set(0.5, forKey: "oledIdleDimLevel.pk")
    let engine = IdleDimmingEngine(config: OledDimConfig(prefs: prefs))
    #expect(abs(engine.alpha(for: .idleDim)! - 0.5) < 1e-9)
  }

  /// The default prefs ARE the Recommended preset, so an un-tuned display's config
  /// must survive every sanitization untouched.
  @Test func presetDefaultsSurviveSanitizationUnchanged() {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "pk")
    let c = OledDimConfig(prefs: prefs)
    #expect(c.idleDimSeconds == 300)
    #expect(c.idleDimBrightness == 0.5)
    #expect(c.lockDim == true)
    #expect(c.blackoutEnabled == false)
    #expect(c.blackoutSeconds == 1200)
    #expect(c.unfocusedDimEnabled == false)
    #expect(c.unfocusedDimSeconds == 600)
    // BRIGHTER than `idleDimBrightness`: the number is how bright the display
    // is left, and an unfocused display is still in the user's view so it gets
    // the gentler dim. The stored opacity behind it is unchanged at 0.3.
    #expect(c.unfocusedDimBrightness == 0.7)
  }

  /// Dim levels were unclamped through the whole chain, from pref accessor to
  /// overlay alpha. A 0.0 dim is a no-op and a 1.0 dim is an unannounced blackout
  /// that does not swallow its waking click (OC15): both are config errors, so the
  /// config is where they die.
  @Test func dimBrightnessesClampToUsableRange() {
    let tooBright = config(level: 1.0, unfocusedLevel: 4.2)
    #expect(tooBright.idleDimBrightness == 0.9)
    #expect(tooBright.unfocusedDimBrightness == 0.9)

    let tooDark = config(level: 0.0, unfocusedLevel: -1)
    #expect(tooDark.idleDimBrightness == 0.1)
    #expect(tooDark.unfocusedDimBrightness == 0.1)

    let inRange = config(level: 0.5, unfocusedLevel: 0.7)
    #expect(inRange.idleDimBrightness == 0.5)
    #expect(inRange.unfocusedDimBrightness == 0.7)

    // The clamp is only worth anything if it reaches the overlay's alpha, and
    // the alpha is the COMPLEMENT: clamped to the brightest allowed, the
    // overlay must be the LIGHTEST it can be.
    let e = IdleDimmingEngine(config: tooBright)
    #expect(abs(e.alpha(for: .idleDim)! - 0.1) < 1e-9)
    #expect(abs(e.alpha(for: .unfocusedDim)! - 0.1) < 1e-9)
  }

  /// A naive `min(max(…))` passes NaN straight through — and a NaN alpha is an
  /// undefined overlay, not a visible error.
  @Test func nonFiniteDimBrightnessesResolveInsideTheRange() {
    let nan = config(level: .nan, unfocusedLevel: .nan)
    #expect((0.1...0.9).contains(nan.idleDimBrightness))
    #expect((0.1...0.9).contains(nan.unfocusedDimBrightness))

    let infinite = config(level: .infinity, unfocusedLevel: -.infinity)
    #expect(infinite.idleDimBrightness == 0.9)
    #expect(infinite.unfocusedDimBrightness == 0.1)
  }

  /// `updateConfig` is how a pref change reaches a live engine, through
  /// `reapplyAfterPrefChange`. An engine that kept its original config would pass
  /// every other test here.
  @Test func updateConfigRetargetsThresholdAndLevel() {
    var e = IdleDimmingEngine(config: config(idle: 300, level: 0.5))
    #expect(e.tick(signals(idle: 200)) == .active)
    e.updateConfig(config(idle: 120, level: 0.4))
    #expect(e.tick(signals(idle: 200)) == .idleDim)
    // Dim TO 40% brightness is a 60% opaque overlay.
    #expect(abs(e.alpha(for: .idleDim)! - 0.6) < 1e-9)
  }

  @Test func stateMirrorsTheLastTick() {
    var e = IdleDimmingEngine(config: config())
    #expect(e.state == .active)
    let returned = e.tick(signals(idle: 400))
    #expect(e.state == returned)
    #expect(e.state == .idleDim)
  }

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

  /// FINDING B: with the entry gate uniform the sticky branch is gone, so a dropped
  /// unfocused counter (focus arrived and left between two ticks) exits.
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

  /// RULING D, restated for the delivery A-16 measured: a blacked-out display that
  /// gets locked drops to `.lockDim`.
  ///
  /// Holding `.blackout` kept the panel off lock dim's lighter level in name only.
  /// `.blackout` is delivered by an overlay, and no overlay of ours renders above
  /// the lock screen, so the hold delivered a FULL-BRIGHT lock screen while every
  /// surface said "Screen off". `.lockDim` goes on the wire, strictly darker than
  /// the hold ever was, so ruling D holds in light off the panel rather than in the
  /// name of a state.
  @Test func lockingABlackoutDimsTheWireInsteadOfHoldingAnInvisibleOverlay() {
    var e = IdleDimmingEngine(config: config(blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 1300)) == .blackout)
    e.noteLock(idleSeconds: 1300)
    #expect(e.tick(signals(idle: 1301, locked: true)) == .lockDim)
    #expect(e.tick(signals(idle: 2, locked: true)) == .active)  // input still lifts
  }

  /// Wake always lands `.active`, from a lock reached through a blackout as much
  /// as from any other, and re-arms on the idle threshold measured from the
  /// wake.
  @Test func wakeFromALockedBlackoutLandsActiveAndReArms() {
    var e = IdleDimmingEngine(config: config(idle: 300, blackout: true, blackoutAt: 1200))
    #expect(e.tick(signals(idle: 1300)) == .blackout)
    e.noteLock(idleSeconds: 1300)
    #expect(e.tick(signals(idle: 1301, locked: true)) == .lockDim)
    e.noteWake()
    // The counter still reads hours, since sleep does not reset it, but none of it
    // was spent awake, so the lock screen comes up lit.
    #expect(e.tick(signals(idle: 7200, locked: true)) == .active)
    #expect(e.tick(signals(idle: 7200 + 299, locked: true)) == .active)
    #expect(e.tick(signals(idle: 7200 + 300, locked: true)) == .lockDim)
  }

  /// The lock branch never ENTERS a blackout, however long the screen stays
  /// locked: an overlay nobody can see is not a state this machine may report,
  /// and the wire dim is the whole of what lock dim delivers.
  @Test func aBlackoutThresholdElapsingWhileLockedStillYieldsLockDim() {
    var e = IdleDimmingEngine(config: config(idle: 300, blackout: true, blackoutAt: 1200))
    e.noteLock(idleSeconds: 10)
    #expect(e.tick(signals(idle: 11, locked: true)) == .lockDim)
    #expect(e.tick(signals(idle: 301, locked: true)) == .lockDim)
    #expect(e.tick(signals(idle: 1201, locked: true)) == .lockDim)
    #expect(e.tick(signals(idle: 9000, locked: true)) == .lockDim)
  }

  /// RULING F: lock dim is exempt from the HDR-settle deferral. A full-bright lock
  /// screen during a settle is the worse outcome, and locking is an explicit user
  /// action rather than an inferred idle.
  @Test func lockEdgeDimsEvenDuringHDRSettle() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock(idleSeconds: 1)
    #expect(e.tick(signals(idle: 1, locked: true, settling: true)) == .lockDim)
  }

  /// FINDING E: sub-30 s thresholds mean "dimmed always", and the blackout row
  /// derives from the idle one, so an unfloored idle threshold is how a display
  /// blacks out at zero idle with nothing to recover it.
  @Test func secondsThresholdsHaveFloors() {
    let c = OledDimConfig(idleDimSeconds: 0, idleDimBrightness: 0.5, lockDim: true,
                          blackoutEnabled: true, blackoutSeconds: -100,
                          unfocusedDimEnabled: true, unfocusedDimSeconds: 5,
                          unfocusedDimBrightness: 0.7)
    #expect(c.idleDimSeconds == 30)
    #expect(c.unfocusedDimSeconds == 30)
    #expect(c.blackoutSeconds == 90)  // floored idle + 60, not -100

    // Boundary: a threshold already above the floor is untouched.
    let ok = OledDimConfig(idleDimSeconds: 30, idleDimBrightness: 0.5, lockDim: true,
                           blackoutEnabled: false, blackoutSeconds: 5000,
                           unfocusedDimEnabled: false, unfocusedDimSeconds: 31,
                           unfocusedDimBrightness: 0.7)
    #expect(ok.idleDimSeconds == 30)
    #expect(ok.unfocusedDimSeconds == 31)
    #expect(ok.blackoutSeconds == 5000)
  }

  /// `max(NaN, floor)` returns NaN, which reads as "floored" while disabling the
  /// row it belongs to: every `>=` against it is false.
  @Test func nonFiniteSecondsFallBackToTheFloor() {
    let c = OledDimConfig(idleDimSeconds: .nan, idleDimBrightness: 0.5, lockDim: true,
                          blackoutEnabled: true, blackoutSeconds: .nan,
                          unfocusedDimEnabled: true, unfocusedDimSeconds: .nan,
                          unfocusedDimBrightness: 0.7)
    #expect(c.idleDimSeconds == 30)
    #expect(c.blackoutSeconds == 90)  // the floored idle threshold + 60
    #expect(c.unfocusedDimSeconds == 30)
  }

  @Test func aNegativeBlackoutCannotFireAtZeroIdle() {
    var e = IdleDimmingEngine(config: OledDimConfig(
      idleDimSeconds: 0, idleDimBrightness: 0.5, lockDim: true,
      blackoutEnabled: true, blackoutSeconds: -100,
      unfocusedDimEnabled: false, unfocusedDimSeconds: 600, unfocusedDimBrightness: 0.7))
    #expect(e.tick(signals(idle: 0)) == .active)
    #expect(e.tick(signals(idle: 29)) == .active)
    #expect(e.tick(signals(idle: 30)) == .idleDim)
    #expect(e.tick(signals(idle: 89)) == .idleDim)
    #expect(e.tick(signals(idle: 90)) == .blackout)
  }
}
