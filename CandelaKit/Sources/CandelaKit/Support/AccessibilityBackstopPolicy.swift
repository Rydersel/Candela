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

  /// What asked for the backstop to be re-evaluated. Both cases carry the same state
  /// and differ only in what they say about the person at the keyboard.
  public enum Edge: Sendable, Equatable {
    /// A key mode was written: someone chose whether a key family goes through us.
    case keyModesWritten
    /// The tap was re-armed by something else: a settings reset, or a pref that
    /// carries the re-arm without being about keys at all.
    case tapRearmed
  }

  /// Whether this edge reopens the hunt window, putting its clock back to zero.
  ///
  /// Only a key-mode write does: a person turning a key family on with no grant is at
  /// System Settings about to make it, however long the grant has been missing. The
  /// tap's other re-arm routes re-derive the cadence from the live modes and leave the
  /// clock where it is; reopening there would put an ungranted rig back on the
  /// two-second interval for two minutes after a write that has nothing to do with
  /// keys (a DDC availability switch, an audio-routing override).
  public static func reopensHunt(
    edge: Edge, granted: Bool, requiresAccessibility: Bool
  ) -> Bool {
    guard edge == .keyModesWritten else { return false }
    return !granted && requiresAccessibility
  }

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
