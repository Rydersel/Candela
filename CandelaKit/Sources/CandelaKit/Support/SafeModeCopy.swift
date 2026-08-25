import Foundation

/// The one list of what a Safe Mode session suppresses, and the three summaries
/// built from it.
///
/// D11 is not a rule about wording, it is a rule about one feature being
/// described the same way in every place it is described. Before #147 the list
/// lived three separate times: in the launch alert, in the Diagnostics row
/// caption, and in the General pane caption. W3a added OLED care to the code and
/// to one of the three, so two surfaces spent a milestone naming three
/// suppressions while the app performed four, and #147 also found that no
/// summary named the saved arrangement. Adding a fifth `Suppression` case is now
/// a compile error until its clause is written, and all three summaries pick it
/// up with no further edit.
///
/// What belongs here: the SUMMARIES, the ones that answer "what does Safe Mode
/// do" for a reader who is not looking at a particular control. What does not:
/// the per-control notes (the OLED Care pane, Panel Health, the Arrangement
/// pane, the Advanced page's polling row, the General pane's startup picker),
/// which say what THIS control means during a safe-mode session. Those are
/// deliberately short, local, and about one control, and D11's visibility rule
/// wants them phrased in the terms of the control they sit under.
///
/// `careSessionNotice` is the borderline case, and it is here rather than in a
/// pane because it belongs to no control: it is the lead OLED Care and Health
/// both open with during a safe-mode session, and Health only exists as a
/// separate pane at all since the care restructure, which is what turned one
/// pane's literal into two panes' shared sentence.
///
/// Returns `String`, never `LocalizedStringKey`, which is why this can live in
/// Kit at all (CandelaKit imports no SwiftUI). `app` is the product name, passed
/// in for the same reason `DiagnosticsCopy` passes it: `AppInfo.productName`
/// lives in the app target, and a second copy of the literal here would break
/// the one-line rename it exists to guarantee.
public enum SafeModeCopy {

  /// Everything the flag actually gates, one case per behaviour a reader would
  /// name separately. Each case cites the guard that proves it, because the list
  /// is only worth trusting if it was read off the code rather than off another
  /// surface's copy, which is how #147 happened.
  ///
  /// What is NOT here, and must never be added: sliders, keyboard shortcuts and
  /// the OLED Care pane's two screen-chrome switches all still work and still
  /// send commands. They are explicit user actions rather than unattended
  /// behaviour, and the chrome controller is built even in a safe-mode session
  /// for exactly that reason. No summary may claim "no DDC commands".
  public enum Suppression: CaseIterable {
    /// `DisplayPrefs.startupAction` reports `.doNothing` for the session
    /// regardless of what is stored, which closes both of
    /// `RestoreCoordinator`'s passes (each gates on `== .write`); and
    /// `StatusItemController.restoreUnattended()` returns early, which is where
    /// the stored resolution and the saved arrangement would have been
    /// reapplied.
    case restore
    /// `AppModel` skips `refreshFromHardware` for appeared and kept displays,
    /// the volume and contrast passes return early because `startupAction`
    /// never reports `.read`, and `DisplayPrefs.pollingTries` is 0.
    case readback
    /// `StatusItemController.applicationWillTerminate` returns before the
    /// full-range DDC restore. The gamma reset and shade removal above that
    /// guard are not DDC and still run.
    case quitWrite
    /// `OledCareCoordinator.start` returns before the driver loop is built, so
    /// everything riding it stops: dimming overlays, lock dim, panel hours,
    /// brightness sampling and window observation. `reapplyAfterPrefChange`,
    /// `displaysReconfigured` and `resetDidComplete` each return early too, so
    /// nothing rebuilds the loop later in the session.
    case oledCare
  }

