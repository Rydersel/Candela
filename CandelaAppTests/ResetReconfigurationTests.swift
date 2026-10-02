import CandelaKit
import Testing

@Suite("Settings reset reconfiguration ownership") @MainActor
struct ResetReconfigurationTests {
  @Test(arguments: [ReconfigurationClaimant.displayModes, .mirroring, .rotation, .arrangement, .hdr, .checkup])
  func aDisplayChangeRefusesResetBeforeItsBodyRuns(_ holder: ReconfigurationClaimant) async {
    let model = TestFixtures.appModel()
    _ = await model.reconfigurationGate.claim(holder)
    var ran = false
    #expect(await !model.withSettingsReset { ran = true })
    #expect(!ran)
    #expect(!model.isResetting)
    #expect(model.resetRefusalMessage != nil)
    #expect(await model.reconfigurationGate.holder == holder)
  }

  @Test func aResetReservesEveryDisplayChangeUntilItsBodyAndCleanupFinish() async {
    let model = TestFixtures.appModel()
    let ran = await model.withSettingsReset {
      #expect(model.isResetting)
      #expect(await model.reconfigurationGate.holder == .settingsReset)
      for claimant in ReconfigurationClaimant.allCases where claimant != .settingsReset {
        #expect(await model.reconfigurationGate.claim(claimant) == .refused(by: .settingsReset))
      }
      #expect(await !model.beginReset())
    }
    #expect(ran)
    #expect(!model.isResetting)
    #expect(await model.reconfigurationGate.holder == nil)
    #expect(await model.beginReset())
    await model.endReset()
  }

  @Test func cancellationBeforeAdmissionNeverRunsTheResetOrLeavesAClaim() async {
    let model = TestFixtures.appModel()
    var ran = false
    let task = Task { @MainActor in
      await model.withSettingsReset { ran = true }
    }
    task.cancel()
    #expect(await !task.value)
    #expect(!ran)
    #expect(!model.isResetting)
    #expect(await model.reconfigurationGate.holder == nil)
    #expect(await model.beginReset())
    await model.endReset()
  }

  @Test func cancellationInsideTheResetHoldsTheClaimThroughCleanupThenReleasesIt() async {
    let model = TestFixtures.appModel()
    let task = Task { @MainActor in
      await model.withSettingsReset {
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(Task.isCancelled)
        #expect(model.isResetting)
        #expect(await model.reconfigurationGate.holder == .settingsReset)
        await Task.yield()
        #expect(await model.reconfigurationGate.claim(.rotation) == .refused(by: .settingsReset))
      }
    }
    #expect(await task.value)
    #expect(!model.isResetting)
    #expect(await model.reconfigurationGate.holder == nil)
    #expect(await model.beginReset())
    await model.endReset()
  }

}
