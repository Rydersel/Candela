import Foundation

/// How a preview ended, for every kind of preview there is.
///
/// Named `ModePreviewOutcome` and declared inside `ModePreviewSession` until
/// #68, by which point it was the return type of all four preview sessions
/// (mode, mirror, rotation, arrangement) and the name said otherwise. Renaming
/// it costs nothing on disk: it is a runtime type with no raw values and no
/// persisted form, so it is not shipped schema the way a pref key is.
public enum PreviewOutcome: Sendable, Equatable {
  case committed
  case reverted
  case failed(DisplayConfigError)
  /// The answer named a preview that is no longer the outstanding one, so it
  /// resolved nothing and the outstanding preview is untouched. An answer is
  /// given about something a person was looking at; applying it to a different
  /// preview would commit a mode they never saw.
  case stale
}
