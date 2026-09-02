import AppKit
import CandelaKit
import CoreGraphics
import Testing

// `ShadeOverlay` is the software-dimming fallback: one black, click-through,
// shielding-level window per display, whose content-view alpha carries the dim.
//
// Two properties here are worth more than the rest. `setShadeAlpha` returns
// Bool so the engine never memoises a dimming that did not land, and its
// false answer is the only signal that exists: a display that was never shaded
// is indistinguishable from a shaded one at every layer the engine can see. And
// the dim rides the CONTENT VIEW's alpha, never the window's, because an
// alpha-faded window composites differently and reads washed out at low dim
// levels; both are silent when they break.
//
// A note on the windows these cases build. They are real `NSWindow`s on the
// attached displays, but a host-free bundle's windows never reach the screen:
// measured 2026-08-17, `CGWindowListCopyWindowInfo` does not list them at any
// option set while `NSApplication.shared.windows` does. Nothing here can dim a
// panel, and no window-server route to checking teardown exists from in here.
@Suite("Shade overlay") @MainActor
struct ShadeOverlayTests {
  /// The windows `body` adds to this process, identified by difference rather
  /// than by title. Titles collide: every `ShadeOverlay` names its windows the
  /// same way, closed windows stay in `NSApplication.shared.windows` for the
  /// rest of the process, and cases share a process.
  private static func windowsCreated(by body: () -> Void) -> [NSWindow] {
    let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
    body()
    return NSApplication.shared.windows.filter { !before.contains(ObjectIdentifier($0)) }
  }

  private static var firstScreen: NSScreen? {
    NSScreen.screens.first { $0.displayID != nil }
  }

  /// The engine memoises the brightness it believes it applied, so a
  /// shade that could not be built has to say so: a silent success leaves the
  /// display at its old level with the engine convinced it moved, and nothing
  /// downstream ever retries.
  @Test func setShadeAlphaReportsFalseWhenNoScreenMatchesTheDisplay() {
    let overlay = ShadeOverlay()
    #expect(overlay.setShadeAlpha(0.5, on: OverlayWindowTests.unmatchedDisplayID) == false)
  }

  /// A display can depart between the engine deciding to undim it and the call
  /// arriving, and reconfiguration handling removes shades it may never have
  /// created, so removal is allowed to be asked for anything. Teardown's other
  /// half (that a removed shade's window is really gone) is not checkable from
  /// this bundle at all, since the window server does not list these windows.
  @Test func removingAShadeThatWasNeverCreatedIsANoOp() {
    let overlay = ShadeOverlay()
    overlay.removeShade(for: OverlayWindowTests.unmatchedDisplayID)
    overlay.removeAllShades()
    overlay.repinFrames()
    // Surviving the three calls is the assertion; stating it makes the case
    // report a result, and proves the overlay is still usable afterwards.
    #expect(overlay.setShadeAlpha(0.5, on: OverlayWindowTests.unmatchedDisplayID) == false)
  }

  /// The dim's control point, checked on the window that carries it.
  ///
  /// The window's own alpha staying at 1 is half the assertion and the half
  /// that is easy to lose: fading the window instead of its content view looks
  /// like a working shade in code review and reads washed out on the panel.
  @Test func aShadeDimsItsContentViewAndLeavesItsWindowOpaque() throws {
    let screen = try #require(Self.firstScreen, "the test process sees no screens")
    let displayID = try #require(screen.displayID)
    let overlay = ShadeOverlay()
    defer { overlay.removeAllShades() }

    var applied = false
    let made = Self.windowsCreated { applied = overlay.setShadeAlpha(0.4, on: displayID) }
    #expect(applied)
    #expect(made.count == 1)
    let shade = try #require(made.first)

    #expect(shade.alphaValue == 1)
    #expect(shade.contentView?.alphaValue == 0.4)
    // The recipe reached the real window, not just the value it is described
    // by. Level and click-through are the two whose failure is invisible until
    // something paints over the shade or a click disappears into it.
    #expect(shade.level == OverlayWindowConfig.dimming.level)
    #expect(shade.ignoresMouseEvents)
    #expect(shade.collectionBehavior == OverlayWindowConfig.dimming.collectionBehavior)
    #expect(shade.frame == screen.frame)
  }

  /// `alphaValue` carries 0...1, so a caller handing over a value outside it
  /// must be clamped rather than allowed to reach AppKit. The second call also
  /// covers reuse: the display's existing shade is updated, not replaced.
  @Test func anOutOfRangeDimIsClampedOnTheShade() throws {
    let screen = try #require(Self.firstScreen, "the test process sees no screens")
    let displayID = try #require(screen.displayID)
    let overlay = ShadeOverlay()
    defer { overlay.removeAllShades() }

    let made = Self.windowsCreated { _ = overlay.setShadeAlpha(1.8, on: displayID) }
    let shade = try #require(made.first)
    #expect(made.count == 1)
    #expect(shade.contentView?.alphaValue == 1)

    let reused = Self.windowsCreated { _ = overlay.setShadeAlpha(-0.6, on: displayID) }
    #expect(reused.isEmpty, "the display's shade should be reused, not rebuilt")
    #expect(shade.contentView?.alphaValue == 0)
  }
}
