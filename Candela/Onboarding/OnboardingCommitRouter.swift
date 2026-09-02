import CandelaKit

/// Routes the guided setup flow's commit records onto the app's existing write
/// paths. Every leg is an injected closure: live wiring hands it the real
/// pref writer, the login item and the apply acknowledgement, tests hand it
/// recorders. Nothing here constructs a writer, reads a pref or touches a
/// display, so the routing rules stay testable without any of that.
///
/// No leg carries a default. An unwired leg is a commit the user made and the
/// app silently dropped, so omitting one is a compile error rather than a
/// no-op.
@MainActor
struct OnboardingCommitRouter {
  /// Writes the display's friendly name, the standard pref-write shape at the call site: the
  /// `DisplayPrefs` setter followed by the `.friendlyName` pref-change
  /// notification.
  var writeFriendlyName: (_ displayKey: String, _ name: String) -> Void
  var enrollInCare: (_ displayKey: String) -> Void
  var unenrollFromCare: (_ displayKey: String) -> Void
  var enableMeasuredTelemetry: (_ displayKey: String) -> Void
  var disableMeasuredTelemetry: (_ displayKey: String) -> Void
  /// The LIVE registration state (one source of truth, never mirrored),
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
      // The page already guards non-empty and changed; this is the cheap half,
      // kept because an empty friendly name is never a valid write. Blank under
      // ANY whitespace means "use the name the display reports", a clear rather
      // than a rename, and the flow has no clear.
      let normalized = DisplayCardPolicy.normalizedFriendlyName(name)
      guard !normalized.isEmpty else { return }
      writeFriendlyName(displayKey, normalized)

    case let .applySize(displayKey, looksLikeWidth, looksLikeHeight):
      // Deliberately NOT an apply. The size page applies interactively through
      // the shipped mode-apply path with its keep and revert countdown, and only
      // a kept apply produces this commit, so the display is already showing the
      // size. Re-applying here would fire a second mode change at a display that
      // just settled, with a second countdown to answer.
      acknowledgeAppliedSize(displayKey, looksLikeWidth, looksLikeHeight)

    case let .enrollInCare(displayKey):
      enrollInCare(displayKey)

    case let .unenrollFromCare(displayKey):
      unenrollFromCare(displayKey)

    case let .enableMeasuredTelemetry(displayKey):
      enableMeasuredTelemetry(displayKey)

    case let .disableMeasuredTelemetry(displayKey):
      disableMeasuredTelemetry(displayKey)

    case let .setLaunchAtLogin(enabled):
      // Differs-only. An unchanged toggle must not touch SMAppService: an
      // unregister costs a registration made outside the app, and a re-register
      // buys nothing.
      guard enabled != isLoginItemEnabled() else { return }
      setLaunchAtLogin(enabled)
    }
  }
}
