import AppKit
import SwiftUI

/// The app's one motion voice. Every animation names its role here, so curves
/// and durations cannot drift apart per surface, and the Reduce Motion
/// contract stays uniform: nil (instant), never merely a faster animation.
///
/// Grown out of the panel's motion helper when the settings-wide pass adopted
/// the same vocabulary.
enum Motion {
  /// A disclosure or inline list opening and closing, and a control giving
  /// way to a sibling arriving beside it.
  static func disclosure(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.2)
  }

  /// The menu-bar panel's arrival on each open. Ease-out so the settle
  /// decelerates into place; shorter than a disclosure because it plays on
  /// every open.
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
  /// Motion so orderFront and orderOut land instantly, the same contract as
  /// the nil animations above. In is quicker than out: a window arriving is
  /// something the user is waiting on; a window leaving is not.
  static func windowFadeIn(reduceMotion: Bool) -> TimeInterval {
    reduceMotion ? 0 : 0.15
  }

  static func windowFadeOut(reduceMotion: Bool) -> TimeInterval {
    reduceMotion ? 0 : 0.3
  }

  /// Reduce Motion for AppKit call sites, which have no SwiftUI environment
  /// to read `accessibilityReduceMotion` from.
  static var systemReduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}
