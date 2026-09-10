/// What a launch does about a temporary-dim marker a previous process left
/// behind. A surviving marker means the brightness register may disagree with
/// the slider, and a write-only panel cannot be asked which is right.
///
/// Pure and fully parameterized rather than reaching for prefs or a controller,
/// because four of the five answers are silences: a hardware pass cannot tell a
/// launch that correctly wrote nothing from one where the recovery never ran.
public enum InterruptedDimRecovery {
  public enum Action: Equatable, Sendable {
    /// Reset the write memo and re-assert, then clear the marker.
    case reassert
    /// Nothing safe to write; consume the marker so later launches do not
    /// re-evaluate a display nothing can help.
    case clearOnly
    case leave
  }

  /// Guards in order, each one reason not to write. Safe mode and a live dim
  /// both outrank a stored value.
  public static func action(
    markerSurvived: Bool, dimIsLive: Bool, hasStoredValue: Bool, isSafeMode: Bool
  ) -> Action {
    guard markerSurvived else { return .leave }
    // Safe mode sends no unattended DDC, and consuming the marker here would
    // spend the evidence the next normal launch needs.
    guard !isSafeMode else { return .leave }
    // This process owns the dim. Re-asserting would write the undimmed value to
    // a locked screen, and clearing would strand the next crash.
    guard !dimIsLive else { return .leave }
    // An empty store publishes the ASSUMED 1.0 default, which on an OLED is a
    // blast to full output. `AppModel.performRestorePass` refuses to write it
    // and so does this.
    guard hasStoredValue else { return .clearOnly }
    return .reassert
  }
}
