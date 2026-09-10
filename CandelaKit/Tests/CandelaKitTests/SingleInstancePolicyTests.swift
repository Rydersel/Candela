import Testing

@testable import CandelaKit

@Suite("Single instance policy")
struct SingleInstancePolicyTests {
  private static let ownPID: Int32 = 42

  private func own(path: String? = "/Applications/Candela.app") -> SingleInstancePolicy.Instance {
    SingleInstancePolicy.Instance(processIdentifier: Self.ownPID, bundlePath: path)
  }

  private func decide(_ running: [SingleInstancePolicy.Instance]) -> SingleInstancePolicy.Decision {
    SingleInstancePolicy.decide(running: running, ownProcessIdentifier: Self.ownPID)
  }

  /// The ordinary launch: the enumeration finds us and nothing else.
  @Test func onlyOurOwnProcessMeansProceed() {
    #expect(decide([own()]) == .proceed)
  }

  /// The path goes into the alert, so the decision has to carry it: telling
  /// someone another copy is running without saying where leaves them hunting.
  @Test func anotherProcessMeansTerminateAndNamesItsPath() {
    let other = SingleInstancePolicy.Instance(
      processIdentifier: 7, bundlePath: "/Applications/Candela.app"
    )
    #expect(decide([own(path: "/Users/me/Build/Candela.app"), other])
      == .terminate(runningBundlePath: "/Applications/Candela.app"))
  }

  /// The enumeration failing must never lock anyone out: an app that refuses to
  /// launch because it cannot see itself has no route back from the UI.
  @Test func anEmptyListProceeds() {
    #expect(decide([]) == .proceed)
  }

  /// A running instance whose path cannot be read is still a running instance;
  /// the alert says so with a nil path rather than inventing a location.
  @Test func aMissingBundlePathStillTerminates() {
    let other = SingleInstancePolicy.Instance(processIdentifier: 7, bundlePath: nil)
    #expect(decide([own(), other]) == .terminate(runningBundlePath: nil))
  }

  /// Defensive: the exclusion is by pid, so a list that reports us twice still
  /// leaves no survivor.
  @Test func ourOwnPidIsExcludedEvenWhenItAppearsTwice() {
    #expect(decide([own(), own(path: nil)]) == .proceed)
  }
}
