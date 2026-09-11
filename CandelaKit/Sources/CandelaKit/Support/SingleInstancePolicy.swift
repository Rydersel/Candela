import Foundation

/// Which copy of the app keeps running when more than one is launched.
///
/// Only one process may drive DDC at a time: the bus has no arbitration, so two
/// copies talking to the same panel interleave their VCP traffic and the result
/// reads as a flaky monitor rather than as two apps.
///
/// The decision is a pure function so it can be exercised without launching a
/// second app; the enumeration it runs on belongs to the caller.
public enum SingleInstancePolicy {
  public struct Instance: Sendable, Equatable {
    public let processIdentifier: Int32
    /// Nil when the location cannot be read. That is not evidence of anything:
    /// it is still a running copy.
    public let bundlePath: String?
    public let launchDate: Date?

    public init(processIdentifier: Int32, bundlePath: String?, launchDate: Date? = nil) {
      self.processIdentifier = processIdentifier
      self.bundlePath = bundlePath
      self.launchDate = launchDate
    }
  }

  public enum Decision: Sendable, Equatable {
    case proceed
    /// The path is nil when the running copy's location could not be read; the
    /// caller says so rather than inventing one.
    case terminate(runningBundlePath: String?)
  }

  /// An empty list proceeds, which is also what a failed enumeration looks like: a
  /// missed second copy costs interleaved DDC writes, while a false positive locks
  /// someone out of the app with no route back from the UI.
  public static func decide(
    running: [Instance], ownProcessIdentifier: Int32, ownLaunchDate: Date? = nil
  ) -> Decision {
    let others = running.filter { $0.processIdentifier != ownProcessIdentifier }
    guard !others.isEmpty else { return .proceed }
    // Include this process even if Launch Services has not listed it yet.
    // Preserve a listed entry even when its date is nil: filling it in only for
    // ourselves could make two copies choose different orderings for one snapshot.
    let own = running.first { $0.processIdentifier == ownProcessIdentifier }
      ?? Instance(processIdentifier: ownProcessIdentifier, bundlePath: nil, launchDate: ownLaunchDate)
    let candidates = others + [own]
    // Choose one ordering for the whole set. Mixing date and PID comparisons
    // pair by pair when a date is missing can make the comparison non-transitive.
    let datesAvailable = candidates.allSatisfy { $0.launchDate != nil }
    let winner = candidates.min {
      if datesAvailable, let lhs = $0.launchDate, let rhs = $1.launchDate, lhs != rhs {
        return lhs < rhs
      }
      return $0.processIdentifier < $1.processIdentifier
    }!
    return winner.processIdentifier == ownProcessIdentifier
      ? .proceed : .terminate(runningBundlePath: winner.bundlePath)
  }
}
