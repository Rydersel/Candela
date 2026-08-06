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
    e.noteLock()
    #expect(e.tick(signals(idle: 1, locked: true)) == .lockDim)
  }

  @Test func inputWhileLockedLiftsThenRearms() {
    var e = IdleDimmingEngine(config: config(idle: 300))
    e.noteLock()
    _ = e.tick(signals(idle: 5, locked: true))
    #expect(e.tick(signals(idle: 1, locked: true)) == .active)     // typing password
    #expect(e.tick(signals(idle: 299, locked: true)) == .active)
    #expect(e.tick(signals(idle: 300, locked: true)) == .lockDim)  // re-armed by idle
  }

  @Test func wakeBeatsLock() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock()
    _ = e.tick(signals(idle: 5, locked: true))
    e.noteWake()
    #expect(e.tick(signals(idle: 6, locked: true)) == .active)
    #expect(e.tick(signals(idle: 300, locked: true)) == .lockDim)  // idle re-arms
  }

  @Test func unlockReturnsToActive() {
    var e = IdleDimmingEngine(config: config())
    e.noteLock()
    _ = e.tick(signals(idle: 5, locked: true))
    e.noteUnlock()
    #expect(e.tick(signals(idle: 6)) == .active)
  }

  @Test func lockDimRespectsItsToggle() {
    var e = IdleDimmingEngine(config: config(lock: false))
    e.noteLock()
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
    e.noteLock()
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

  @Test func configFromPrefsReadsTask1Accessors() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    prefs.oledIdleDimSeconds = 120
    prefs.oledIdleDimLevel = 0.3
    let c = OledDimConfig(prefs: prefs)
    #expect(c.idleDimSeconds == 120)
    #expect(c.idleDimLevel == 0.3)
    #expect(c.lockDim == true)
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
}
