import Foundation

/// How often the Accessibility grant is polled behind the
/// `com.apple.accessibility.api` notification. Held: watching for a revocation
/// nothing else reports. Missing: hunting for a grant the user may be making now,
/// worth two seconds for a while and very little an hour later.
public enum AccessibilityBackstopPolicy {
  /// Held: slow, but never zero. Latching on success is the defect this tracking
  /// exists to prevent.
  public static let heldInterval: TimeInterval = 10
  /// Missing, with a grant plausibly moments away.
  public static let huntingInterval: TimeInterval = 2
  /// Missing long enough that nobody is standing at System Settings.
  public static let restingInterval: TimeInterval = 30
  /// Hunt length from the moment the grant went missing (launch, if it launched without one).
  public static let huntWindow: TimeInterval = 120
  /// A notification means TCC just changed something and the immediate read can
  /// lose the settle race, so the hunt resumes for this long after one.
  public static let notificationWindow: TimeInterval = 30

  /// `secondsSinceNotification` is nil when no notification has arrived this
  /// launch. A nil result means run no timer at all.
  public static func interval(
    granted: Bool,
    requiresAccessibility: Bool,
    secondsSinceMissingBegan: TimeInterval,
    secondsSinceNotification: TimeInterval?
  ) -> TimeInterval? {
    // Before the skip: the prompt path trusts a held answer, so a stale `true`
    // would leave a rig that turns a key family back on with dead keys and no prompt.
    if granted { return heldInterval }
    // Custom shortcuts are Carbon hotkeys: nothing prompts, reports or reads the
    // grant on an all-custom rig.
    guard requiresAccessibility else { return nil }
    if secondsSinceMissingBegan < huntWindow { return huntingInterval }
    if let secondsSinceNotification, secondsSinceNotification < notificationWindow {
      return huntingInterval
    }
    return restingInterval
  }
}
