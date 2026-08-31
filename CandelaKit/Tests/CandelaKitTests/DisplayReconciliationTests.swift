import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// A display ID is not a panel. macOS reassigns IDs across a replug (measured: the
/// MAG went 3 to 2 and the Dell 2 to 3 across one dock cycle), so an ID that is
/// still present can be a different monitor, and state reconciled on the ID alone
/// follows the wire rather than the panel.
@Suite("Display reconciliation (#51)")
struct DisplayReconciliationTests {
  private let mag = "mag-edid-uuid"
  private let dell = "dell-edid-uuid"

  @Test("an untouched topology reuses everything")
  func steadyStateReuses() {
    let plan = DisplayReconciliation.plan(held: [2: mag, 3: dell], discovered: [2: mag, 3: dell])
    #expect(plan.reused == [2, 3])
    #expect(plan.built.isEmpty)
    #expect(plan.departed.isEmpty)
  }

  /// The bug. Same ID, different panel: the held state describes a monitor that
  /// is no longer on the other end, so reusing it would persist the new panel's
  /// brightness under the old panel's key and hand it the old panel's tuning.
  @Test("a different panel on a held ID is built fresh, not reused")
  func swappedPanelIsBuiltFresh() {
    let plan = DisplayReconciliation.plan(held: [2: mag], discovered: [2: dell])
    #expect(plan.reused.isEmpty)
    #expect(plan.built == [2])
    #expect(plan.departed == [2])
  }

  /// The swap has to be ANNOUNCED as a departure too, not silently replaced:
  /// the departure list is what drops the old panel's HUD and what the
  /// diagnostics ring records.
  @Test("the replaced panel is reported departed even though its ID is still live")
  func swapReportsADeparture() {
    let plan = DisplayReconciliation.plan(held: [2: mag], discovered: [2: dell])
    #expect(plan.departed.contains(2))
  }

  @Test("an ID that stopped being reported has departed")
  func unplugDeparts() {
    let plan = DisplayReconciliation.plan(held: [2: mag, 3: dell], discovered: [2: mag])
    #expect(plan.reused == [2])
    #expect(plan.departed == [3])
    #expect(plan.built.isEmpty)
  }

  @Test("an ID nobody held is a plain arrival, and no departure")
  func newIDArrives() {
    let plan = DisplayReconciliation.plan(held: [2: mag], discovered: [2: mag, 5: dell])
    #expect(plan.reused == [2])
    #expect(plan.built == [5])
    #expect(plan.departed.isEmpty)
  }

  /// The measured dock-cycle case: both panels present throughout, both IDs
  /// reassigned. Every ID is held and every ID is discovered, yet NOTHING may be
  /// reused, because each ID now carries the other panel's state.
  @Test("two panels swapping IDs reuse nothing and both count as departures")
  func swappedIDsAcrossADockCycle() {
    let plan = DisplayReconciliation.plan(held: [2: mag, 3: dell], discovered: [2: dell, 3: mag])
    #expect(plan.reused.isEmpty)
    #expect(plan.built == [2, 3])
    #expect(plan.departed == [2, 3])
  }

  @Test("an empty topology departs everything held")
  func everythingUnplugged() {
    let plan = DisplayReconciliation.plan(held: [2: mag, 3: dell], discovered: [:])
    #expect(plan.departed == [2, 3])
    #expect(plan.reused.isEmpty)
    #expect(plan.built.isEmpty)
  }

  @Test("the first pass builds everything and departs nothing")
  func coldStart() {
    let plan = DisplayReconciliation.plan(held: [:], discovered: [2: mag, 3: dell])
    #expect(plan.built == [2, 3])
    #expect(plan.reused.isEmpty)
    #expect(plan.departed.isEmpty)
  }

  /// Every discovered ID must end up in exactly one of reused or built, or the
  /// caller either drops a display or builds one twice.
  @Test("reused and built partition the discovered set")
  func reusedAndBuiltPartitionDiscovery() {
    let discovered: [CGDirectDisplayID: String] = [2: dell, 3: mag, 7: "third-panel"]
    let plan = DisplayReconciliation.plan(held: [2: mag, 3: mag], discovered: discovered)
    #expect(plan.reused.isDisjoint(with: plan.built))
    #expect(plan.reused.union(plan.built) == Set(discovered.keys))
  }
}
