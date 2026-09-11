/// The decision half of OLED care's entry fade: which states fade in and for
/// how long. The animation itself lives in the app target, but the care loop's
/// reconcile and the restore gate both read these.
///
/// Nothing here fades a lift. Every decrease in dimming lands in one write, and
/// the overlay's own gate keeps that true whatever a state says.
public enum OverlayFade {
  /// Long enough not to read as a step in peripheral vision, short enough that
  /// the fade cannot outlive the care loop's bounded reconcile budget.
  public static let entrySeconds: Double = 0.4

  /// Which target states fade in. Exhaustive so a state added later has to be
  /// ruled on rather than defaulting into the set. `.lockDim` raises no overlay
  /// (it is a DDC ramp on the wire); `.unfocusedDim` is already gated on ten
  /// minutes of another display holding focus; a detection mask under `.active`
  /// arrives while the user is working and stays instant.
  public static func fadesInOnEntry(to state: OledDimState) -> Bool {
    switch state {
    case .idleDim, .blackout:
      return true
    case .active, .unfocusedDim, .lockDim, .suspended:
      return false
    }
  }
}
