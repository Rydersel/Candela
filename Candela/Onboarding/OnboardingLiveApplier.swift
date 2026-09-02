import CandelaKit
import CoreGraphics
import Observation

/// Implements the flow model's apply seam over the shipped mode-apply path.
///
/// Two shipped facts fix the shape. An apply must ride the one path every
/// resolution control uses (`ResolutionSelection` into
/// `DisplayModeCoordinator.selectFromList`), so the real keep and revert
/// countdown guards it (expiry reverts, never silently keeps). And the
/// shipped countdown's answering surface is fixed at preview start, never this
/// window, so Setup renders its OWN Keep and Revert from the coordinator's
/// observable preview state and answers with `confirm`/`revert` carrying the
/// exact preview it rendered: an answer can only resolve what the user was
/// looking at. The preview it starts therefore carries `.guidedSetup`, the
/// surface no other one answers for.
///
/// This object reports into the model and owns no meaning of its own; the model
/// decides what each report does to the flow.
@MainActor
final class OnboardingLiveApplier {
  /// What the flow's synchronous `.counting` seed shows before the first
  /// observed tick. Mirrors `ModePreviewSession`'s default countdown length, and
  /// is only cosmetic: the first tick report overwrites it.
  static let countdownSeedSeconds = 30

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
  /// An answer requested before the first preview observation (the window can
  /// close between the select and the first tick). Held and delivered when the
  /// preview appears, cleared if the apply resolves some other way first. True
  /// keeps, false reverts.
  private var requestedAnswerBeforePreview: Bool?
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
    // A pick of the size already on the glass (the alternatives grid offers it)
    // would hit the shipped already-on-screen guard, which applies nothing and
    // opens no countdown, leaving the model counting against silence. The
    // display is showing that size, which is what a kept apply means.
    if let onScreen = catalog.onScreen,
      onScreen.logicalWidth == looksLikeWidth, onScreen.logicalHeight == looksLikeHeight
    {
      flow?.applyKept()
      return
    }
    // A start failure left by an earlier select must not be mistaken for THIS
    // apply's outcome: the failure branch below keys on the display alone, so
    // dismiss a stale one before the select.
    if let stale = coordinator.startFailure, stale.displayID == state.id {
      coordinator.dismissStartFailure()
    }
    pendingDisplayID = state.id
    renderedPreview = nil
    sawPreview = false
    answerInFlight = false
    requestedAnswerBeforePreview = nil
    // This flow OWNS the answer: the Setup page renders the countdown and
    // both buttons itself, and no other surface offers an ANSWER for
    // `.guidedSetup`. The floating confirmation window is not presented, the
    // settings banner renders nothing even in a background window on this
    // display's page, and the menu-bar panel keeps its passive waiting line.
    // Ownership is the guarantee; the session's stale-answer refusal is a
    // backstop, not what keeps two button rows from disagreeing.
    let selection = ResolutionSelection(
      coordinator: coordinator, displayID: state.id, surface: .guidedSetup)
    selection.select(size: row, in: catalog)
    startTrackingIfNeeded()
  }

  func keep() { answer(keeping: true) }
  func revert() { answer(keeping: false) }

  /// Forget the pending apply so the next observation pass lets the tracking
  /// loop die. Called when the hosting window closes and when a fresh flow
  /// replaces this applier: a departed display or a late outcome must not leave
  /// the loop armed against a dead flow. An answer already requested before the
  /// first preview observation is kept, and the loop stays armed just long
  /// enough to deliver it.
  func cancel() {
    guard requestedAnswerBeforePreview == nil else { return }
    finishPending()
  }

  // MARK: - Answering

  private func answer(keeping: Bool) {
    guard pendingDisplayID != nil, !answerInFlight else { return }
    guard let preview = renderedPreview else {
      // The apply is pending but its preview has not been observed yet. Hold
      // the answer; the observation pass delivers it when the preview appears,
      // so the preview never runs headless to expiry.
      requestedAnswerBeforePreview = keeping
      return
    }
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
      // The preview stays outstanding with its failure recorded and nothing
      // auto-retries, so the model stays counting and the next click retries
      // through the same path. Not `applyFailed`: that is for an apply that
      // never started, and it would abandon a preview still on the glass.
      break
    case .stale:
      // The answer named a preview that had already resolved (an expiry
      // racing the click). The coordinator's own handling ran; read what it
      // left behind.
      processCoordinatorState()
    }
  }

  // MARK: - Observing the coordinator

  /// Mirrors the coordinator's observable preview state into the model, the same
  /// state `BannerRegion` renders from. No SwiftUI body here tracks it, so a
  /// re-arming observation loop does the job: each pass re-reads and re-arms, so
  /// every preview mutation (the once-a-second tick included) lands as a report.
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
    guard let pendingID = pendingDisplayID else { return }
    let coordinator = model.displayModes
    if let preview = coordinator.preview, preview.displayID == pendingID {
      renderedPreview = preview
      sawPreview = true
      // An answer requested before this first observation is delivered now,
      // with the preview it could not name earlier.
      if let keeping = requestedAnswerBeforePreview {
        requestedAnswerBeforePreview = nil
        answer(keeping: keeping)
        return
      }
      flow?.applyCountdownTicked(secondsRemaining: preview.secondsRemaining)
      return
    }
    // No outstanding preview for this display. While an answer is in flight
    // its awaited outcome decides; interpreting the gap here would report a
    // kept apply as a revert.
    if answerInFlight { return }
    if sawPreview {
      // Resolved without our answer: countdown expiry or the display's
      // departure, and the coordinator's own handling of both is a revert.
      // Reported rather than left counting.
      finishPending()
      flow?.applyReverted()
    } else if let failure = coordinator.startFailure, failure.displayID == pendingID {
      // The select never took effect: begin() failed, or another reconfiguration
      // claimed the displays. Dismissed once reported, since this page renders
      // its own failure copy and leaving it would show a stale banner the next
      // time the settings window opens on this display.
      finishPending()
      coordinator.dismissStartFailure()
      flow?.applyFailed()
    }
  }

  private func finishPending() {
    pendingDisplayID = nil
    renderedPreview = nil
    sawPreview = false
    requestedAnswerBeforePreview = nil
  }
}
