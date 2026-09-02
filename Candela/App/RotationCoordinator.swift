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
/// Owned by `AppModel` rather than by a view: the countdown has to outlive
/// whatever window started it.
///
/// **The apply is blocking and must not run on the main actor.**
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
  /// and did not happen.
  private(set) var lastFailure: DisplayConfigError?
  /// The gate refused this request, and names who holds it. Not a
  /// `RotationRefusal` case: that enum answers about the DISPLAY, and this is no
  /// fact about the display.
  private(set) var blockedBy: ReconfigurationClaimant?
  private(set) var isApplying = false

  @ObservationIgnored weak var confirmation: (any RotationConfirmationPresenting)?

  @ObservationIgnored private let configurator: any DisplayConfiguring
  /// The reconfiguration gate. Held from just before the rotation applies until nothing is
  /// outstanding. Not defaulted: a per-coordinator default would compile, run,
  /// and exclude nobody.
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  @ObservationIgnored private let session: RotationPreviewSession
  @ObservationIgnored private let queue = PreviewQueue()
  @ObservationIgnored private let countdown = PreviewCountdownDriver()
  @ObservationIgnored private var inFlight = 0
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "rotation"
  )

  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  #if DEBUG
    @ObservationIgnored private var debugObserver: (any NSObjectProtocol)?
  #endif

  init(
    gate: DisplayReconfigurationGate,
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
    timeoutSeconds: Int = 30
  ) {
    self.gate = gate
    self.configurator = configurator
    session = RotationPreviewSession(configurator: configurator, timeoutSeconds: timeoutSeconds)
    // A rotation fires this notification itself, so besides departures this is
    // what re-reads the angle a picker is showing.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.displaysChanged() }
    }

    #if DEBUG
      // Screenshot validation only: the confirmation window cannot be reached
      // from a script. Driving the Settings picker needs an Accessibility grant
      // this machine lacks (synthetic scroll events to the settings window are
      // silently dropped), and there is no rotation hotkey by design.
      //
      // Posts the REAL request through the real policy, so the countdown and its
      // revert are the shipping ones. Never the built-in: a rotated laptop panel
      // whose revert fails is the worst outcome available here.
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

  /// False hides every rotation control rather than offering one that
  /// cannot work.
  var canRotate: Bool { configurator.canRotate }

  func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? {
    configurator.rotation(of: displayID)
  }

  /// What a picker should show: the live angle, or the previewed one while a
  /// preview is outstanding, so the control does not snap back under the
  /// question being asked about it.
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
      // A refusal changed nothing on screen, so silence looks like the feature
      // not working. `unchanged` is the exception: the display is ALREADY where
      // they asked for it, so a dialog would say "no" to someone who got what
      // they wanted.
      if case .unchanged = refusal {
        log.debug("rotation request is a no-op for display \(displayID)")
        return
      }
      lastRefusal = refusal
      syncConfirmation()
    case let .rotate(request):
      // Raised HERE, synchronously, not inside the queue. A control that queues
      // main-actor work and only then disables itself is a control two clicks get
      // through, and `enqueue` also carries the countdown's per-second `adopt`
      // and the departure discard, so raising the flag inside it greyed Keep and
      // Revert once a second for the whole preview. Counted, not boolean, so the
      // first of two queued rotations cannot clear the flag for the second.
      inFlight += 1
      isApplying = true
      queue.enqueue {
        await self.begin(request)
        self.inFlight -= 1
        if self.inFlight == 0 { self.isApplying = false }
      }
    }
  }

  private func begin(_ request: RotationRequest) async {
    // Through the syncing funnel, not bare assignments: the `gate.claim` below
    // suspends, and a window still rendering a just-cleared report is the
    // empty-floating-panel defect `syncConfirmation` documents.
    dismissReport()
    // The reconfiguration gate, asked BEFORE the apply: `SLSSetDisplayRotation` blocks for 0.4–1.1
    // seconds and does not come back until the panel has moved, so a refusal
    // after it would be a refusal of something that already happened.
    if let holder = await gate.claim(.rotation).refusedBy {
      blockedBy = holder
      log.info("Refused a rotation: \(holder.rawValue, privacy: .public) is reconfiguring displays")
      syncConfirmation()
      return
    }
    let result = await session.begin(request)
    switch result {
    case .success:
      await adopt(.clear)
      startCountdown()
    case let .failure(error):
      // Nothing is outstanding, since `begin` leaves no request when it fails,
      // so this is a report rather than a preview.
      lastFailure = error
      await adopt(.clear)
    }
  }

  @discardableResult
  func confirm(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.resolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.resolve(answered, keeping: false) }
  }

  func dismissReport() {
    lastRefusal = nil
    lastFailure = nil
    blockedBy = nil
    syncConfirmation()
  }

  /// The display carrying an unanswered rotation went away. Nothing can be
  /// rotated back, so the request is discarded rather than left waiting.
  func displaysChanged() {
    let present = Set(configurator.displays().map(\.id))
    guard let preview, !present.contains(preview.request.display) else { return }
    queue.enqueue {
      await self.session.discardOnDeparture()
      await self.adopt(.clear)
    }
  }

  // MARK: - Serialisation

  private func resolve(_ answered: Preview, keeping: Bool) async -> PreviewOutcome {
    let outcome = keeping
      ? await session.confirm(answered.request)
      : await session.revert(answered.request)
    switch outcome {
    case .committed, .reverted: await adopt(.clear)
    case let .failed(error): await adopt(.set(error))
    // The answer was about a preview that is no longer outstanding, so it
    // resolved nothing. Keep what is on screen: it belongs to the one still
    // there.
    case .stale: await adopt(.keep)
    }
    return outcome
  }

  /// Rebuilds the UI's picture FROM the session. THE only writer of `preview`,
  /// so no path can leave the two disagreeing, a late countdown tick included.
  private func adopt(_ failure: FailureUpdate) async {
    guard let outstanding = await session.previewed else {
      preview = nil
      stopCountdown()
      // THE release (the reconfiguration gate), here rather than at each call site: this funnel
      // already runs after every path that can end a rotation preview.
      // Unconditional, since the gate refuses a release from a non-holder.
      await gate.release(.rotation)
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

  /// Every write to `preview` or the report properties must be followed by this.
  /// An un-synced write leaves the window rendering a state that no longer
  /// exists, which shows up as an empty floating panel.
  private func syncConfirmation() {
    if let preview {
      confirmation?.presentRotationConfirmation(.preview(preview.request.display))
      return
    }
    if lastFailure != nil || lastRefusal != nil || blockedBy != nil {
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
    let session = session
    countdown.start(tick: { await session.tick() }) { [weak self] outcome in
      guard let self else { return }
      // Through the queue, never straight to `adopt`: a tick that landed
      // mid-apply would otherwise publish a picture the apply is about to
      // replace.
      if case let .failed(error) = outcome {
        queue.enqueue { await self.adopt(.set(error)) }
      } else {
        queue.enqueue { await self.adopt(.keep) }
      }
    }
  }

  private func stopCountdown() {
    countdown.stop()
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
