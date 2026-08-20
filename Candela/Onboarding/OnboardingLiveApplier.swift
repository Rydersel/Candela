import CandelaKit
import CoreGraphics
import Observation

/// Implements the flow model's apply seam over the shipped mode-apply path.
///
/// The shape is fixed by two shipped facts. First, an apply must ride the one
/// path every resolution control uses (`ResolutionSelection` into
/// `DisplayModeCoordinator.selectFromList`), so the real keep and revert
/// countdown guards it (PD9: expiry reverts, never silently keeps). Second,
/// the shipped countdown's answering surface is fixed at preview start and
/// renders in the settings window, never here, so the Setup window renders its
/// OWN Keep and Revert from the coordinator's observable preview state and
/// answers with `confirm`/`revert` directly, carrying the exact preview it
/// rendered: an answer can only resolve what the user was looking at.
///
/// This object reports into the model (`applyCountdownTicked`, `applyKept`,
/// `applyReverted`, `applyFailed`) and owns no meaning of its own; the model
/// decides what each report does to the flow.
@MainActor
final class OnboardingLiveApplier {
  private let model: AppModel
  /// Weak both ways is deliberate: the flow's seam closures capture this
  /// object weakly, and the window controller owns both.
  private weak var flow: OnboardingFlowModel?

  /// The display whose apply is outstanding, nil when nothing is.
  private var pendingDisplayID: CGDirectDisplayID?
  /// The latest coordinator preview observed for the pending display. This is
  /// the preview the page's countdown is rendering, and therefore the only
  /// one an answer may name.
  private var renderedPreview: DisplayModeCoordinator.Preview?
  /// Set once a preview for the pending display has been seen. Separates "the
  /// select never produced a preview" (a start failure) from "the preview
  /// resolved without our answer" (expiry or departure, both reverts).
  private var sawPreview = false
  /// True from a Keep or Revert click until its awaited outcome returns. While
  /// an answer is in flight the observation pass must not interpret the
  /// preview's disappearance; the outcome is the authority.
  private var answerInFlight = false
  private var tracking = false

  init(model: AppModel, flow: OnboardingFlowModel) {
    self.model = model
    self.flow = flow
  }

  // MARK: - Seam entry points

  func applySize(displayKey: String, looksLikeWidth: Int, looksLikeHeight: Int) {
    let coordinator = model.displayModes
    guard let state = model.displays.first(where: { $0.display.persistenceKey == displayKey })
    else {
      flow?.applyFailed()
      return
    }
    // Enumerate on demand, the same way the environment harvest does: a nil
    // catalog means nobody has asked yet, not "no modes".
    if coordinator.catalogs[state.id] == nil {
      coordinator.refreshCatalog(for: state.id)
    }
    guard let catalog = coordinator.catalogs[state.id] else {
      flow?.applyFailed()
      return
    }
    // Published rows only, matching the environment builder's suggestion rule:
    // the flow names a size, and only a published row resolves one.
    guard let row = catalog.rows.first(where: { candidate in
      !candidate.mode.isSynthesized
        && candidate.mode.logicalWidth == looksLikeWidth
        && candidate.mode.logicalHeight == looksLikeHeight
    }) else {
      flow?.applyFailed()
      return
    }
    // A pick of the size already on the glass (the alternatives grid offers
    // it) would hit the shipped already-on-screen guard, which applies nothing
    // and opens no countdown, leaving the model counting against silence. The
    // display is showing that size, which is what a kept apply means.
    if let onScreen = catalog.onScreen,
      onScreen.logicalWidth == looksLikeWidth, onScreen.logicalHeight == looksLikeHeight
    {
      flow?.applyKept()
      return
    }
    pendingDisplayID = state.id
    renderedPreview = nil
    sawPreview = false
    answerInFlight = false
    // `.settingsBanner` is the surface that presents NO floating confirmation
    // window: the Setup page renders the answer, and a second button row on
    // the display that just changed would be the two-surfaces defect the
    // surface model exists to prevent. `.floatingPanel` would present one.
    // Known residue, same class the settings window accepts: a background
    // settings window left open on this display's page also renders the
    // answerable banner; both surfaces answer with the preview they render,
    // so a stale answer is refused by the session either way.
    let selection = ResolutionSelection(
      coordinator: coordinator, displayID: state.id, surface: .settingsBanner)
    selection.select(size: row, in: catalog)
    startTrackingIfNeeded()
  }

