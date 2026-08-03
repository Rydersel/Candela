import CandelaKit
import CoreGraphics
import Foundation
import Observation

/// App-side owner of display-mode enumeration, the preview countdown, and
/// stored-mode writes.
///
/// The plan handed Task 8 a section view with `onSelect` closures and never
/// named an owner for `ModePreviewSession`. A view cannot be that owner: the
/// countdown has to keep running after the view that started it goes away —
/// that is the entire safety argument for previewing at all (a mode can leave
/// the screen unreadable, and the safe outcome must be the one that happens
/// when nobody does anything). So it lives on `AppModel`, where the settings
/// pane and the panel drive ONE session and read ONE answer.
///
/// The countdown driver is a plain `Task` loop, deliberately: `tick()` is a
/// logical clock, and a driver tied to a window, a `.task` modifier or a modal
/// run loop stops exactly when the screen is unreadable and the user cannot
/// dismiss anything — which is the moment the expiry exists for.
@MainActor @Observable
final class DisplayModeCoordinator {
  /// Everything one display's UI renders, computed once per enumeration.
  /// Enumerating costs several CoreGraphics round-trips per call, so it is done
  /// on demand and cached, never per body evaluation.
  struct Catalog: Equatable {
    let display: ConfiguredDisplay
    let rows: [DisplayModeRow]
    let all: [DisplayMode]
    let current: DisplayMode?
    /// Denominator of the section header. Distinct LOGICAL SIZES, not modes:
    /// the curated list is one row per size, so counting modes would compare 11
    /// against 332 and read as though we were hiding 321 resolutions.
    let distinctLogicalSizes: Int
    /// False when no mode carries the native flag. `isScaled` is then
    /// undecidable and the badge is suppressed rather than guessed — comparing
    /// against a zero-sized panel would mark every mode as scaled.
    let nativeKnown: Bool
  }

  /// A preview that has been applied and not yet resolved.
  struct Preview: Equatable {
    let displayID: CGDirectDisplayID
    let mode: DisplayMode
    var secondsRemaining: Int
    /// Set when `confirm()`, `revert()` or the expiry threw. The display did
    /// not move, the session still holds the fallback, and both buttons stay
    /// live — nothing auto-retries, so a silent failure would leave the user on
    /// a mode they never approved, held only until the app exits.
    var failure: DisplayConfigError?
    /// Whether the session's countdown can still expire into a revert. A failed
    /// expiry disarms it (the engine fires it once); a failed COMMIT leaves it
    /// armed on purpose.
    var isCountingDown: Bool
  }

  /// A `begin()` that never took effect. Separate from `Preview.failure`
  /// because nothing is outstanding: there is nothing to keep or revert, only
  /// something to report. Carries the display so one display's failure is not
  /// reported on another display's page.
  struct StartFailure: Equatable {
    let displayID: CGDirectDisplayID
    let error: DisplayConfigError
  }

  private(set) var catalogs: [CGDirectDisplayID: Catalog] = [:]
  private(set) var preview: Preview?
  private(set) var startFailure: StartFailure?

  let configurator: any DisplayConfiguring
  let persistence: ModePersistence

  @ObservationIgnored private let session: ModePreviewSession
  @ObservationIgnored private var countdown: Task<Void, Never>?
  /// Which preview a countdown tick belongs to. Cancelling the driver is not
  /// enough on its own: a tick already suspended inside the session resumes
  /// after the next `begin()`, and without this check its (stale) outcome would
  /// clear the NEW preview from the UI while the session still holds it —
  /// leaving an armed countdown with nothing driving it, which is the one state
  /// that disables the expiry entirely.
  @ObservationIgnored private var previewGeneration: UInt64 = 0

  init(
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
    persistence: ModePersistence = ModePersistence()
  ) {
    self.configurator = configurator
    self.persistence = persistence
    session = ModePreviewSession(configurator: configurator)
  }

  deinit {
    countdown?.cancel()
  }

  // MARK: - Enumeration

  /// Re-enumerates one display. Called when a pane appears, when the screen
  /// configuration changes, and after any mode this app applies — never on a
  /// timer (DM7).
  func refreshCatalog(for displayID: CGDirectDisplayID) {
    guard let display = configurator.displays().first(where: { $0.id == displayID }) else {
      catalogs[displayID] = nil
      return
    }
    let all = DisplayModeCatalog.full(configurator.modes(for: displayID))
    let native = configurator.nativePixels(for: displayID)
    catalogs[displayID] = Catalog(
      display: display,
      rows: DisplayModeCatalog.curated(
        all,
        nativePixelWidth: native?.width ?? 0,
        nativePixelHeight: native?.height ?? 0
      ),
      all: all,
      current: configurator.currentMode(for: displayID),
      distinctLogicalSizes: Set(all.map { LogicalSize(mode: $0) }).count,
      nativeKnown: native != nil
    )
  }

  func isRemembering(_ displayID: CGDirectDisplayID) -> Bool {
    guard let identity = identity(for: displayID) else { return false }
    return persistence.isEnabled(for: identity)
  }

