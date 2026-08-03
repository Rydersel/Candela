import AppKit
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
/// the screen unreadable, so the safe outcome must be the one that happens when
/// nobody does anything). So it lives on `AppModel`, where the settings pane
/// and the panel drive ONE session and read ONE answer.
///
/// Two rules hold this together and neither is optional:
///
/// 1. **Every session-touching operation is serialised** through `pending`.
///    Without it, two clicks both suspend inside `begin()`, the actor
///    serialises them, and their main-actor continuations resume in an order
///    unrelated to the actor's — leaving the banner naming one mode while
///    "Keep" commits the other at session scope.
/// 2. **The UI's state is rebuilt FROM the session** (`adopt`), never from what
///    a caller remembers passing in. The two disagree exactly when something
///    went wrong, and the session is the one that decides what is applied.
@MainActor @Observable
final class DisplayModeCoordinator {
  /// Which surface asked for the preview that is outstanding.
  ///
  /// Not cosmetic, and not a preference: it decides where the answer can be
  /// offered. The settings pane's banner lives in an ordinary window that is
  /// still there fifteen seconds later. The panel is an `NSMenu` tracking
  /// session — it ends on Escape, on a click in the menu bar, and plausibly as
  /// a side effect of the very reconfiguration the preview performs. A
  /// panel-started preview therefore gets a surface that does not depend on the
  /// menu still being open, or the countdown would expire with the user having
  /// been shown nothing at all.
  enum PreviewOrigin: Sendable {
    case settings
    case panel
  }

  /// Everything one display's UI renders, computed once per enumeration.
  /// Enumerating costs several CoreGraphics round-trips, so it is done on
  /// demand and cached, never per body evaluation. A missing entry means "not
  /// enumerated yet" and is deliberately distinct from an entry with no modes.
  struct Catalog: Equatable {
    let display: ConfiguredDisplay
    let rows: [DisplayModeRow]
    let all: [DisplayMode]
    let current: DisplayMode?
    /// Denominator of the curation caption. Distinct LOGICAL SIZES, not modes:
    /// the curated list is one row per size, so counting modes would compare 11
    /// against 332 and read as though we were hiding 321 resolutions.
    let distinctLogicalSizes: Int
    /// False when no mode carries the native flag. `isScaled` is then
    /// undecidable and the badge is suppressed rather than guessed — comparing
    /// against a zero-sized panel would mark every mode as scaled.
    let nativeKnown: Bool
  }

  /// A preview that has been applied and not yet resolved. Every field is a
  /// copy of the session's own answer.
  struct Preview: Equatable {
    let displayID: CGDirectDisplayID
    let mode: DisplayMode
    var secondsRemaining: Int
    /// Set when `confirm()`, `revert()` or the expiry threw. The display did
    /// not move, the session still holds the fallback, and both buttons stay
    /// live — nothing auto-retries, so a silent failure would leave the user on
    /// a mode they never approved, held only until the app exits.
    var failure: DisplayConfigError?
    /// Reported by the session, not inferred: a failed expiry disarms the
    /// countdown while a failed commit deliberately leaves it armed.
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
  /// True from the click until the reconfiguration it started has settled.
  /// `begin()` spans a real CoreGraphics mode change, and a Keep pressed inside
  /// that window is queued behind it and would commit the NEW mode while the
  /// banner still named the old one — correct ordering, wrong intent. Set
  /// synchronously so the disable lands in the same body evaluation as the
  /// click that caused it.
  private(set) var isApplying = false

  let configurator: any DisplayConfiguring
  let persistence: ModePersistence

  /// Where a `.panel`-origin preview is answered. Wired at launch; nil means
  /// the app never installed one, which degrades to "no confirmation surface
  /// for panel selections" rather than to a crash.
  @ObservationIgnored weak var confirmation: (any ModeConfirmationPresenting)?

  /// Called after a commit actually wrote `storedDisplayMode`, so the
  /// propagation seam hears about it (D27) no matter which surface answered.
  /// Owned here because it used to be the answering view's job, and two views
  /// answering the same question is one too many — the second one to be written
  /// is the one that forgets.
  @ObservationIgnored var didStoreMode: (CGDirectDisplayID) -> Void = { _ in }

  @ObservationIgnored private let session: ModePreviewSession
  /// Per display, not one value for the coordinator. A settings-select on B
  /// whose `begin()` fails leaves A's preview outstanding and reports the error
  /// against A — with a single `origin` that select would have flipped the whole
  /// coordinator to `.settings` and torn down A's confirmation window while A
  /// was still counting down. Keyed, the surface follows the preview.
  @ObservationIgnored private var origins: [CGDirectDisplayID: PreviewOrigin] = [:]
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var inFlightSelects = 0
  /// Displays anything has asked about. `handleDisplaysChanged` re-enumerates
  /// these rather than only the currently cached ones, so a display that
  /// departs and returns under the same ID gets its catalog back — a nil
  /// catalog now renders as "not enumerated yet", i.e. as nothing at all, and
  /// `.task(id:)` does not re-fire for an unchanged id.
  @ObservationIgnored private var observed: Set<CGDirectDisplayID> = []
  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

