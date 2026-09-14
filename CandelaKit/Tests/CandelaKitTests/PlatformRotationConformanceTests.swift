import Testing
@testable import CandelaKit

@Suite("Rotation platform conformance")
struct PlatformRotationConformanceTests {
  private typealias PC = PlatformConformance

  @Test func delayedApplyAndRestoreReadbackPass() {
    var readings: [DisplayRotation?] = [.twoSeventy, .standard, .standard, .twoSeventy]
    var requested: [DisplayRotation] = []
    let outcome = PC.rotationRoundtrip(
      displayID: 2, before: .twoSeventy,
      set: { requested.append($0); return 0 },
      read: { readings.removeFirst() }, pause: {}
    )
    #expect(outcome == .pass("display 2: 270 -> 0 -> 270 verified"))
    #expect(requested == [.standard, .twoSeventy])
    #expect(readings.isEmpty)
  }

  @Test(arguments: [false, true])
  func anUnachievedApplyFailsAndStillRestores(unreadable: Bool) {
    var requested: [DisplayRotation] = []
    var reads = 0
    let outcome = PC.rotationRoundtrip(
      displayID: 2, before: .twoSeventy,
      set: { requested.append($0); return 0 },
      read: {
        reads += 1
        if requested.count == 1 { return unreadable ? nil : .twoSeventy }
        return .twoSeventy
      }, pause: {}
    )
    guard case let .fail(detail) = outcome else {
      Issue.record("a successful setter without the requested orientation must fail")
      return
    }
    #expect(detail.contains("apply 0 returned 0"))
    #expect(detail.contains(unreadable ? "readback unreadable" : "readback 270"))
    #expect(detail.contains("restore 270 returned 0, readback 270"))
    #expect(requested == [.standard, .twoSeventy])
    #expect(reads > 1 && reads < 100)
  }

  @Test(arguments: [false, true])
  func setterFailureIsNotHiddenByCorrectReadback(failsRestore: Bool) {
    var current = DisplayRotation.twoSeventy
    var requests = 0
    let outcome = PC.rotationRoundtrip(
      displayID: 2, before: .twoSeventy,
      set: {
        current = $0
        requests += 1
        return (requests == 2) == failsRestore ? 1001 : 0
      }, read: { current }, pause: {}
    )
    guard case let .fail(detail) = outcome else {
      Issue.record("a nonzero setter result must fail even with matching readback")
      return
    }
    #expect(detail.contains(failsRestore ? "restore 270 returned 1001" : "apply 0 returned 1001"))
    #expect(requests == 2)
  }

  @Test(arguments: [false, true])
  func failureToRestoreIsReported(unreadable: Bool) {
    var requests = 0
    let outcome = PC.rotationRoundtrip(
      displayID: 2, before: .twoSeventy,
      set: { _ in requests += 1; return 0 },
      read: { requests == 2 && unreadable ? nil : .standard }, pause: {}
    )
    guard case let .fail(detail) = outcome else {
      Issue.record("an unrestored display must fail")
      return
    }
    #expect(detail.contains("restore 270 returned 0, readback \(unreadable ? "unreadable" : "0")"))
  }

  @Test func uprightDisplayGetsADifferentSupportedTarget() {
    var current = DisplayRotation.standard
    var requested: [DisplayRotation] = []
    let outcome = PC.rotationRoundtrip(
      displayID: 2, before: .standard,
      set: { requested.append($0); current = $0; return 0 },
      read: { current }, pause: {}
    )
    #expect(outcome == .pass("display 2: 0 -> 90 -> 0 verified"))
    #expect(requested == [.ninety, .standard])
  }
}