  /// One clause per suppression, each written to follow the word "won't".
  ///
  /// The restore clause names the arrangement as well as the resolution: both
  /// ride the same `restoreUnattended()` guard, and naming one but not the other
  /// is the incompleteness #147 was filed about, one notch smaller.
  public static func clause(_ suppression: Suppression) -> String {
    switch suppression {
    case .restore:
      "restore your saved brightness, volume, contrast, resolution or arrangement at startup or wake"
    case .readback:
      "read values back from your displays"
    case .quitWrite:
      "write anything to them when it quits"
    case .oledCare:
      "dim any display, count hours of use, or take any measurements for OLED care"
    }
  }

  /// The full list as one sentence, opening with the product name so a caller
  /// can lead into it ("For this session, Candela won't ...").
  public static func suppressions(app: String) -> String {
    let clauses = Suppression.allCases.map { "won't \(clause($0))" }
    guard let last = clauses.last else { return "" }
    let joined = clauses.count == 1
      ? last
      : clauses.dropLast().joined(separator: ", ") + ", and " + last
    return "\(app) \(joined)."
  }

  /// The Shift-launch alert's informative text, without the brightness-sync
  /// paragraph: that one is appended by the caller only when the pref is
  /// actually on, and is additional to the list rather than part of it.
  ///
  /// The second paragraph is as load-bearing as the first. A user reaching for
  /// Safe Mode because DDC writes are wedging a monitor must not read the list
  /// above as "the traffic has stopped", and gating the sliders and keys would
  /// disable the only unmute affordance a hardware-muted display has (D29
  /// rule 3).
  public static func launchNotice(app: String) -> String {
    """
    Shift was held during launch. For this session, \(suppressions(app: app))

    Your sliders and keyboard shortcuts still work, and they still send commands to your displays. \
    Nothing about your settings has changed: relaunch without holding Shift to leave Safe Mode.
    """
  }

  /// The one piece of traffic `launchNotice` does not cover, appended to it only
  /// while `enableBrightnessSync` is on.
  ///
  /// `BrightnessSync.fanOut` writes DDC to the other displays whenever the
  /// built-in's brightness moves, INCLUDING moves nobody made here, such as the
  /// ambient light sensor's. That is unattended traffic, so "your sliders and
  /// keyboard shortcuts" does not honestly account for it. Named only when the
  /// pref is on: a standing caveat about a feature the user does not use is
  /// noise, and the honesty rule is about the copy matching THIS session.
  public static let brightnessSyncParagraph = """
    "Match other displays to the built-in display" is on, so changes to the built-in display's \
    brightness (including ones macOS makes by itself, such as the ambient light sensor's) are \
    still mirrored out to your other displays. Turn it off in Settings if you need those \
    displays left completely alone.
    """

  /// The Diagnostics page's safe-mode row caption. Terser surroundings than the
  /// other two, same list.
  public static func diagnosticsRow(app: String) -> String {
    "Shift was held at launch. \(suppressions(app: app)) Sliders and keys still work."
  }

  /// The General pane's caption, shown under the startup picker only during a
  /// safe-mode session: the picker reports the PERSISTED choice, so without this
  /// the pane describes behaviour that is not happening.
  public static func generalPaneCaption(app: String) -> String {
    "Shift was held at launch. \(suppressions(app: app)) The sliders and keys still work, your settings are unchanged, and relaunching without Shift restores normal behavior."
  }

  /// The care panes' pane-level lead: the `oledCare` suppression said in the
  /// terms those panes are read in, for a reader looking at figures and
  /// switches rather than at a list of what the session gates.
  ///
  /// A summary, not a per-control note, which is why it is here: OLED Care and
  /// Health both open on it, and two panes describing one session in two
  /// wordings is #147 again one notch smaller. Each pane still writes its own
  /// second sentence, because what the reader should do next differs (Screen
  /// Chrome still works on one; the figures below are stored history on the
  /// other).
  ///
  /// Hard-coded rather than assembled from `clause(.oledCare)`: that clause is
  /// written to follow "won't" and reads as one item in a list, and this is a
  /// standalone sentence about the session. Both must stay true of the same
  /// guard, so a change to `OledCareCoordinator.start`'s safe-mode return
  /// belongs in both.
  public static let careSessionNotice =
    "Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken."
}
