import Foundation
import Testing
@testable import CandelaKit

@Suite("Keep awake")
@MainActor
struct KeepAwakeTests {
  /// Records the pairing rather than taking a real assertion, so the suite can
  /// state "exactly one held" without asking the system what it is holding.
  private final class RecordingHolder: PowerAssertionHolding {
    var created: [String] = []
    var released: [UInt32] = []
    var refuses = false
    private var next: UInt32 = 100

    var outstanding: Int { created.count - released.count }

    func createPreventDisplaySleep(named name: String) -> UInt32? {
      guard !refuses else { return nil }
      created.append(name)
      next += 1
      return next
    }

    func release(_ id: UInt32) { released.append(id) }
  }

  @Test func onTakesOneAssertionAndOffReleasesIt() {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)

    keepAwake.setOn(true)
    #expect(keepAwake.isOn)
    #expect(holder.outstanding == 1)

    keepAwake.setOn(false)
    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)
  }

  /// The name is what a person reads in `pmset -g assertions`, and the hardware
  /// check for this feature is "check the name, not just the count".
  @Test func theAssertionCarriesTheAppsName() {
    let holder = RecordingHolder()
    KeepAwake(holder: holder).setOn(true)
    #expect(holder.created == ["Candela Keep Awake"])
  }

  /// A second `true` must not take a second assertion: one `false` releases one
  /// id, so the extra would stay held with no control left pointing at it.
  @Test func turningItOnTwiceLeavesExactlyOneAssertionHeld() {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.setOn(true)
    keepAwake.setOn(true)
    #expect(holder.created.count == 1)

    keepAwake.setOn(false)
    #expect(holder.outstanding == 0)
  }

  @Test func turningItOffWhenItWasNeverOnReleasesNothing() {
    let holder = RecordingHolder()
    KeepAwake(holder: holder).setOn(false)
    #expect(holder.created.isEmpty)
    #expect(holder.released.isEmpty)
  }

  /// A refused assertion leaves the control OFF. Reporting on over a display
  /// that will sleep anyway is the one outcome worse than not offering it.
  @Test func aRefusedAssertionLeavesTheControlOff() {
    let holder = RecordingHolder()
    holder.refuses = true
    let keepAwake = KeepAwake(holder: holder)

    keepAwake.setOn(true)

    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)
  }

  @Test func toggleFlipsBothWays() {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.toggle()
    #expect(keepAwake.isOn)
    keepAwake.toggle()
    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)
  }
}
