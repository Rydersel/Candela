import CandelaKit
import CoreGraphics
import Foundation
import Testing

@Suite("Settings mode change feedback") @MainActor
struct ModeChangeFeedbackTests {
  @Test func repeatedListRequestsCannotReplaceTheChangeAlreadyStarting() async throws {
    let fixture = SynthesisFixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let first = try #require(fixture.modes.catalogs[SynthesisFixture.panelID])
    let second = try #require(fixture.modes.catalogs[SynthesisFixture.secondPanelID])
    let wanted = try #require(first.all.first { $0.ioModeID == 2 })
    let selection = ResolutionSelection(
      coordinator: fixture.modes, displayID: SynthesisFixture.panelID, surface: .settingsBanner
    )
    let current = try #require(first.current)
    selection.apply(current, in: first)
    expectIdle(fixture.modes)
    #expect(fixture.modes.preview == nil)
    selection.apply(wanted, in: first)
    #expect(fixture.modes.isApplying)
    // Same main-actor turn: a disabled view has not yet had a chance to redraw.
    fixture.modes.selectFromList(
      wanted, on: SynthesisFixture.secondPanelID, from: .settings,
      surface: .settingsBanner, currentModeID: second.alreadyOnScreenModeID
    )
    await fixture.settle()
    #expect(!fixture.modes.isApplying)
    #expect(fixture.modes.preview?.displayID == SynthesisFixture.panelID)
    await fixture.revertAnyPreview()
    selection.apply(wanted, in: first)
    await fixture.settle()
    if let preview = fixture.modes.preview {
      _ = await fixture.modes.confirm(preview)
    } else {
      Issue.record("A new choice must be accepted after the previous one reverts")
    }
    #expect(fixture.modes.preview == nil)
    expectIdle(fixture.modes)
  }

  @Test(arguments: [false, true])
  func ordinaryChangesStayBusyUntilSuccessOrFailure(fails: Bool) async throws {
    let fixture = SynthesisFixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let catalog = try #require(fixture.modes.catalogs[SynthesisFixture.panelID])
    let wanted = try #require(catalog.all.first { $0.ioModeID == 2 })
    let suspension = ModeApplySuspension()
    fixture.configurator.onModeApply = { suspension.block() }
    fixture.configurator.refusesModeApplies = fails
    expectIdle(fixture.modes)
    fixture.modes.selectFromList(
      wanted, on: SynthesisFixture.panelID, from: .settings,
      surface: .settingsBanner, currentModeID: catalog.alreadyOnScreenModeID
    )
    expectBusy(fixture.modes, rendered: false)
    let entered = await suspension.waitUntilEntered()
    #expect(entered)
    expectBusy(fixture.modes, rendered: false)
    suspension.resume()
    await fixture.settle()
    expectIdle(fixture.modes)
    if fails {
      #expect(fixture.modes.startFailure != nil)
      #expect(fixture.modes.preview == nil)
    } else {
      #expect(fixture.modes.preview?.mode == wanted)
      // Recovery is outside the selection gate and remains answerable.
      await fixture.revertAnyPreview()
      #expect(fixture.modes.preview == nil)
      expectIdle(fixture.modes)
    }
  }

  @Test func renderedChangeKeepsItsLongCaptionUntilTheEngineFinishes() async throws {
    let fixture = SynthesisFixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let stop = try #require(fixture.modes.catalogs[SynthesisFixture.panelID]?.syntheticStops.first)
    let suspension = ModeApplySuspension()
    fixture.host.onCreate = { suspension.block() }
    fixture.modes.select(
      SyntheticSizeCatalog.row(for: stop), on: SynthesisFixture.panelID,
      from: .settings, surface: .settingsBanner
    )
    expectBusy(fixture.modes, rendered: true)
    let entered = await suspension.waitUntilEntered()
    #expect(entered)
    expectBusy(fixture.modes, rendered: true)
    suspension.resume()
    await fixture.settle()
    expectIdle(fixture.modes)
    #expect(fixture.modes.preview?.synthesized?.size == stop)
    await fixture.revertAnyPreview()
    expectIdle(fixture.modes)
    #expect(fixture.modes.preview == nil)
    #expect(fixture.synthesis.pairings.isEmpty)
  }

