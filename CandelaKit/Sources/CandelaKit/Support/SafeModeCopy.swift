import Foundation

/// The one list of what a Safe Mode session suppresses, and the summaries built
/// from it.
///
/// D11 is about one feature being described the same way everywhere. This list used
/// to live separately in the launch alert, the Diagnostics row and the General pane,
/// and the three drifted apart. Adding a `Suppression` case is now a compile error
/// until its clause is written, and every summary picks it up for free.
///
/// Summaries only. Per-control notes stay in their panes, phrased in the terms of
/// the control they sit under.
///
/// Returns `String`, never `LocalizedStringKey`, which is what lets it live in the
/// Kit. `app` is passed in because `AppInfo.productName` lives in the app target and
/// a second copy of the literal would break the one-line rename.
public enum SafeModeCopy {

  /// Everything the flag actually gates, one case per behaviour a reader would name
  /// separately. Each case cites the guard that proves it, so the list is read off
  /// the code rather than off another surface's copy.
  ///
  /// Sliders, keyboard shortcuts and the OLED Care pane's screen-chrome switches are
  /// deliberately absent: they still send commands, being explicit user actions
  /// rather than unattended behaviour. No summary may claim "no DDC commands".
  public enum Suppression: CaseIterable {
    /// `DisplayPrefs.startupAction` reports `.doNothing` for the session whatever is
    /// stored, closing both `RestoreCoordinator` passes, and
    /// `StatusItemController.restoreUnattended()` returns early, which is where the
    /// stored resolution and the saved arrangement would have been reapplied.
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
    /// everything riding it stops. `reapplyAfterPrefChange`, `displaysReconfigured`
    /// and `resetDidComplete` return early too, so nothing rebuilds it later.
    case oledCare
  }

  /// One clause per suppression, each written to follow the word "won't". The
  /// restore clause names the arrangement as well as the resolution, since both ride
  /// the same `restoreUnattended()` guard.
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
  /// paragraph, which the caller appends only when that pref is on.
  ///
  /// The second paragraph is as load-bearing as the first. Someone reaching for Safe
  /// Mode because DDC writes are wedging a monitor must not read the list above as
  /// "the traffic has stopped", and gating the sliders and keys would remove the only
  /// unmute affordance a hardware-muted display has (D29 rule 3).
  public static func launchNotice(app: String) -> String {
    """
    Shift was held during launch. For this session, \(suppressions(app: app))

    Your sliders and keyboard shortcuts still work, and they still send commands to your displays. \
    Nothing about your settings has changed: relaunch without holding Shift to leave Safe Mode.
    """
  }

  /// The one piece of traffic `launchNotice` does not cover, appended only while
  /// `enableBrightnessSync` is on.
  ///
  /// `BrightnessSync.fanOut` writes DDC to the other displays whenever the built-in's
  /// brightness moves, INCLUDING moves nobody made here, such as the ambient light
  /// sensor's. That is unattended traffic, so "your sliders and keyboard shortcuts"
  /// does not account for it. Named only when the pref is on, so the copy matches
  /// THIS session.
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

  /// The care panes' pane-level lead: the `oledCare` suppression in the terms those
  /// panes are read in. A summary, not a per-control note, which is why it lives
  /// here: OLED Care and Health both open on it. Each pane still writes its own
  /// second sentence, because what the reader should do next differs.
  ///
  /// Hard-coded rather than assembled from `clause(.oledCare)`, which is written to
  /// follow "won't". Both must stay true of the same guard, so a change to
  /// `OledCareCoordinator.start`'s safe-mode return belongs in both.
  public static let careSessionNotice =
    "Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken."
}
