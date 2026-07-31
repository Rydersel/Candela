import Testing
@testable import CandelaKit

@Suite("Settings sidebar selection")
struct SettingsSelectionPolicyTests {
  @Test func keepsASelectionThatIsStillConnected() {
    #expect(SettingsSelectionPolicy.resolve(selectedDisplayKey: "mag", connectedKeys: ["mag", "builtIn"]) == "mag")
  }

  @Test func dropsASelectionThatDisconnected() {
    // The sidebar must not render a destination for a display that is gone —
    // the caller falls back to a pane on nil.
    #expect(SettingsSelectionPolicy.resolve(selectedDisplayKey: "mag", connectedKeys: ["builtIn"]) == nil)
  }

  @Test func dropsEverySelectionWhenNothingIsConnected() {
    // Clamshell / all-displays-asleep: there is nothing to select at all, so
    // the empty list must not be a special case that keeps a stale key alive.
    #expect(SettingsSelectionPolicy.resolve(selectedDisplayKey: "mag", connectedKeys: []) == nil)
  }

  @Test func passesThroughWhenNoDisplayIsSelected() {
    // A pane (not a display) is selected. No key to validate, so the answer is
    // nil regardless of what is connected.
    #expect(SettingsSelectionPolicy.resolve(selectedDisplayKey: nil, connectedKeys: ["mag"]) == nil)
  }

  @Test func aReplugKeepsTheSelectionBecauseTheKeyIsStable() {
    // Why the persistence key is the selection identity rather than the
    // CGDirectDisplayID: a replug (or a link renegotiation) hands the same
    // panel a NEW display ID, so an ID-keyed selection would never match again
    // and the user would be silently kicked out of their pane. The key does not
    // change, so reconnecting restores exactly the selection they had.
    #expect(SettingsSelectionPolicy.resolve(selectedDisplayKey: "mag", connectedKeys: []) == nil)
    #expect(SettingsSelectionPolicy.resolve(selectedDisplayKey: "mag", connectedKeys: ["mag"]) == "mag")
  }
}
