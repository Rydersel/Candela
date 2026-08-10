import Testing
@testable import CandelaKit

@Suite("Settings sidebar selection")
struct SettingsSelectionPolicyTests {
  @Test func keepsAStillConnectedSelection() {
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: "mag", connectedKeys: ["mag"]) == .keep("mag"))
    // A live selection outranks the sibling fallback: "builtIn" is first in the
    // list, so a resolver that reached for the sibling too eagerly would move
    // the user off a display that never went anywhere.
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: "mag", connectedKeys: ["mag", "builtIn"])
            == .keep("mag"))
  }

  @Test func fallsBackToTheFirstSurvivingSibling() {
    // The sidebar must not render a destination for a display that is gone. A
    // surviving display is a better landing place than a pane — the user was
    // looking at display settings, so keep them in display settings.
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: "dell", connectedKeys: ["builtIn", "mag"])
            == .fallbackToSibling("builtIn"))
  }

  @Test func fallsBackToAPaneOnlyWhenNoDisplayRemains() {
    // Clamshell / all-displays-asleep: there is nothing to select at all, so
    // the empty list must not be a special case that keeps a stale key alive.
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: "dell", connectedKeys: [])
            == .fallbackToPane)
  }

  @Test func paneSelectionResolvesToNil() {
    // A pane (not a display) is selected. No key to validate, so the answer is
    // nil regardless of what is connected — and nil means the caller does
    // nothing, never that it should move the selection.
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: nil, connectedKeys: ["mag"]) == nil)
  }

  @Test func aReplugKeepsTheSelectionBecauseTheKeyIsStable() {
    // Why the persistence key is the selection identity rather than the
    // CGDirectDisplayID: a replug (or a link renegotiation) hands the same
    // panel a NEW display ID, so an ID-keyed selection would never match again
    // and the user would be silently kicked out of their pane. The key does not
    // change, so reconnecting restores exactly the selection they had.
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: "mag", connectedKeys: []) == .fallbackToPane)
    #expect(SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: "mag", connectedKeys: ["mag"]) == .keep("mag"))
  }

  @Test func aReturningDisplayTakesBackItsSelection() {
    #expect(SettingsSelectionPolicy.restoration(lastDisplayKey: "dell", arrivedKeys: ["dell"], currentIsDisplay: false) == "dell")
  }

  @Test func restorationNeverYanksTheUserOffADisplayTheyChose() {
    #expect(SettingsSelectionPolicy.restoration(lastDisplayKey: "dell", arrivedKeys: ["dell"], currentIsDisplay: true) == nil)
  }

  @Test func restorationIgnoresUnrelatedArrivals() {
    #expect(SettingsSelectionPolicy.restoration(lastDisplayKey: "dell", arrivedKeys: ["mag"], currentIsDisplay: false) == nil)
  }

  @Test func restorationDoesNothingWithoutARememberedDisplay() {
    // Nothing was remembered, so there is nothing to return to — the arrival of
    // some other display must not invent a selection the user never made.
    #expect(SettingsSelectionPolicy.restoration(lastDisplayKey: nil, arrivedKeys: ["mag"], currentIsDisplay: false) == nil)
  }
}

@Suite("Settings detail presentation")
struct SettingsDetailPresentationTests {
  /// Stands in for the app target's `DisplaySubPage`, which CandelaKit cannot
  /// see. Only its identity matters here.
  private enum Page: String, Sendable { case allModes, advanced, diagnostics }

  @Test func aConnectedDisplayPresentsItsRetainedPath() {
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page.advanced], connectedKeys: ["builtIn", "dell"]
      ) == .display(key: "dell", path: [.advanced])
    )
  }

  @Test func aPaneSelectionPresentsNothingPushed() {
    // A pane has no stack. The retained path belongs to whichever display the
    // user was last on and must not follow them onto a pane.
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: nil, retainedPath: [Page.advanced], connectedKeys: ["dell"]
      ) == .pane
    )
  }

  @Test func aDisconnectedDisplayPresentsThePaneFallbackAndNoPushedPage() {
    // The defect this exists to make impossible (#124): the title and the
    // content each answered this question on their own, and the presented path
    // did not answer it at all. A display that left the list while a sub-page
    // was pushed therefore kept a page in the stack that could not render, so
    // the detail column went blank and declared no toolbar title.
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page.advanced], connectedKeys: ["builtIn"]
      ) == .pane
    )
  }

  @Test func aDisconnectedDisplayWithNothingPushedIsStillThePaneFallback() {
    // Same answer whether or not a page was pushed: the presentation names one
    // destination, so the title and the content cannot disagree about it.
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page](), connectedKeys: []
      ) == .pane
    )
  }

  @Test func retentionIsNotTheSameAsPresentation() {
    // Presenting nothing for an absent display must not be read as clearing
    // what is retained: the same key with the display back presents the same
    // path again (SO23). This function is pure, so that is a property of it
    // rather than of the caller's storage.
    let path = [Page.diagnostics]
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: path, connectedKeys: []
      ) == .pane
    )
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: path, connectedKeys: ["dell"]
      ) == .display(key: "dell", path: path)
    )
  }

  @Test func theDepthMatchesWhatIsPresentedNotWhatIsRetained() {
    // The window configurator re-runs on this number, so a depth taken from
    // retained storage would claim a push that is not on screen.
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page.advanced], connectedKeys: []
      ).pathDepth == 0
    )
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page.advanced], connectedKeys: ["dell"]
      ).pathDepth == 1
    )
  }

  @Test func theSelectedDisplayKeyIsOnlyReportedWhenItIsPresentable() {
    // The convenience the view reads to decide whether a banner region, a hero
    // and a hub exist at all. It must never name a display the detail column is
    // not showing.
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page](), connectedKeys: ["dell"]
      ).displayKey == "dell"
    )
    #expect(
      SettingsSelectionPolicy.present(
        selectedDisplayKey: "dell", retainedPath: [Page](), connectedKeys: []
      ).displayKey == nil
    )
  }
}
