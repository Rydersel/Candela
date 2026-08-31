import AppKit
import SwiftUI

/// The app's one motion voice. Every animation names its role here, so curves
/// and durations cannot drift apart per surface, and the Reduce Motion contract
/// stays uniform: nil (instant), never merely a faster animation.
///
/// Hover reveals, press feedback, and crossfades between two renderings of the
/// same data stay OUTSIDE this vocabulary. They are per-surface feel rather than
/// a state change a person made, so each carries its own curve and its own
/// Reduce Motion guard at its site. A mixed idiom in one of those views is
/// intent; anything a user's action moves belongs to a role below.
enum Motion {
  /// A disclosure or inline list opening and closing, and a control giving
  /// way to a sibling arriving beside it.
  static func disclosure(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.2)
  }

  /// The menu-bar panel's arrival. Ease-out so it decelerates into place, and
  /// shorter than a disclosure because it plays on every open.
  static func entrance(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.18)
  }

  /// A banner or inline notice arriving or leaving.
  static func notice(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.2)
  }

  /// A dragged element settling into place, or springing back home after an
  /// invalid drop.
  static func settle(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.2)
  }

  /// A live readout changing value; pairs with `.contentTransition`.
  static func value(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .default
  }

  /// A programmatic scroll to an anchor.
  static func scroll(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .default
  }

  /// AppKit window fade durations for `NSAnimationContext`. Zero under Reduce
  /// Motion, the same contract as the nil animations above. In is quicker than
  /// out: a window arriving is something the user is waiting on.
  static func windowFadeIn(reduceMotion: Bool) -> TimeInterval {
    reduceMotion ? 0 : 0.15
  }

  static func windowFadeOut(reduceMotion: Bool) -> TimeInterval {
    reduceMotion ? 0 : 0.3
  }

  /// An AppKit window's own frame changing under it, such as the confirmation
  /// window growing as a caption arrives. Same value as `windowFadeIn` because it
  /// is the same register, and zero under Reduce Motion. Named separately so a
  /// fade duration can move without silently retiming every resize.
  static func windowResize(reduceMotion: Bool) -> TimeInterval {
    reduceMotion ? 0 : 0.15
  }

  /// Reduce Motion for AppKit call sites, which have no SwiftUI environment
  /// to read `accessibilityReduceMotion` from.
  static var systemReduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}
