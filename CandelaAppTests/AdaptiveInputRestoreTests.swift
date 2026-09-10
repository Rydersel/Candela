import Foundation
import Testing

@Suite("Adaptive input restoration")
@MainActor
struct AdaptiveInputRestoreTests {
  @Test func aPointerMoveThenFocusChangeRestoresTheLatestStateInOneBatch() async {
    let gate = DelayGate()
    var frontmost = 1
    var restored: [Int] = []
    let input = AdaptiveInputRestore(delay: { await gate.wait() }, restore: {
      restored.append(frontmost)
    })
    let first = input.request() // pointer movement
    await gate.started()
    frontmost = 2
    let following = input.request() // included in the pending batch
    #expect(restored.isEmpty)
    gate.release()
    await first.value
    await following.value
    #expect(restored == [2])
    #expect(gate.calls == 1)
    let next = input.request()
    await gate.started()
    gate.release()
    await next.value
    #expect(restored == [2, 2])
  }

  @Test func cancellationPreventsALateRestoreAndAllowsAnotherBatch() async {
    let gate = DelayGate()
    var restores = 0
    let input = AdaptiveInputRestore(delay: { await gate.wait() }, restore: { restores += 1 })
    let cancelled = input.request()
    await gate.started()
    input.cancel()
    gate.release()
    await cancelled.value
    #expect(restores == 0)
    let next = input.request()
    await gate.started()
    gate.release()
    await next.value
    #expect(restores == 1)
  }
}

@MainActor
private final class DelayGate {
  var continuation: CheckedContinuation<Void, Never>?
  var calls = 0
  private var startWaiter: CheckedContinuation<Void, Never>?
  func wait() async {
    calls += 1
    await withCheckedContinuation {
      continuation = $0
      startWaiter?.resume()
      startWaiter = nil
    }
  }
  func started() async {
    guard continuation == nil else { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func release() {
    let held = continuation
    continuation = nil
    held?.resume()
  }
}