  init(
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
    persistence: ModePersistence = ModePersistence()
  ) {
    self.configurator = configurator
    self.persistence = persistence
    session = ModePreviewSession(configurator: configurator)
    // Observed here rather than in a pane: a display can depart while its pane
    // is being dismissed for that very reason, and an outstanding preview on a
    // departed display has to be dropped whether or not anything is on screen.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.handleDisplaysChanged() }
    }
  }

  /// The notification token is deliberately not unregistered here: it is not
  /// `Sendable`, so a nonisolated `deinit` cannot touch it. Harmless — this
  /// object lives as long as the app, and the block holds `self` weakly, so a
  /// surviving registration is inert rather than dangling.
  deinit {
    countdown?.cancel()
    pending?.cancel()
  }

  // MARK: - Enumeration

  /// Re-enumerates one display. Called when a pane appears, when the screen
  /// configuration changes, and after any mode this app applies — never on a
  /// timer (DM7).
  func refreshCatalog(for displayID: CGDirectDisplayID) {
    observed.insert(displayID)
    guard let display = configurator.displays().first(where: { $0.id == displayID }) else {
      catalogs[displayID] = nil
      dropPreviewOnDepartedDisplay()
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

  /// Screen configuration changed: re-enumerate what is still here, forget what
  /// is not, and — the part that matters — end a preview on a display that has
  /// departed. Left alone, the expiry would apply the fallback to a dead
  /// display, fail, and leave the session holding an outstanding preview
  /// forever; `begin()` on ANY other display then reverts-first, fails, and
  /// refuses, so one unplug would wedge mode switching for the whole session.
  func handleDisplaysChanged() {
    let live = Set(configurator.displays().map(\.id))
    // Over `observed`, not over `catalogs`: a departed display's entry is nil,
    // so iterating the cache would never re-enumerate it when it comes back.
    for displayID in observed {
      if live.contains(displayID) {
        refreshCatalog(for: displayID)
      } else {
        catalogs[displayID] = nil
      }
    }
    dropPreviewOnDepartedDisplay()
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
      // Through `store(_:on:)`, not `persistence.store` directly: this is the
      // second place `storedDisplayMode` is written, and it announced nothing.
      // Its caller happened to fan out the same name by hand, which is exactly
      // the arrangement that broke the first time — the moment a second surface
      // offers this toggle, a stored mode is written with no propagation.
      store(current, on: displayID, for: identity)
    }
  }

  // MARK: - Preview

  /// Applies `mode` as a preview and starts the countdown.
  ///
  /// Only ever from an explicit choice naming THIS display: `begin()` on a
  /// display other than the one holding an outstanding preview performs a
  /// session-scope apply on that other display, so a speculative call would
  /// reconfigure a display the user never touched.
  ///
  /// Synchronous and fire-and-forget on purpose — the queue owns the ordering,
  /// so no caller can create a second in-flight `begin()` by spawning its own
  /// task.
  ///
  /// `origin` is not defaulted: every caller has to say where its answer will
  /// be offered, because getting it wrong is invisible until a countdown
  /// expires against nobody.
  func select(_ mode: DisplayMode, on displayID: CGDirectDisplayID, from origin: PreviewOrigin) {
    // Raised HERE, synchronously, not inside the queued operation: the whole
    // point is that the banner's buttons are already disabled by the time the
    // reconfiguration starts, so nobody can confirm a mode they are not
    // reading. Counted rather than boolean — two queued selects must not have
    // the first one's completion clear the flag for the second.
    inFlightSelects += 1
    isApplying = true
    enqueue {
      await self.performSelect(mode, on: displayID, from: origin)
      self.inFlightSelects -= 1
      if self.inFlightSelects == 0 { self.isApplying = false }
    }
  }

  /// `answered` is the preview the caller was LOOKING AT when it answered. It
  /// is carried into the session, which refuses an answer that no longer names
  /// the outstanding preview.
  ///
  /// This is what closes the last tail of the concurrency hazard. The button's
  /// action runs one main-actor turn before the queued operation, so a
  /// selection can still land in between — ordering alone cannot stop the
  /// answer from resolving a preview the user never saw. Carrying the intent
  /// makes "an answer only ever resolves the preview it was given for" a
  /// property of the type, and demotes queue ordering to an optimisation.
  @discardableResult
  func confirm(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.performResolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.performResolve(answered, keeping: false) }
  }

