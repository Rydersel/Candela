import CandelaKit
import CoreGraphics
import Foundation
import AppKit
import Observation
import OSLog
import SwiftUI

/// Display rotation: the request, the countdown, and the one surface that
/// reports on either.
///
/// Owned by `AppModel` rather than by a view, for `DisplayModeCoordinator`'s
/// reason — the countdown has to outlive whatever window started it.
///
/// **The apply is blocking and must not run on the main actor (RS10).**
/// `SLSSetDisplayRotation` does not return until the rotation has taken effect;
/// measured at 0.4–1.1 seconds. Every call into the session therefore crosses
/// onto the session actor, and the session's own executor is where the blocking
/// happens.
@MainActor
@Observable
final class RotationCoordinator {
  /// The applied-but-unanswered rotation, as the UI renders it.
  struct Preview: Equatable {
    let request: RotationRequest
    let secondsRemaining: Int
    let failure: DisplayConfigError?
    let isCountingDown: Bool
  }

  private(set) var preview: Preview?
  /// Why the last request was not attempted. Cleared by `dismissReport`.
  private(set) var lastRefusal: RotationRefusal?
  /// A rotation or a revert that the hardware refused, or that reported success
  /// and did not happen (RT8).
  private(set) var lastFailure: DisplayConfigError?
  private(set) var isApplying = false

  @ObservationIgnored weak var confirmation: (any RotationConfirmationPresenting)?
  /// Friendly-name resolution belongs to the surfaces. Empty by default so an
  /// unwired coordinator looks unfinished in testing rather than plausibly right.
  @ObservationIgnored var displayName: (CGDirectDisplayID) -> String = { _ in "" }

