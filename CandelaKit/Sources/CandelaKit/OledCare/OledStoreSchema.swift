import Foundation

/// Why a persisted OLED wear store could not be read.
///
/// The distinction is the point. JSON that fails to parse is junk and starting
/// over costs nothing, but a store written by a newer schema, or laid out for a
/// different grid, is intact history a later build could migrate. Overwriting
/// that destroys months of wear data, and the schema rule (migrate forward,
/// never wipe on downgrade) forbids it.
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
/// Bump when the meaning or shape of a stored field changes, so an older build
/// quarantines the file instead of reinterpreting it. `PanelGrid` geometry is
/// covered by `gridChanged` and needs no bump: the cell count is
/// self-describing.
public enum OledStoreSchema {
  public static let currentVersion = 1
}
