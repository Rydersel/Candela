import os
import Testing
@testable import CandelaKit

// MARK: - Cadence policy

/// One row of the truth table. Every row is spelled out rather than re-derived: a
/// test that recomputes the policy agrees with a wrong one just as readily.
private struct Cell: Sendable, Hashable {
  let moving: Bool
  let surface: Bool
  let sync: Bool
  let native: Bool
  let battery: Bool
  let want: BrightnessPollCadence
}

private let cadenceCells: [Cell] = [
  Cell(moving: false, surface: false, sync: false, native: false, battery: false, want: .slowIdle),
  Cell(moving: false, surface: false, sync: false, native: false, battery: true,  want: .batterySlowIdle),
  Cell(moving: false, surface: false, sync: false, native: true,  battery: false, want: .idle),
  Cell(moving: false, surface: false, sync: false, native: true,  battery: true,  want: .idle),
  Cell(moving: false, surface: true,  sync: false, native: false, battery: false, want: .idle),
  Cell(moving: false, surface: true,  sync: false, native: false, battery: true,  want: .idle),
  Cell(moving: false, surface: true,  sync: false, native: true,  battery: false, want: .idle),
  Cell(moving: false, surface: true,  sync: false, native: true,  battery: true,  want: .idle),
  Cell(moving: false, surface: false, sync: true,  native: false, battery: false, want: .idle),
  Cell(moving: false, surface: false, sync: true,  native: false, battery: true,  want: .idle),
  Cell(moving: false, surface: false, sync: true,  native: true,  battery: false, want: .idle),
  Cell(moving: false, surface: false, sync: true,  native: true,  battery: true,  want: .idle),
  Cell(moving: false, surface: true,  sync: true,  native: false, battery: false, want: .idle),
  Cell(moving: false, surface: true,  sync: true,  native: false, battery: true,  want: .idle),
  Cell(moving: false, surface: true,  sync: true,  native: true,  battery: false, want: .idle),
  Cell(moving: false, surface: true,  sync: true,  native: true,  battery: true,  want: .idle),
  Cell(moving: true,  surface: false, sync: false, native: false, battery: false, want: .fast),
  Cell(moving: true,  surface: false, sync: false, native: false, battery: true,  want: .fast),
  Cell(moving: true,  surface: false, sync: false, native: true,  battery: false, want: .fast),
  Cell(moving: true,  surface: false, sync: false, native: true,  battery: true,  want: .fast),
  Cell(moving: true,  surface: true,  sync: false, native: false, battery: false, want: .fast),
  Cell(moving: true,  surface: true,  sync: false, native: false, battery: true,  want: .fast),
  Cell(moving: true,  surface: true,  sync: false, native: true,  battery: false, want: .fast),
  Cell(moving: true,  surface: true,  sync: false, native: true,  battery: true,  want: .fast),
  Cell(moving: true,  surface: false, sync: true,  native: false, battery: false, want: .fast),
  Cell(moving: true,  surface: false, sync: true,  native: false, battery: true,  want: .fast),
  Cell(moving: true,  surface: false, sync: true,  native: true,  battery: false, want: .fast),
  Cell(moving: true,  surface: false, sync: true,  native: true,  battery: true,  want: .fast),
  Cell(moving: true,  surface: true,  sync: true,  native: false, battery: false, want: .fast),
  Cell(moving: true,  surface: true,  sync: true,  native: false, battery: true,  want: .fast),
  Cell(moving: true,  surface: true,  sync: true,  native: true,  battery: false, want: .fast),
  Cell(moving: true,  surface: true,  sync: true,  native: true,  battery: true,  want: .fast),
]

@Suite("Poll cadence policy")
struct BrightnessPollCadencePolicyTests {
  @Test func theTableCoversEveryCell() {
    #expect(cadenceCells.count == 32)
    // 32 rows is only every cell if no two describe the same inputs: a duplicated
    // row and a missing one look identical from the count alone.
    let inputs = Set(cadenceCells.map { [$0.moving, $0.surface, $0.sync, $0.native, $0.battery] })
    #expect(inputs.count == 32)
  }

  @Test(arguments: cadenceCells)
  fileprivate func cadence(_ cell: Cell) {
    let got = BrightnessPollCadence.choose(
      isMoving: cell.moving,
      isSyncEnabled: cell.sync,
      isSurfaceVisible: cell.surface,
      isExternalNativeActive: cell.native,
      isOnBattery: cell.battery
    )
    #expect(got == cell.want)
  }

  /// The power-source read is the one input with a cost, so it is asked for only
  /// in the branch that uses it.
  @Test func theBatteryIsNotReadUnlessTheSlowBranchIsReached() {
    let asked = OSAllocatedUnfairLock(initialState: 0)
    func onBattery() -> Bool {
      asked.withLock { $0 += 1 }
      return false
    }
    _ = BrightnessPollCadence.choose(
      isMoving: true, isSyncEnabled: false, isSurfaceVisible: false,
      isExternalNativeActive: false, isOnBattery: onBattery())
    _ = BrightnessPollCadence.choose(
      isMoving: false, isSyncEnabled: false, isSurfaceVisible: true,
      isExternalNativeActive: false, isOnBattery: onBattery())
    #expect(asked.withLock { $0 } == 0)
    _ = BrightnessPollCadence.choose(
      isMoving: false, isSyncEnabled: false, isSurfaceVisible: false,
      isExternalNativeActive: false, isOnBattery: onBattery())
    #expect(asked.withLock { $0 } == 1)
  }
}
