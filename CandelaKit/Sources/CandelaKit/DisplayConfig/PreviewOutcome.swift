import Foundation

/// How a preview ended, for every kind of preview there is.
public enum PreviewOutcome: Sendable, Equatable {
  case committed
  case reverted
  case failed(DisplayConfigError)
  /// The answer named a preview that is no longer outstanding, so it resolved
  /// nothing. Applying it to a different preview would commit a mode nobody
  /// looked at.
  case stale
}
