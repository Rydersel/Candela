import CandelaKit

/// Routes the guided setup flow's commit records onto the app's existing write
/// paths (OB6). Every leg is an injected closure: the live wiring hands it the
/// real pref writer, the login item and the apply acknowledgement, and tests
/// hand it recorders. Nothing here constructs a writer, reads a pref, or
/// touches a display, so the routing rules (the empty-name guard, the
/// differs-only login gate, the deliberate absence of a re-apply) are testable
/// without any of that.
///
/// No leg carries a default. An unwired leg is a commit the user made and the
/// app silently dropped, so omitting one is a compile error rather than a
/// no-op; the acknowledgement leg is where a no-op is legitimate, and the live
/// wiring passes one explicitly.
@MainActor
struct OnboardingCommitRouter {
  /// Writes the display's friendly name, D27 shape at the call site: the
  /// `DisplayPrefs` setter followed by the `.friendlyName` pref-change
  /// notification.
  var writeFriendlyName: (_ displayKey: String, _ name: String) -> Void
  var enrollInCare: (_ displayKey: String) -> Void
  var enableMeasuredTelemetry: (_ displayKey: String) -> Void
  /// The LIVE registration state (D10 has one source of truth and no mirror),
  /// read at routing time so the gate below compares against the system rather
  /// than against whatever the flow snapshotted at launch.
  var isLoginItemEnabled: () -> Bool
  var setLaunchAtLogin: (_ enabled: Bool) -> Void
  /// Called for a size the user already applied and KEPT. It exists so the
  /// record has somewhere to land (a log line, a suggestion dismissal); it must
  /// never apply a mode.
  var acknowledgeAppliedSize: (_ displayKey: String, _ looksLikeWidth: Int, _ looksLikeHeight: Int) -> Void

  func route(_ commit: OnboardingCommit) {
    switch commit {
    case let .rename(displayKey, name):
      // The page guards non-empty and changed; this is the cheap half of that
      // guard, kept here because an empty friendly name is never a valid
      // write. Blank under ANY whitespace means "use the name the display
      // reports", which is a clear rather than a rename, and the flow has no
      // clear: the same shared rule the settings name field commits through.
      let normalized = DisplayCardPolicy.normalizedFriendlyName(name)
      guard !normalized.isEmpty else { return }
      writeFriendlyName(displayKey, normalized)

    case let .applySize(displayKey, looksLikeWidth, looksLikeHeight):
      // Deliberately NOT an apply. The size page applies interactively through
      // the shipped mode-apply path with its real keep and revert countdown,
      // and only a kept apply produces this commit, so the display is already
      // showing this size by the time the record arrives. Re-applying on
      // advance would fire a second mode change at a display that just settled,
      // with a second countdown to answer.
      acknowledgeAppliedSize(displayKey, looksLikeWidth, looksLikeHeight)

    case let .enrollInCare(displayKey):
      enrollInCare(displayKey)

    case let .enableMeasuredTelemetry(displayKey):
      enableMeasuredTelemetry(displayKey)

    case let .setLaunchAtLogin(enabled):
      // OB13: differs-only. An unchanged toggle must not touch SMAppService,
      // because an unregister the user did not ask for costs them a
      // registration made outside the app, and a re-register buys nothing.
      guard enabled != isLoginItemEnabled() else { return }
      setLaunchAtLogin(enabled)
    }
  }
}
