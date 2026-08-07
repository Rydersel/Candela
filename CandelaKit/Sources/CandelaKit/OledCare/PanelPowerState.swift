/// Whether one display's panel is believed to be physically lit, for panel-hours
/// accrual (#94).
///
/// **The problem this exists for, measured 2026-08-07 on both external panels.**
/// A display blanked by our own VCP 0xD6 power-off keeps reporting
/// `CGDisplayIsAsleep == false`, stays in the online *and* active lists at full
/// resolution, and produces no reconfiguration. macOS never observes the panel
/// going dark, so `PanelHoursTracker`'s `displayAwake` gate — which is exactly
/// that reading — books wear time for a panel that is provably off. Powered off
/// overnight, the lifetime total gains eight phantom hours, and that number is
/// the whole point of the feature.
///
/// **So the belief is ours, not the system's.** We know when *we* turned a panel
/// off; nothing else does. The panel does not self-recover (measured: the
/// register held `4/255` for 40 s with no restore), so there is no duration to
/// time out against — the belief has to be ended by positive evidence that the
/// panel is lit again, and only two such signals exist on every panel:
///
/// 1. **Focus arriving on this display.** The best evidence available that the
///    user is at a lit panel — not proof of one. Free (the coordinator already
///    samples focus) and works on write-only panels, which a `0xD6` readback
///    cannot. It can be wrong: macOS keeps a blanked display active at full
///    resolution and never migrates its windows, so windows REMAIN on the dark
///    panel and can take focus. Cmd-Tab to an app whose frontmost window sits
///    on the dark display and the belief clears while the panel is still off,
///    and hours accrue until it departs. No better signal exists on a
///    write-only panel, so this stands as evidence, not as an invariant.
/// 2. **A departure.** A real power-cycle *does* reconfigure — the MAG departed
///    when its compensation cycle finished — and a display that left is a
///    display whose next connection starts from a clean belief. Nothing accrues
///    while it is gone either way, so clearing on the departure and clearing on
///    the return are the same thing; the departure is the event the coordinator
///    actually sees.
///
/// A `0xD6` readback is deliberately NOT one of them: the MAG is write-only and
/// will never answer, so it could not be the only mechanism, and a DDC read
/// costs tens of milliseconds on a tick that runs at 10 Hz.
///
/// **Focus has to ARRIVE, not merely be there.** The settings window that owns
/// the power-off button is very often on the display being turned off, so the
/// focused display at the moment of the write can already be this one — and
/// treating that stale reading as evidence would clear the belief on the very
/// next tick and fix nothing. Hence the ratchet: while the panel is believed
/// off, focus must be seen somewhere else before a sample on this display counts
/// as a return. `notePoweredOff(focusedElsewhere:)` seeds it, so the common case
/// (turning off a display you are not working on) still clears on the first
/// focus visit.
///
/// **Honest residual, by design.** A display powered off and never focused again
/// — one used only for video with no focused window, or one whose user never
/// gives another window focus on any display — stays suspended and stops
/// accruing hours for as long as that lasts. It undercounts rather than
/// overcounts, which is the right direction for a wear number, and "a display
/// nobody ever focuses" is arguably a display that is not being used. A system
/// sleep/wake does not clear the belief either: whether a DPMS-off panel returns
/// across a wake has not been measured, and guessing would put the phantom hours
/// straight back.
///
/// **The one residual that goes the other way: a restart.** The belief is
/// in-memory only — nothing persists it. So if Candela relaunches (update,
/// crash, logout/login) while a panel is still dark, the belief is gone, the
/// system still reports that panel awake, and phantom hours accrue again —
/// the exact defect this type fixes, resurrected by a restart. That is
/// accepted rather than fixed: a persisted belief could freeze a counter
/// across sessions with no clearing event in sight (the display is dark, so
/// no focus arrives, and it need not depart), which is unbounded, while this
/// is bounded — accrual resumes only until the panel departs or is focused
/// after the relaunch, which is the same evidence any other clearing uses.
public struct PanelPowerState: Equatable, Sendable {
  /// True from the moment we issue the power-off until positive evidence
  /// arrives that the panel is lit again.
  public private(set) var believedPoweredOff = false
  /// The ratchet described above. Meaningless while `believedPoweredOff` is
  /// false, and reseeded by every `notePoweredOff`.
  private var sawFocusElsewhere = false

  public init() {}

  /// We issued the VCP 0xD6 power-off. `focusedElsewhere` is true only when the
  /// focused display is KNOWN and is not this one; an unresolved focus counts as
  /// "possibly here", so the ratchet still applies. Erring that way costs an
  /// undercount; erring the other way costs the whole fix.
  public mutating func notePoweredOff(focusedElsewhere: Bool) {
    believedPoweredOff = true
    sawFocusElsewhere = focusedElsewhere
  }

  /// One focus sample. Call only with a resolved sample — a `FocusSampler`
  /// returning nil means "no data yet", never "focus went nowhere", and feeding
  /// that in as `isThisDisplay: false` would arm the ratchet off a non-reading.
  public mutating func noteFocusSample(isThisDisplay: Bool) {
    guard believedPoweredOff else { return }
    if !isThisDisplay {
      sawFocusElsewhere = true
    } else if sawFocusElsewhere {
      believedPoweredOff = false
      sawFocusElsewhere = false
    }
  }

  /// The display left the live list. Its return is a fresh connection, and a
  /// power-cycle is the one thing that reliably brings a DPMS-off panel back.
  public mutating func noteDeparted() { clear() }

  /// The panel refused the power-off write, so nothing went dark. Same effect as
  /// `noteDeparted`, separate name because the two call sites mean different
  /// things and a shared one would read as a lie at whichever site lost.
  public mutating func notePowerOffFailed() { clear() }

  private mutating func clear() {
    believedPoweredOff = false
    // Cleared with the belief, not left armed: a stale ratchet would let the
    // NEXT power-off resolve on the first already-here focus sample — exactly
    // the reading `notePoweredOff(focusedElsewhere:)` refuses to trust.
    // Deliberately redundant with that reseed, which already forecloses it
    // unconditionally: mutating either site alone survives the tests, only
    // breaking BOTH is caught. Keep both — the invariant is worth two lines,
    // and proving one site dead is not grounds to delete it.
    sawFocusElsewhere = false
  }

  /// The one question the hours path asks. `systemReportsAsleep` is
  /// `CGDisplayIsAsleep`, unchanged in meaning — a normal display sleep still
  /// suspends accrual exactly as it did before this type existed; the belief
  /// only covers the case the system cannot see.
  public func accruesHours(systemReportsAsleep: Bool) -> Bool {
    !systemReportsAsleep && !believedPoweredOff
  }
}