  /// Turning it ON also stores what is on screen now. Without that, the toggle
  /// does nothing until the next resolution change — a control that reads as
  /// broken on the very reconnect it was turned on for. Turning it OFF leaves
  /// the stored mode alone, matching `ModePersistence.clear`'s ruling that
  /// "forget my choice" and "stop remembering" are separate answers.
  func setRemembering(_ remembering: Bool, for displayID: CGDirectDisplayID) {
    guard let identity = identity(for: displayID) else { return }
    persistence.setEnabled(remembering, for: identity)
    guard remembering else { return }
    if let current = catalogs[displayID]?.current ?? configurator.currentMode(for: displayID) {
      persistence.store(current.descriptor, for: identity)
    }
  }

  // MARK: - Preview

  /// Applies `mode` as a preview and starts the countdown.
  ///
  /// Only ever from an explicit choice naming THIS display: `begin()` on a
  /// display other than the one holding an outstanding preview performs a
  /// session-scope apply on that other display, so a speculative call would
  /// reconfigure a display the user never touched.
  func select(_ mode: DisplayMode, on displayID: CGDirectDisplayID) async {
    startFailure = nil
    switch await session.begin(mode: mode, on: displayID) {
    case .success:
      preview = Preview(
        displayID: displayID,
        mode: mode,
        secondsRemaining: await session.secondsRemaining,
        failure: nil,
        isCountingDown: true
      )
      refreshCatalog(for: displayID)
      previewGeneration &+= 1
      startCountdown(generation: previewGeneration)
    case let .failure(error):
      startFailure = StartFailure(displayID: displayID, error: error)
      // A begin() that fails may or may not have left something outstanding:
      // it refuses when the previous mode is unreadable (nothing applied), and
      // it also refuses when ending a preview on ANOTHER display failed (that
      // display still outstanding). Ask the session rather than assume.
      await syncWithSession(failure: error)
    }
  }

  @discardableResult
  func confirm() async -> ModePreviewOutcome {
    guard preview != nil else { return .reverted }
    let outcome = await session.confirm()
    apply(outcome)
    return outcome
  }

  @discardableResult
  func revert() async -> ModePreviewOutcome {
    guard preview != nil else { return .reverted }
    let outcome = await session.revert()
    apply(outcome)
    return outcome
  }

  func dismissStartFailure() {
    startFailure = nil
  }

  // MARK: - Private

  private func apply(_ outcome: ModePreviewOutcome) {
    guard let outstanding = preview else { return }
    switch outcome {
    case .committed:
      // The mode is permanent now, so this is the moment the remembered
      // descriptor is worth writing — and the previewed mode is the right one
      // to write, not whatever the display reports afterwards.
      if let identity = identity(for: outstanding.displayID),
         persistence.isEnabled(for: identity) {
        persistence.store(outstanding.mode.descriptor, for: identity)
      }
      preview = nil
      stopCountdown()
    case .reverted:
      preview = nil
      stopCountdown()
    case let .failed(error):
      // Nothing moved, so the preview is still outstanding and still needs an
      // answer. The countdown is NOT touched here: a failed commit leaves it
      // armed by design (falling back to the mode the user can definitely see
      // is the safe way to end that), and a failed expiry already disarmed it
      // inside the session.
      preview?.failure = error
    }
    refreshCatalog(for: outstanding.displayID)
  }

  /// Detached on purpose. The expiry is the safety mechanism, so it must not
  /// depend on the main thread being able to run work: the tick and the revert
  /// it triggers happen on the session's own executor, and only the state the
  /// UI renders is handed back to the main actor afterwards.
  private func startCountdown(generation: UInt64) {
    countdown?.cancel()
    let session = session
    countdown = Task.detached { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        let outcome = await session.tick()
        let remaining = await session.secondsRemaining
        await MainActor.run { [weak self] in
          self?.applyTick(outcome: outcome, secondsRemaining: remaining, generation: generation)
        }
        // The countdown fires at most once; whatever it returned, it is spent.
        if outcome != nil { return }
      }
    }
  }

  private func stopCountdown() {
    countdown?.cancel()
    countdown = nil
  }

  private func applyTick(
    outcome: ModePreviewOutcome?, secondsRemaining: Int, generation: UInt64
  ) {
    guard generation == previewGeneration, preview != nil else { return }
    guard let outcome else {
      preview?.secondsRemaining = secondsRemaining
      return
    }
    preview?.isCountingDown = false
    preview?.secondsRemaining = 0
    stopCountdown()
    apply(outcome)
  }

  /// Re-reads the session after a call whose effect on the outstanding preview
  /// is not determined by its return value.
  private func syncWithSession(failure: DisplayConfigError?) async {
    if await session.hasOutstandingPreview {
      preview?.failure = failure
    } else {
      preview = nil
      stopCountdown()
    }
  }

  private func identity(for displayID: CGDirectDisplayID) -> DisplayConfigIdentity? {
    catalogs[displayID]?.display.identity
      ?? configurator.displays().first { $0.id == displayID }?.identity
  }

  private struct LogicalSize: Hashable {
    let width: Int
    let height: Int

    init(mode: DisplayMode) {
      width = mode.logicalWidth
      height = mode.logicalHeight
    }
  }
}
