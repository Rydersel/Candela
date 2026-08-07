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
