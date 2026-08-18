import AppKit
import CoreGraphics
import Testing

// The overlay windows cover a user's whole display at `CGShieldingWindowLevel()`,
// which is the worst place to find out a flag is wrong: a shade that stops
// covering full-screen apps still looks like a working shade until someone goes
// full-screen, and a shade that stops being click-through eats clicks on live
// UI. Every assertion below is on a property whose failure is silent.
//
// What is deliberately NOT here: anything that only restates the extraction of
// `OverlayWindow` out of the two overlay classes. A test that would pass either
// way buys nothing.
@Suite("Overlay window") @MainActor
struct OverlayWindowTests {
  // MARK: - The recipe, as a value

  /// The recipe is checkable without opening a window, which is the reason it
  /// is a value at all. Each of these has a named failure mode: a level below
  /// shielding lets the screen saver paint over the dim; a missing
  /// `.fullScreenAuxiliary` drops the overlay when a space goes full-screen; a
  /// missing `.canJoinAllSpaces` or `.stationary` leaves other spaces
  /// undimmed; mouse events not ignored turns a click into a blind one; and
  /// released-when-closed frees a window its owner still holds.
  @Test func theDimmingRecipeIsTheShieldingLevelClickThroughSet() {
    let config = OverlayWindowConfig.dimming
    #expect(config.level == NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())))
    #expect(config.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(config.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(config.collectionBehavior.contains(.stationary))
    #expect(config.collectionBehavior.contains(.ignoresCycle))
    // Exactly those four: an extra flag is as much a behaviour change as a
    // missing one (`.moveToActiveSpace` alone would undo `.canJoinAllSpaces`).
    #expect(
      config.collectionBehavior
        == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
    #expect(config.ignoresMouseEvents)
    #expect(config.isReleasedWhenClosed == false)
    #expect(config.isMovableByWindowBackground == false)
    #expect(config.initialContentAlpha == 0)
  }

  /// The value and the window have to agree, or describing the recipe as a
  /// value is worse than not describing it: this is what catches a field added
  /// to the config and never read by the applier.
  ///
  /// The window here is never ordered front, so nothing reaches the screen.
  @Test func configureAppliesEveryPropertyTheRecipeCarries() {
    let window = NSWindow(
      contentRect: OverlayWindow.seedRect, styleMask: OverlayWindow.styleMask,
      backing: .buffered, defer: false)
    // Not the seed rect, and not any screen's frame: an arbitrary rect proves
    // the frame argument is what lands.
    let frame = NSRect(x: 120, y: 60, width: 400, height: 300)
    OverlayWindow.configure(window, title: "Overlay window test", covering: frame)
    defer { window.close() }

    let config = OverlayWindowConfig.dimming
    #expect(window.title == "Overlay window test")
    #expect(window.level == config.level)
    #expect(window.collectionBehavior == config.collectionBehavior)
    #expect(window.ignoresMouseEvents == config.ignoresMouseEvents)
    #expect(window.isReleasedWhenClosed == config.isReleasedWhenClosed)
    #expect(window.isMovableByWindowBackground == config.isMovableByWindowBackground)
    #expect(window.frame == frame)
    // The window is clear and the black lives in the content layer. Swapping
    // the two (a black window faded by its own alpha) is the exact mistake the
    // recipe exists to prevent: it composites differently and reads washed out
    // at low dim levels.
    #expect(window.backgroundColor.alphaComponent == 0)
    #expect(window.contentView?.wantsLayer == true)
    #expect(window.contentView?.alphaValue == config.initialContentAlpha)
    #expect(window.contentView?.layer?.backgroundColor == CGColor.black)
  }

  // MARK: - The alpha clamp

  /// `alphaValue` carries 0...1 and nothing else. The interesting half is the
  /// non-finite one: a bare `min(max(NaN, 0), 1)` is NaN, because every
  /// comparison against NaN is false, and a NaN alpha compares unequal to
  /// itself, which silently defeats OLED care's write-only-on-change guard and
  /// turns the overlay into a per-tick write to the window server.
  @Test func clampedAlphaHoldsTheRangeAnAlphaValueCanCarry() {
    #expect(OverlayWindow.clampedAlpha(0.25) == 0.25)
    #expect(OverlayWindow.clampedAlpha(0) == 0)
    #expect(OverlayWindow.clampedAlpha(1) == 1)
    #expect(OverlayWindow.clampedAlpha(-0.5) == 0)
    #expect(OverlayWindow.clampedAlpha(1.5) == 1)
    #expect(OverlayWindow.clampedAlpha(.nan) == 0)
    #expect(OverlayWindow.clampedAlpha(.infinity) == 0)
    #expect(OverlayWindow.clampedAlpha(-.infinity) == 0)
    // The property the guard exists for, stated directly.
    #expect(OverlayWindow.clampedAlpha(.nan) == OverlayWindow.clampedAlpha(.nan))
  }

  // MARK: - Helpers

  /// A display ID no attached screen answers to. Derived from the live set
  /// rather than picked as a constant, so it stays absent whatever is plugged
  /// in when the suite runs.
  static var unmatchedDisplayID: CGDirectDisplayID {
    let live = Set(NSScreen.screens.compactMap(\.displayID))
    var candidate: CGDirectDisplayID = 0xFFFF_0000
    while live.contains(candidate) {
      candidate += 1
    }
    return candidate
  }
}