  @ObservationIgnored private let configurator: any DisplayConfiguring
  @ObservationIgnored private let session: RotationPreviewSession
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var inFlight = 0
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "rotation"
  )

  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  #if DEBUG
    @ObservationIgnored private var debugObserver: (any NSObjectProtocol)?
  #endif

  init(
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
    timeoutSeconds: Int = 30
  ) {
    self.configurator = configurator
    session = RotationPreviewSession(configurator: configurator, timeoutSeconds: timeoutSeconds)
    // A rotation fires this notification itself, so this is not only about
    // departures — it is also what re-reads the angle a picker is showing.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.displaysChanged() }
    }

    #if DEBUG
      // Screenshot validation only, and permanent for the reason its two
      // siblings in `MirroringCoordinator` are: the confirmation window cannot
      // be reached from a script. Driving the Settings picker needs an
      // Accessibility grant this machine does not have — measured 2026-08-04,
      // synthetic scroll events to the settings window were silently dropped —
      // and there is no rotation hotkey by design (RT1).
      //
      // It posts the REAL request through the real policy, so the countdown and
      // its revert are the shipping ones. Never the built-in: a rotated laptop
      // panel whose revert fails is the worst outcome available here.
      debugObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.rydersel.Candela.debug.showRotationPreview"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self,
                let external = self.configurator.displays().first(where: { !$0.isBuiltIn })
          else { return }
          let current = self.configurator.rotation(of: external.id) ?? .standard
          self.rotate(external.id, to: current == .standard ? .ninety : .standard)
        }
      }
    #endif
  }

  /// RT5. False hides every rotation control rather than offering one that
  /// cannot work.
  var canRotate: Bool { configurator.canRotate }

  func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? {
    configurator.rotation(of: displayID)
  }

  /// What a picker should show for this display: its live angle, or — while a
  /// preview is outstanding on it — the previewed one, so the control does not
  /// snap back under the question being asked about it.
  func displayedRotation(of displayID: CGDirectDisplayID) -> DisplayRotation? {
    if let preview, preview.request.display == displayID { return preview.request.to }
    return rotation(of: displayID)
  }

  // MARK: - Requesting

  func rotate(_ displayID: CGDirectDisplayID, to requested: DisplayRotation) {
    let decision = RotationPolicy.decide(
      display: displayID,
      to: requested,
      in: configurator.displays(),
      currentRotation: configurator.rotation(of: displayID),
      isSupported: configurator.canRotate
    )
    switch decision {
    case let .refused(refusal):
      // A refusal changed nothing on screen, so silence is indistinguishable
      // from the feature not working — except for `unchanged`, which is the one
      // refusal the user cannot tell from success because the display is
      // ALREADY where they asked for it. Reporting that would be a dialog
      // saying "no" to someone who got what they wanted.
      if case .unchanged = refusal {
        log.debug("rotation request is a no-op for display \(displayID)")
        return
      }
      lastRefusal = refusal
      syncConfirmation()
    case let .rotate(request):
      enqueue { await self.begin(request) }
    }
  }

  private func begin(_ request: RotationRequest) async {
    lastRefusal = nil
    lastFailure = nil
    let result = await session.begin(request)
    switch result {
    case .success:
      await adopt(.clear)
      startCountdown()
    case let .failure(error):
      // Nothing is outstanding — `begin` leaves no request when it fails — so
      // this is a report, not a preview.
      lastFailure = error
      await adopt(.clear)
    }
  }

  @discardableResult
  func confirm(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.resolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.resolve(answered, keeping: false) }
  }

  func dismissReport() {
    lastRefusal = nil
    lastFailure = nil
    syncConfirmation()
  }

  /// The display carrying an unanswered rotation went away. Nothing can be
  /// rotated back, so the request is discarded rather than left waiting for an
  /// answer about hardware that is gone.
  func displaysChanged() {
    let present = Set(configurator.displays().map(\.id))
    guard let preview, !present.contains(preview.request.display) else { return }
    enqueue {
      await self.session.discardOnDeparture()
      await self.adopt(.clear)
    }
  }

  // MARK: - Serialisation

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = pending
    inFlight += 1
    isApplying = true
    pending = Task { @MainActor in
      _ = await previous?.value
      await operation()
      inFlight -= 1
      if inFlight == 0 { isApplying = false }
    }
  }

  private func enqueueReturning<T: Sendable>(
    _ operation: @escaping @MainActor () async -> T
  ) async -> T {
    let previous = pending
    inFlight += 1
    isApplying = true
    let task = Task { @MainActor in
      _ = await previous?.value
      let value = await operation()
      inFlight -= 1
      if inFlight == 0 { isApplying = false }
      return value
    }
    pending = Task { @MainActor in _ = await task.value }
    return await task.value
  }

  private func resolve(_ answered: Preview, keeping: Bool) async -> ModePreviewOutcome {
    let outcome = keeping
      ? await session.confirm(answered.request)
      : await session.revert(answered.request)
    switch outcome {
    case .committed, .reverted: await adopt(.clear)
    case let .failed(error): await adopt(.set(error))
    // The answer was about a preview that is no longer outstanding, so it
    // resolved nothing. Keep whatever is on screen — it belongs to the preview
    // that is still there.
    case .stale: await adopt(.keep)
    }
    return outcome
  }

  private enum FailureUpdate { case clear, keep, set(DisplayConfigError) }

  /// Rebuilds the UI's picture FROM the session, and is the only writer of
  /// `preview` — so no path can leave the two disagreeing, including a countdown
  /// tick that resumes late.
  private func adopt(_ failure: FailureUpdate) async {
    guard let outstanding = await session.previewed else {
      preview = nil
      stopCountdown()
      syncConfirmation()
      return
    }
    let carried: DisplayConfigError? = switch failure {
    case .clear: nil
    case .keep: preview?.request == outstanding ? preview?.failure : nil
    case let .set(error): error
    }
    let counting = await session.isCountingDown
    preview = Preview(
      request: outstanding,
      secondsRemaining: await session.secondsRemaining,
      failure: carried,
      isCountingDown: counting
    )
    if !counting { stopCountdown() }
    syncConfirmation()
  }

  /// Every write to `preview`, `lastRefusal` or `lastFailure` must be followed
  /// by this. An un-synced write leaves the window rendering a state that no
  /// longer exists — an empty floating panel.
  private func syncConfirmation() {
    if let preview {
      confirmation?.presentRotationConfirmation(.preview(preview.request.display))
      return
    }
    if lastFailure != nil || lastRefusal != nil {
      confirmation?.presentRotationConfirmation(.report)
      return
    }
    confirmation?.dismissRotationConfirmation()
  }

  /// Detached, with a fire-and-forget hop to the main actor, for
  /// `MirroringCoordinator.startCountdown`'s reason: a main thread wedged by a
  /// synchronous reconfiguration callback must not be able to stop the expiry.
  /// The expiry is what rescues a display nobody meant to rotate.
  private func startCountdown() {
    countdown?.cancel()
    let session = session
    countdown = Task.detached { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        let outcome = await session.tick()
        Task { @MainActor [weak self] in
          guard let self else { return }
          if case let .failed(error) = outcome {
            enqueue { await self.adopt(.set(error)) }
          } else {
            enqueue { await self.adopt(.keep) }
          }
        }
        if outcome != nil { return }
      }
    }
  }

  private func stopCountdown() {
    countdown?.cancel()
    countdown = nil
  }
}

/// The surface that reports on a rotation independently of whichever view
/// started it. Declared beside the coordinator and AppKit-free.
@MainActor
protocol RotationConfirmationPresenting: AnyObject {
  /// Must be idempotent for unchanged content: called again on every tick.
  func presentRotationConfirmation(_ content: RotationConfirmationContent)
  func dismissRotationConfirmation()
}

enum RotationConfirmationContent: Hashable {
  /// A rotation applied and waiting to be answered, on the display it rotated.
  case preview(CGDirectDisplayID)
  /// A refusal or a failed apply. Nothing is outstanding; one button.
  case report
}
