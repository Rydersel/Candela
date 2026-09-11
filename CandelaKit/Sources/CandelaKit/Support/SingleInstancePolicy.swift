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

    public init(processIdentifier: Int32, bundlePath: String?) {
      self.processIdentifier = processIdentifier
      self.bundlePath = bundlePath
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
  public static func decide(running: [Instance], ownProcessIdentifier: Int32) -> Decision {
    let others = running.filter { $0.processIdentifier != ownProcessIdentifier }
    guard let first = others.first else { return .proceed }
    return .terminate(runningBundlePath: first.bundlePath)
  }
}
