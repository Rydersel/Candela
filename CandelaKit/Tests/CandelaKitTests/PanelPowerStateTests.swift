import Testing
@testable import CandelaKit

@Suite("Panel power belief (hours while a display is off)")
struct PanelPowerStateTests {
  @Test func aFreshPanelAccruesWhileTheSystemCallsItAwake() {
    let p = PanelPowerState()
    #expect(p.believedPoweredOff == false)
    #expect(p.accruesHours(systemReportsAsleep: false) == true)
  }

  @Test func aNormalDisplaySleepStillSuspendsAccrual() {
    // The pre-existing gate, unchanged: CGDisplayIsAsleep true means no hours,
    // with or without a belief about a power-off.
    var p = PanelPowerState()
    #expect(p.accruesHours(systemReportsAsleep: true) == false)
    p.notePoweredOff(focusedElsewhere: true)
    #expect(p.accruesHours(systemReportsAsleep: true) == false)
  }

  @Test func powerOffSuspendsAccrualDespiteTheSystemReportingItAwake() {
    // The defect in one assertion: macOS reports a DPMS-off panel as awake, so
    // `systemReportsAsleep: false` is what the coordinator actually sees here.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    #expect(p.believedPoweredOff == true)
    #expect(p.accruesHours(systemReportsAsleep: false) == false)
  }

  @Test func focusArrivingResumesAccrualWhenItWasElsewhereAtPowerOff() {
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    p.noteFocusSample(isThisDisplay: true)
    #expect(p.believedPoweredOff == false)
    #expect(p.accruesHours(systemReportsAsleep: false) == true)
  }

  @Test func focusThatWasAlreadyHereAtPowerOffIsNotEvidence() {
    // The settings window with the power-off button is very often ON the display
    // being turned off. Without the ratchet the belief clears on the next tick
    // and the fix does nothing.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: false)
    for _ in 0..<20 { p.noteFocusSample(isThisDisplay: true) }
    #expect(p.believedPoweredOff == true)
    #expect(p.accruesHours(systemReportsAsleep: false) == false)
  }

  @Test func focusLeavingAndComingBackResumesAccrual() {
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: false)
    p.noteFocusSample(isThisDisplay: true)   // stale reading, still not evidence
    #expect(p.believedPoweredOff == true)
    p.noteFocusSample(isThisDisplay: false)  // user moved to another display
    #expect(p.believedPoweredOff == true)    // leaving is not evidence either
    p.noteFocusSample(isThisDisplay: true)   // and came back: the panel is lit
    #expect(p.believedPoweredOff == false)
  }

  @Test func aDisplayNeverFocusedAgainStaysSuspended() {
    // The documented residual: it undercounts rather than booking phantom hours.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    for _ in 0..<1000 { p.noteFocusSample(isThisDisplay: false) }
    #expect(p.believedPoweredOff == true)
    #expect(p.accruesHours(systemReportsAsleep: false) == false)
  }

  @Test func departureResumesAccrualOnReturn() {
    // A real power-cycle DOES reconfigure (the MAG departed when its
    // compensation cycle finished), and the returning connection starts clean.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: false)
    p.noteDeparted()
    #expect(p.believedPoweredOff == false)
    #expect(p.accruesHours(systemReportsAsleep: false) == true)
  }

  @Test func departureAlsoClearsTheRatchet() {
    // Otherwise a departure would leave `sawFocusElsewhere` armed, and the NEXT
    // power-off would clear on the first stale focus sample — the defect this
    // suite's third case pins, resurrected one connection later.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    p.noteDeparted()
    p.notePoweredOff(focusedElsewhere: false)
    p.noteFocusSample(isThisDisplay: true)
    #expect(p.believedPoweredOff == true)
  }

  @Test func aSecondPowerOffReseedsTheRatchet() {
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    p.noteFocusSample(isThisDisplay: true)   // resumed
    #expect(p.believedPoweredOff == false)
    p.notePoweredOff(focusedElsewhere: false)
    p.noteFocusSample(isThisDisplay: true)
    #expect(p.believedPoweredOff == true)    // reseeded, not left armed
  }

  @Test func focusSamplesDoNothingWhileThePanelIsBelievedOn() {
    // The coordinator feeds samples for every enrolled display, not only the
    // dark ones; they must not accumulate state that a later power-off inherits.
    var p = PanelPowerState()
    p.noteFocusSample(isThisDisplay: false)
    p.noteFocusSample(isThisDisplay: true)
    #expect(p.believedPoweredOff == false)
    p.notePoweredOff(focusedElsewhere: false)
    p.noteFocusSample(isThisDisplay: true)
    #expect(p.believedPoweredOff == true)
  }

  @Test func aRefusedWriteNeverSuspendsAccrual() {
    // The coordinator records the belief BEFORE the write (a tick can land in
    // the await gap). A panel that refuses 0xD6 never went dark, so the belief
    // must not outlive the failure — suspending hours for a display that is
    // still lit is the mirror-image defect.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: false)
    p.notePowerOffFailed()
    #expect(p.believedPoweredOff == false)
    #expect(p.accruesHours(systemReportsAsleep: false) == true)
  }

  @Test func resumingIsFinalUntilTheNextPowerOff() {
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    p.noteFocusSample(isThisDisplay: true)
    p.noteFocusSample(isThisDisplay: false)  // focus wanders off again
    #expect(p.believedPoweredOff == false)   // which is not a power-off
    #expect(p.accruesHours(systemReportsAsleep: false) == true)
  }

  @Test func theEightHourWalkTheDefectDescribes() {
    // Power off at bedtime, no focus visit all night: not one of the eight hours
    // is booked. Then the user sits down, works on the other display and clicks
    // back — accrual resumes from there.
    var p = PanelPowerState()
    p.notePoweredOff(focusedElsewhere: true)
    var accruedTicks = 0
    for _ in 0..<(8 * 3600) where p.accruesHours(systemReportsAsleep: false) {
      accruedTicks += 1
    }
    #expect(accruedTicks == 0)
    p.noteFocusSample(isThisDisplay: false)
    p.noteFocusSample(isThisDisplay: true)
    #expect(p.accruesHours(systemReportsAsleep: false) == true)
  }
}
