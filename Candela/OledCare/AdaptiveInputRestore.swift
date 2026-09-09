import Foundation

/// Coalesces a burst of input while retaining the latest focus/pointer state.
@MainActor
final class AdaptiveInputRestore {
  private let delay: @MainActor () async throws -> Void
  private let restore: @MainActor () -> Void
  private var pending: Task<Void, Never>?

  init(delay: @escaping @MainActor () async throws -> Void = {
    try await Task.sleep(for: .milliseconds(100))
  }, restore: @escaping @MainActor () -> Void) {
    self.delay = delay
    self.restore = restore
  }

  /// Requests within one burst share a completion handle.
  @discardableResult
  func request() -> Task<Void, Never> {
    if let pending { return pending }
    let batch = Task { @MainActor [weak self] in
      guard let delay = self?.delay else { return }
      do { try await delay() } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.pending = nil
      self.restore()
    }
    pending = batch
    return batch
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }

  deinit { pending?.cancel() }
}
