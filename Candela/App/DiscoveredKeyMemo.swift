import CoreGraphics

/// One display configuration's answers from the persistence-key discovery
/// fallback, including the negative ones.
///
/// A class so the escaping closure that performs the fallback can record what
/// it learned without capturing the model mutably. Main-actor confined: every
/// reader and the one writer that clears it run there.
@MainActor
final class DiscoveredKeyMemo {
  /// `String??`: the outer optional is "have we asked", the inner is what
  /// discovery said. Collapsing them would re-run the walk forever for the
  /// displays discovery cannot see, which are the only ones that reach it.
  private var answers: [CGDirectDisplayID: String?] = [:]

  func value(for displayID: CGDirectDisplayID, otherwise compute: () -> String?) -> String? {
    if let remembered = answers[displayID] { return remembered }
    let answer = compute()
    answers[displayID] = answer
    return answer
  }

  func clear() { answers.removeAll() }
}