  func keep() { answer(keeping: true) }
  func revert() { answer(keeping: false) }

  // MARK: - Answering

  private func answer(keeping: Bool) {
    guard pendingDisplayID != nil, let preview = renderedPreview, !answerInFlight else { return }
    answerInFlight = true
    let coordinator = model.displayModes
    Task { [weak self] in
      let outcome =
        keeping
        ? await coordinator.confirm(preview)
        : await coordinator.revert(preview)
      self?.handleAnswer(outcome)
    }
  }

  private func handleAnswer(_ outcome: PreviewOutcome) {
    answerInFlight = false
    guard pendingDisplayID != nil else { return }
    switch outcome {
    case .committed:
      finishPending()
      flow?.applyKept()
    case .reverted:
      finishPending()
      flow?.applyReverted()
    case .failed:
      // The session still holds the fallback and the preview stays
      // outstanding with its failure recorded, buttons live, nothing
      // auto-retries. The model stays counting, so Keep and Revert remain
      // clickable and the next click retries through the same path. Not
      // `applyFailed`: that is for an apply that never started, and calling
      // it here would abandon a preview that is still on the glass.
      break
    case .stale:
      // The answer named a preview that had already resolved (an expiry
      // racing the click). The coordinator's own handling ran; read what it
      // left behind.
      processCoordinatorState()
    }
  }

  // MARK: - Observing the coordinator

  /// Mirrors the coordinator's observable preview state into the model, the
  /// same state `BannerRegion` renders from in the settings window. There is
  /// no SwiftUI body here to track it, so a re-arming observation loop does
  /// the same job: each pass re-reads and re-arms, and every preview mutation
  /// (the once-a-second tick included) lands as a report.
  private func startTrackingIfNeeded() {
    guard !tracking else { return }
    tracking = true
    trackCoordinator()
  }

  private func trackCoordinator() {
    guard tracking else { return }
    let coordinator = model.displayModes
    withObservationTracking {
      _ = coordinator.preview
      _ = coordinator.startFailure
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.processCoordinatorState()
        if self.pendingDisplayID == nil {
          self.tracking = false
          return
        }
        self.trackCoordinator()
      }
    }
  }

  private func processCoordinatorState() {
    guard let flow, let pendingID = pendingDisplayID else { return }
    let coordinator = model.displayModes
    if let preview = coordinator.preview, preview.displayID == pendingID {
      renderedPreview = preview
      sawPreview = true
      flow.applyCountdownTicked(secondsRemaining: preview.secondsRemaining)
      return
    }
    // No outstanding preview for this display. While an answer is in flight
    // its awaited outcome decides; interpreting the gap here would report a
    // kept apply as a revert.
    if answerInFlight { return }
    if sawPreview {
      // Resolved without our answer: countdown expiry or the display's
      // departure, and the coordinator's own handling of both is a revert
      // (PD9). Reported rather than left counting.
      finishPending()
      flow.applyReverted()
    } else if let failure = coordinator.startFailure, failure.displayID == pendingID {
      // The select never took effect: begin() failed or another
      // reconfiguration claimed the displays. Nothing is outstanding. The
      // failure is dismissed once reported, because this page renders its own
      // failure copy; leaving it would show a stale banner the next time the
      // settings window opens on this display.
      finishPending()
      coordinator.dismissStartFailure()
      flow.applyFailed()
    }
  }

  private func finishPending() {
    pendingDisplayID = nil
    renderedPreview = nil
    sawPreview = false
  }
}
