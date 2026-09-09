import SwiftUI
import Testing

/// The settings window's poll-consumer signal.
///
/// The window's own answer wins wherever there is one; activation is the fallback
/// for the moment before a window has attached, and on its own it cannot tell a
/// settings page open beside another app from a closed one (every window of a
/// non-frontmost app reports `.inactive`).
///
/// The occlusion observation that produces the window's answer is AppKit window
/// lifecycle no bundle test reaches. Its hardware leg: leave Settings open beside
/// another frontmost app, move brightness in Control Center, and watch the hero
/// slider follow within about a second rather than at the next slow tick.
@Suite("Settings visibility signal") @MainActor
struct SettingsVisibilitySignalTests {
  private func onScreen(_ windowVisibility: Bool?, _ activeState: ControlActiveState) -> Bool {
    SettingsRootView.isSettingsOnScreen(
      windowVisibility: windowVisibility, activeState: activeState)
  }

  /// The finding this shape exists for.
  @Test func aWindowThatSaysItIsOnScreenIsOnScreenWhileTheAppIsBehindAnother() {
    #expect(onScreen(true, .inactive))
  }

  /// The other direction, and the one that pays for itself: a fully covered or
  /// closed window is off screen however active the app is.
  @Test func aWindowThatSaysItIsCoveredIsOffScreenHoweverActiveTheAppIs() {
    #expect(onScreen(false, .key) == false)
    #expect(onScreen(false, .active) == false)
    #expect(onScreen(false, .inactive) == false)
  }

  /// Until a window has attached there is nothing to ask, so activation answers.
  @Test func activationAnswersOnlyWhileNoWindowHasAttached() {
    #expect(onScreen(nil, .key))
    #expect(onScreen(nil, .active))
    #expect(onScreen(nil, .inactive) == false)
  }
}
