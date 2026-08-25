import Foundation

/// Why a persisted OLED wear store could not be read.
///
/// The distinction is the whole point of the type. Both cases below describe
/// bytes this build cannot interpret, but only one of them describes bytes that
/// are *worthless*: JSON that fails to parse at all is junk and starting over
/// costs nothing, while a store written by a schema this build predates, or one
/// laid out for a different grid, is intact history that a later build could
/// migrate. Overwriting the second kind destroys wear data accumulated over
/// months, and D-schema (§4: migrate forward, never wipe on downgrade) forbids
/// it.
///
/// A `DecodingError` therefore means "discard"; an `OledStoreDecodeFailure`
/// means "keep the bytes and write nothing".
public enum OledStoreDecodeFailure: Error, Equatable, Sendable {
  /// Written by a newer build. The version field is the only thing this build
  /// is guaranteed to understand about it.
  case unsupportedVersion(found: Int, supported: Int)
  /// The right schema over a different grid geometry. Always a deliberate shape
  /// change rather than damage, because a truncated array does not round to a
  /// plausible cell count.
  case gridChanged(found: Int, expected: Int)
}

/// The on-disk schema version shared by both wear stores.
///
/// Bump when the meaning or the shape of a stored field changes, so an older
/// build quarantines the file instead of reinterpreting it. `PanelGrid`
/// geometry is covered separately by `gridChanged`, which needs no bump: the
/// cell count is self-describing.
public enum OledStoreSchema {
  public static let currentVersion = 1
}
