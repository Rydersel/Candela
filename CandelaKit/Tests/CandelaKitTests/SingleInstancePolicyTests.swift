import Foundation
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
  @Test func simultaneousCopiesChooseTheSameSurvivor() {
    let copies = [
      SingleInstancePolicy.Instance(processIdentifier: 7, bundlePath: "/Applications/Candela.app"),
      SingleInstancePolicy.Instance(processIdentifier: 42, bundlePath: "/tmp/Candela.app"),
    ]
    let decisions = copies.map { copy in
      SingleInstancePolicy.decide(running: copies, ownProcessIdentifier: copy.processIdentifier)
    }
    #expect(decisions.filter { $0 == .proceed }.count == 1)
    #expect(decisions[0] == .proceed)
    #expect(decisions[1] == .terminate(runningBundlePath: "/Applications/Candela.app"))
  }

  @Test(arguments: [false, true])
  func theEarlierLaunchSurvivesRegardlessOfListOrderOrPID(reverse: Bool) {
    let older = SingleInstancePolicy.Instance(processIdentifier: 90, bundlePath: "/old/Candela.app",
      launchDate: Date(timeIntervalSince1970: 100))
    let newer = SingleInstancePolicy.Instance(processIdentifier: 7, bundlePath: "/new/Candela.app",
      launchDate: Date(timeIntervalSince1970: 101))
    let copies = reverse ? [newer, older] : [older, newer]
    #expect(SingleInstancePolicy.decide(running: copies, ownProcessIdentifier: 90) == .proceed)
    #expect(SingleInstancePolicy.decide(running: copies, ownProcessIdentifier: 7)
      == .terminate(runningBundlePath: "/old/Candela.app"))
  }

  @Test(arguments: [true, false])
  func equalOrMissingDatesUseOnePIDOrdering(equalDates: Bool) {
    let date = Date(timeIntervalSince1970: 100)
    let copies = [
      SingleInstancePolicy.Instance(processIdentifier: 90, bundlePath: "/third/Candela.app", launchDate: date),
      SingleInstancePolicy.Instance(processIdentifier: 7, bundlePath: "/first/Candela.app", launchDate: equalDates ? date : nil),
      SingleInstancePolicy.Instance(processIdentifier: 42, bundlePath: "/second/Candela.app", launchDate: date),
    ]
    for order in [copies, Array(copies.reversed()), [copies[1], copies[2], copies[0]]] {
      let survivors = order.filter {
        SingleInstancePolicy.decide(running: order, ownProcessIdentifier: $0.processIdentifier) == .proceed
      }
      #expect(survivors.map(\.processIdentifier) == [7])
    }
  }

  @Test func ownLaunchDateParticipatesEvenBeforeTheProcessIsListed() {
    let other = SingleInstancePolicy.Instance(processIdentifier: 7, bundlePath: "/other/Candela.app",
      launchDate: Date(timeIntervalSince1970: 101))
    #expect(SingleInstancePolicy.decide(running: [other], ownProcessIdentifier: 90,
      ownLaunchDate: Date(timeIntervalSince1970: 100)) == .proceed)
    #expect(SingleInstancePolicy.decide(running: [other], ownProcessIdentifier: 90,
      ownLaunchDate: Date(timeIntervalSince1970: 102)) == .terminate(runningBundlePath: "/other/Candela.app"))
  }

  @Test func eachCopyUsesTheSameSnapshotWhenItsOwnDateIsMissing() {
    let snapshot = [
      SingleInstancePolicy.Instance(processIdentifier: 90, bundlePath: "/old/Candela.app",
        launchDate: Date(timeIntervalSince1970: 100)),
      SingleInstancePolicy.Instance(processIdentifier: 7, bundlePath: "/new/Candela.app"),
    ]
    let decisions = [
      SingleInstancePolicy.decide(running: snapshot, ownProcessIdentifier: 90,
        ownLaunchDate: Date(timeIntervalSince1970: 100)),
      SingleInstancePolicy.decide(running: snapshot, ownProcessIdentifier: 7,
        ownLaunchDate: Date(timeIntervalSince1970: 101)),
    ]
    #expect(decisions.filter { $0 == .proceed }.count == 1)
  }

}