  func dismissStartFailure() {
    startFailure = nil
  }

  // MARK: - Serialisation

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = pending
    pending = Task { @MainActor in
      _ = await previous?.value
      await operation()
    }
  }

  private func enqueueReturning<T: Sendable>(
    _ operation: @escaping @MainActor () async -> T
  ) async -> T {
    let previous = pending
    let task = Task { @MainActor () -> T in
      _ = await previous?.value
      return await operation()
    }
    // The chain is Void-typed, so the next operation waits on this one through
    // an erased wrapper rather than on its result.
    pending = Task { @MainActor in _ = await task.value }
    return await task.value
  }

  // MARK: - Operations (always inside the queue)

  private func performSelect(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID, from origin: PreviewOrigin
  ) async {
    // Recorded here rather than in `select` so it names the preview that is
    // about to become outstanding, not whichever click was most recent: two
    // queued selects from different surfaces each get their own surface as they
    // land, in the order they land.
    origins[displayID] = origin
    startFailure = nil
    switch await session.begin(mode: mode, on: displayID) {
    case .success:
      await adopt(.clear)
      startCountdown()
    case let .failure(error):
      startFailure = StartFailure(displayID: displayID, error: error)
      // A begin() that fails may or may not have left something outstanding: it
      // refuses when the previous mode is unreadable (nothing applied), and it
      // also refuses when ending a preview on ANOTHER display failed — in which
      // case that display is still outstanding and this error is about IT.
      // Either way the session decides, and the error attaches only if there is
      // something for it to attach to.
      await adopt(.set(error))
    }
    refreshCatalog(for: displayID)
  }

  private func performResolve(_ answered: Preview, keeping: Bool) async -> ModePreviewOutcome {
    let intent = PreviewedMode(displayID: answered.displayID, mode: answered.mode)
    let outcome = keeping ? await session.confirm(intent) : await session.revert(intent)
    switch outcome {
    case .committed:
      // `.committed` is only reachable when the session agreed the answer named
      // its outstanding preview, so the mode that was committed is exactly the
      // one the user was reading — and therefore the one to store.
      storeIfRemembering(answered.mode, on: answered.displayID)
      await adopt(.clear)
    case .reverted:
      await adopt(.clear)
    case let .failed(error):
      await adopt(.set(error))
    case .stale:
      // Nothing was resolved: the outstanding preview is not the one this
      // answer was about. Re-read, and keep whatever failure is on screen —
      // it belongs to the preview that is still there, not to this answer.
      await adopt(.keep)
    }
    refreshCatalog(for: answered.displayID)
    return outcome
  }

  /// Ends an outstanding preview whose display has gone.
  ///
  /// Asks the SESSION which display is outstanding, and re-reads the live list
  /// inside the queue. Gating on `preview?.displayID` instead — the derived
  /// copy — leaves a hole: between `begin()` succeeding and `adopt()` finishing
  /// there are three awaits during which `preview` is still nil while the
  /// session is outstanding, so a departure landing in that window would be
  /// skipped, the countdown would expire onto a dead display, and the session
  /// would wedge. That is the exact case this exists to prevent, so it must not
  /// consult the copy.
  private func dropPreviewOnDepartedDisplay() {
    enqueue {
      guard let outstanding = await self.session.previewedMode else { return }
      let stillHere = self.configurator.displays().contains { $0.id == outstanding.displayID }
      guard !stillHere else { return }
      await self.session.discard(displayID: outstanding.displayID)
      await self.adopt(.clear)
    }
  }

  /// What to do with the failure currently on screen when re-reading the
  /// session.
  private enum FailureUpdate {
    case clear
    case keep
    case set(DisplayConfigError)
  }

  /// Rebuilds the UI's picture of the preview from the session. THE only writer
  /// of `preview`, so no path can leave the two disagreeing — including a
  /// countdown tick that resumes late, which reconciles here instead of being
  /// discarded. A discarded outcome is exactly how a preview with a disarmed
  /// countdown and no driver gets created.
  private func adopt(_ failure: FailureUpdate) async {
    guard let outstanding = await session.previewedMode else {
      preview = nil
      stopCountdown()
      syncConfirmation()
      return
    }
    let carried: DisplayConfigError? = switch failure {
    case .clear:
      nil
    case .keep:
      preview?.displayID == outstanding.displayID && preview?.mode == outstanding.mode
        ? preview?.failure : nil
    case let .set(error):
      error
    }
    let counting = await session.isCountingDown
    preview = Preview(
      displayID: outstanding.displayID,
      mode: outstanding.mode,
      secondsRemaining: await session.secondsRemaining,
      failure: carried,
      isCountingDown: counting
    )
    if !counting { stopCountdown() }
    syncConfirmation()
  }

  /// Show or hide the standalone confirmation surface to match what `adopt`
  /// just decided. Driven from `adopt` rather than by observing `preview`
  /// because `adopt` is the single writer, so the window can never be showing
  /// something the coordinator has already resolved.
  ///
  /// Called on every countdown tick, so the presenter must treat a repeat
  /// present for the same display as a no-op.
  private func syncConfirmation() {
    guard let preview, origins[preview.displayID] == .panel else {
      confirmation?.dismissConfirmation()
      return
    }
    confirmation?.presentConfirmation(on: preview.displayID)
  }

  /// The countdown driver.
  ///
  /// Detached, and its main-actor hop is fire-and-forget. Both halves matter:
  /// the tick and the revert it triggers run on the session's executor, and the
  /// loop's next `sleep`/`tick()` is never gated on the main actor having run
  /// the previous UI update. A main thread wedged by a synchronous
  /// reconfiguration callback or by blocking work in a pane must not be able to
  /// stop the expiry — the expiry is what rescues a screen nobody can read.
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
        // The countdown fires at most once; whatever it returned, it is spent.
        if outcome != nil { return }
      }
    }
  }

  private func stopCountdown() {
    countdown?.cancel()
    countdown = nil
  }

  private func storeIfRemembering(_ mode: DisplayMode, on displayID: CGDirectDisplayID) {
    guard let identity = identity(for: displayID), persistence.isEnabled(for: identity) else {
      return
    }
    store(mode, on: displayID, for: identity)
  }

  /// THE only writer of `storedDisplayMode`. Announcing the write is part of
  /// making it, so no caller can perform one and forget the propagation.
  private func store(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID, for identity: DisplayConfigIdentity
  ) {
    persistence.store(mode.descriptor, for: identity)
    didStoreMode(displayID)
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

/// A surface that can answer a preview on its own, independently of whichever
/// view started it. Declared beside the coordinator, and AppKit-free, so the
/// contract belongs to the thing that needs it — the window that implements it
/// is an app-target island like every other.
@MainActor
protocol ModeConfirmationPresenting: AnyObject {
  /// Must be idempotent: called again on every countdown tick.
  func presentConfirmation(on displayID: CGDirectDisplayID)
  func dismissConfirmation()
}

extension DisplayModeCoordinator.Catalog {
  /// The mode to apply for a curated row: the chosen SIZE at the refresh rate
  /// the display is already running, when that size offers it.
  ///
  /// A size change should not silently move someone from 60 Hz to 175 Hz, and
  /// the curated row carries the size's FASTEST rate as its representative, so
  /// taking the row's own mode would do exactly that.
  ///
  /// `ModePersistence.resolve` is the tested answer to this question (geometry
  /// + desired refresh → best live mode, deterministic down to `ioModeID`), so
  /// the rule is not re-invented in a view. Its cross-size fallbacks cannot
  /// help here — the row came from the live list — so a resolved mode at a
  /// different size is rejected in favour of the row's own representative.
  ///
  /// Lives here rather than in either view because the panel and the settings
  /// pane must apply the same rule; two copies would differ the first time one
  /// was touched.
  func modeKeepingCurrentRefreshRate(for row: DisplayModeRow) -> DisplayMode {
    let wanted = DisplayModeDescriptor(
      logicalWidth: row.mode.logicalWidth,
      logicalHeight: row.mode.logicalHeight,
      pixelWidth: row.mode.pixelWidth,
      pixelHeight: row.mode.pixelHeight,
      refreshHz: current?.refreshHz ?? row.mode.refreshHz
    )
    return mode(matching: wanted, atSizeOf: row.mode) ?? row.mode
  }

  /// Resolves `descriptor` against the live list, keeping the answer only when
  /// it is still the size the caller asked about.
  func mode(matching descriptor: DisplayModeDescriptor, atSizeOf size: DisplayMode) -> DisplayMode? {
    let match: DisplayMode? = switch ModePersistence.resolve(descriptor, in: all) {
    case let .exact(mode): mode
    case let .refreshRateDiffers(mode): mode
    case let .scaleDiffers(mode): mode
    case let .sizeDiffers(mode): mode
    case .none: nil
    }
    guard let match,
          match.logicalWidth == size.logicalWidth,
          match.logicalHeight == size.logicalHeight
    else { return nil }
    return match
  }

  /// True for the row whose LOGICAL SIZE the display is running. Comparing
  /// `ioModeID` instead would leave the checkmark off whenever the user is at a
  /// size's slower refresh rate: the curated row's representative mode is that
  /// size's FASTEST rate, so the IDs differ while the size is plainly selected.
  func isCurrentSize(_ mode: DisplayMode) -> Bool {
    guard let current else { return false }
    return current.logicalWidth == mode.logicalWidth && current.logicalHeight == mode.logicalHeight
  }
}
