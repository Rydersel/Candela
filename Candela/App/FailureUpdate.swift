import CandelaKit

/// What to do with the failure on screen when a preview coordinator re-reads
/// its session. Shared by every preview coordinator so it cannot drift.
enum FailureUpdate {
  case clear
  case keep
  case set(DisplayConfigError)
}
