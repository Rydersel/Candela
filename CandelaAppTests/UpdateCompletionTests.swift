import Foundation
import Observation
import Testing

@Suite("Update completion confirmation")
@MainActor
struct UpdateCompletionTests {
  let defaults = UserDefaults(suiteName: "update-completion-tests-\(UUID().uuidString)")!

  @Test func ordinaryLaunchDoesNotProduceAConfirmation() {
    let state = UpdateCompletionState()
    #expect(!state.consumeRelaunch(in: defaults, version: "1.0.3"))
    #expect(state.notice == nil)
  }

  @Test func anAbortedUpdateDoesNotCelebrateAnUnchangedVersion() {
    let state = UpdateCompletionState()
    UpdateRelaunch.mark(in: defaults, version: "1.0.3")
    #expect(state.consumeRelaunch(in: defaults, version: "1.0.3"))
    #expect(state.notice == nil)
    #expect(!state.consumeRelaunch(in: defaults, version: "1.0.4"))
    #expect(state.notice == nil)
  }

  @Test func legacyMarkersOpenAboutWithoutClaimingVerifiedSuccess() {
    let state = UpdateCompletionState()
    defaults.set(true, forKey: UpdateRelaunch.defaultsKey)
    #expect(state.consumeRelaunch(in: defaults, version: "1.0.3"))
    #expect(state.notice == nil)
  }

  @Test func aMarkedUpdatePublishesTheRunningVersionExactlyOnce() throws {
    let state = UpdateCompletionState()
    UpdateRelaunch.mark(in: defaults, version: "1.0.2")
    #expect(state.consumeRelaunch(in: defaults, version: "2.1.7"))
    let notice = try #require(state.notice)
    #expect(notice.version == "2.1.7")
    state.dismiss(notice.id)
    #expect(state.notice == nil)
    #expect(!state.consumeRelaunch(in: defaults, version: "2.1.7"))
    #expect(state.notice == nil)
    #expect(!UpdateCompletionState().consumeRelaunch(in: defaults, version: "2.1.7"))
  }

  @Test func aPreviousDismissalCannotRemoveANewerConfirmation() throws {
    let state = UpdateCompletionState()
    UpdateRelaunch.mark(in: defaults, version: "1.0.2")
    _ = state.consumeRelaunch(in: defaults, version: "1.0.3")
    let first = try #require(state.notice)
    UpdateRelaunch.mark(in: defaults, version: "1.0.2")
    _ = state.consumeRelaunch(in: defaults, version: "1.0.4")
    let second = try #require(state.notice)
    state.dismiss(first.id)
    #expect(state.notice == second)
  }

  @Test func timeoutDismissesTheConfirmation() async throws {
    let state = UpdateCompletionState()
    UpdateRelaunch.mark(in: defaults, version: "1.0.2")
    _ = state.consumeRelaunch(in: defaults, version: "1.0.3")
    let notice = try #require(state.notice)
    await state.dismissAfterDelay(notice.id, delay: .zero)
    #expect(state.notice == nil)
  }

  @Test func cancellingTheViewTaskDoesNotActLikeAnExpiredTimer() async throws {
    let state = UpdateCompletionState()
    UpdateRelaunch.mark(in: defaults, version: "1.0.2")
    _ = state.consumeRelaunch(in: defaults, version: "1.0.3")
    let notice = try #require(state.notice)
    let task = Task { await state.dismissAfterDelay(notice.id, delay: .seconds(60)) }
    task.cancel()
    await task.value
    #expect(state.notice == notice)
    state.dismiss(notice.id)
    #expect(state.notice == nil)
  }
}
