import CandelaKit
import CoreGraphics
import Foundation

/// Owns pending capture slots and the validation between asynchronous capture
/// and exposure bookkeeping. ScreenCaptureKit stays behind the wave factory.
@MainActor
final class OledExposureCapture {
  struct Request: Equatable {
    let id = UUID()
    let key: String
    let target: OledTelemetryTarget
    let transform: PanelSpaceTransform
    let epoch: Int
  }

  /// Re-read after capture, never carried over from the tick that queued it.
  struct Context {
    var epoch: Int
    var displayID: CGDirectDisplayID
    var target: OledTelemetryTarget
    var transform: PanelSpaceTransform?
    var telemetryEnabled: Bool
    var dimState: OledDimState
    var isResetting: Bool
    var isLocked: Bool
    var panelIsAwake: Bool
    var isLowBattery: Bool

    func accepts(_ request: Request) -> Bool {
      epoch == request.epoch && displayID == request.target.panel
        && target == request.target && transform == request.transform
        && telemetryEnabled && !isResetting && !isLocked && panelIsAwake && !isLowBattery
        && target.samplingMayRun(dimState: dimState)
    }
  }

  private let prepare: @MainActor () async -> LuminanceSampler.Wave?
  private var pending: [String: UUID] = [:]

  init(prepare: @escaping @MainActor () async -> LuminanceSampler.Wave?) {
    self.prepare = prepare
  }

  func reserve(
    key: String, target: OledTelemetryTarget, transform: PanelSpaceTransform, epoch: Int
  ) -> Request? {
    guard pending[key] == nil else { return nil }
    let request = Request(key: key, target: target, transform: transform, epoch: epoch)
    pending[key] = request.id
    return request
  }

  func invalidate(key: String) { pending.removeValue(forKey: key) }
  func invalidateAll() { pending.removeAll() }

  func run(
    _ requests: [Request], current: @escaping @MainActor (Request) -> Context?,
    accept: @escaping @MainActor (Request, LuminanceSampler.Sample) -> Void
  ) async {
    let requests = requests.filter { pending[$0.key] == $0.id }
    guard !requests.isEmpty else { return }
    guard let wave = await prepare() else {
      for request in requests { finish(nil, request: request, current: current, accept: accept) }
      return
    }
    // Launch every capture before waiting for any of them. The snapshot stays
    // on MainActor, but one compositor reply must not hold up another panel.
    // Each completion books independently, even if an earlier task stays out.
    let completions = requests.compactMap { request -> Task<Void, Never>? in
      guard pending[request.key] == request.id else { return nil }
      let capture = wave.start(request.target.surface)
      return Task { @MainActor [weak self] in
        let sample = await capture.value
        self?.finish(sample, request: request, current: current, accept: accept)
      }
    }
    for completion in completions { await completion.value }
  }

  private func finish(
    _ sample: LuminanceSampler.Sample?, request: Request,
    current: @MainActor (Request) -> Context?,
    accept: @MainActor (Request, LuminanceSampler.Sample) -> Void
  ) {
    // A departure, opt-out or reset can replace this key's reservation while
    // the old screenshot is still out. It owns neither the new slot nor its data.
    guard pending[request.key] == request.id else { return }
    pending.removeValue(forKey: request.key)
    guard let sample, let context = current(request), context.accepts(request) else { return }
    accept(request, sample)
  }
}