  @Test func queuedOperationsKeepTheActiveCaptionAndNeverClearBusyBetweenChanges() async throws {
    let fixture = SynthesisFixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let stop = try #require(fixture.modes.catalogs[SynthesisFixture.panelID]?.syntheticStops.first)
    let second = try #require(fixture.modes.catalogs[SynthesisFixture.secondPanelID])
    let wanted = try #require(second.all.first { $0.ioModeID == 2 })
    let ordinary = ModeApplySuspension()
    let rendered = ModeApplySuspension()
    fixture.configurator.onModeApply = { ordinary.block() }
    fixture.host.onCreate = { rendered.block() }
    fixture.modes.select(wanted, on: SynthesisFixture.panelID,
                         from: .settings, surface: .settingsBanner)
    // Direct coordinator clients retain serial queue semantics.
    fixture.modes.select(
      SyntheticSizeCatalog.row(for: stop), on: SynthesisFixture.secondPanelID,
      from: .settings, surface: .settingsBanner
    )
    let firstEntered = await ordinary.waitUntilEntered()
    #expect(firstEntered)
    expectBusy(fixture.modes, rendered: false)
    ordinary.resume()
    let secondEntered = await rendered.waitUntilEntered()
    #expect(secondEntered)
    #expect(fixture.modes.isApplying)
    let feedback = ModeChangeFeedback(coordinator: fixture.modes, displayID: SynthesisFixture.panelID)
    #expect(feedback.controlsDisabled)
    #expect(feedback.caption?.contains("another display") == true)
    #expect(feedback.caption?.contains("tens of seconds") == true)
    rendered.resume()
    await fixture.settle()
    expectIdle(fixture.modes)
    #expect(fixture.modes.preview?.displayID == SynthesisFixture.secondPanelID)
    await fixture.revertAnyPreview()
  }

  @Test func cancellationQueuedDuringAnApplyClearsItsFeedbackAndPreview() async throws {
    let fixture = SynthesisFixture()
    defer { fixture.forgetPrefs() }
    let catalog = try #require(fixture.modes.catalogs[SynthesisFixture.panelID])
    let wanted = try #require(catalog.all.first { $0.ioModeID == 2 })
    let suspension = ModeApplySuspension()
    fixture.configurator.onModeApply = { suspension.block() }
    fixture.modes.select(wanted, on: SynthesisFixture.panelID,
                         from: .settings, surface: .settingsBanner)
    let entered = await suspension.waitUntilEntered()
    #expect(entered)
    let cancellation = Task { await fixture.modes.endOutstandingPreview() }
    suspension.resume()
    #expect(await cancellation.value)
    expectIdle(fixture.modes)
    #expect(fixture.modes.preview == nil)
  }

  private func expectIdle(_ coordinator: DisplayModeCoordinator) {
    #expect(!coordinator.isApplying)
    let feedback = ModeChangeFeedback(coordinator: coordinator, displayID: SynthesisFixture.panelID)
    #expect(!feedback.controlsDisabled)
    #expect(feedback.caption == nil)
  }

  private func expectBusy(_ coordinator: DisplayModeCoordinator, rendered: Bool) {
    #expect(coordinator.isApplying)
    let here = ModeChangeFeedback(coordinator: coordinator, displayID: SynthesisFixture.panelID)
    let elsewhere = ModeChangeFeedback(coordinator: coordinator, displayID: SynthesisFixture.secondPanelID)
    #expect(here.controlsDisabled)
    #expect(elsewhere.controlsDisabled)
    #expect(here.caption?.contains("this display") == true)
    #expect(elsewhere.caption?.contains("another display") == true)
    #expect(here.caption?.contains("tens of seconds") == rendered)
    #expect(elsewhere.caption?.contains("tens of seconds") == rendered)
  }
}

/// Only the synchronous hardware boundary blocks; the test awaits off the pool.
/// Immutable semaphores provide the cross-executor synchronization.
private final class ModeApplySuspension: Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let proceed = DispatchSemaphore(value: 0)

  func block() {
    entered.signal()
    if proceed.wait(timeout: .now() + 5) == .success {
      // Keep the gate open for later applies and recovery calls.
      proceed.signal()
    }
  }

  func resume() { proceed.signal() }

  func waitUntilEntered() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
      }
    }
  }
}
