import CandelaKit

/// What to do with the failure currently on screen when a preview coordinator
/// re-reads its session.
///
/// One type for all four coordinators — display modes, mirroring, arrangement
/// and rotation each ran an identical private copy, and four copies of a
/// three-case decision is four places for the decision to drift.
enum FailureUpdate {
  case clear
  case keep
  case set(DisplayConfigError)
}
