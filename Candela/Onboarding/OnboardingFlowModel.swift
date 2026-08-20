import Foundation
import Observation

/// A decision the flow commits when the user advances past a page (OB7).
/// Stage 1 records these; Stage 2 routes them through the existing write
/// paths (OB6) and nothing else changes.
enum OnboardingCommit: Equatable {
  case rename(displayKey: String, name: String)
  case applySize(displayKey: String, looksLikeWidth: Int, looksLikeHeight: Int)
  case enrollInCare(displayKey: String)
  /// A re-run's off path: a display that was enrolled before this run and is
  /// no longer wanted in OLED care.
  case unenrollFromCare(displayKey: String)
  case enableMeasuredTelemetry(displayKey: String)
  /// The measurement choice turned back down to estimated. Emitted only when
  /// the harvested pref says measured, so a first run's estimated choice writes
  /// nothing and absent keeps meaning "no decision".
  case disableMeasuredTelemetry(displayKey: String)
  case setLaunchAtLogin(Bool)
}

/// What the user chose on a size page.
enum OnboardingSizeChoice: Equatable {
  case recommended
  case keepCurrent
  case custom(looksLikeWidth: Int, looksLikeHeight: Int)
}

/// The in-flow size apply, observable by the size page. One apply runs at a
/// time. The semantics are the shipped keep and revert countdown's (PD9):
/// expiry REVERTS and the page stays on its choices; only an explicit keep
/// resolves the apply and advances.
enum OnboardingApplyState: Equatable, Sendable {
  case idle
  case counting(secondsRemaining: Int)
  case kept
  case reverted
  case failed
}

/// Drives the guided setup flow over an `OnboardingEnvironment`. Owns the
/// derived page list, the in-flow choices, and the commit seam. In fixture
/// mode (Stage 1, tests) commits are recorded and the permission grant is
/// simulated; live mode replaces `commit` and the permission proxy.
@MainActor
@Observable
final class OnboardingFlowModel {
  private(set) var environment: OnboardingEnvironment
  private(set) var pages: [OnboardingPage]
  private(set) var index: Int = 0

  /// Displays currently marked as OLEDs on the designation page. Changing it
  /// re-derives the plan, which is how the care page appears and disappears.
  var designatedOleds: Set<String> {
    didSet { replan() }
  }

  /// Per-display protection choice on the care page, default on for every
  /// designated display (OB3).
  var careEnabled: Set<String>
  /// True when the user took the recommended measured path (OB5).
  var measuredTelemetry: Bool = true
  /// The size decision per display. A kept apply records `.recommended` or
  /// `.custom`; a revert (clicked or by expiry) records `.keepCurrent`. Set
  /// through the apply reports below, never directly by the countdown UI.
  var sizeChoices: [String: OnboardingSizeChoice] = [:]
  var renames: [String: String] = [:]
  /// Finish-page toggle, default checked on a first run (OB13).
  var launchAtLogin: Bool
  /// Simulated grant state in fixture mode; live mode mirrors the real
  /// permission object instead.
  var accessibilityGranted: Bool
  var accessibilityRequested = false

  /// The commit seam. Fixture mode records; live mode writes (OB6).
  var onCommit: (OnboardingCommit) -> Void
  /// Close the hosting window, recording completion (OB7 keeps everything
  /// already committed).
  var onClose: () -> Void = {}
  /// Permission actions, injected: live mode binds `AccessibilityPermission`,
  /// the mock presenter simulates a grant so the page's states are clickable.
  var onRequestAccessibility: () -> Void = {}
  var onOpenAccessibilitySettings: () -> Void = {}

  func requestAccessibility() {
    accessibilityRequested = true
    onRequestAccessibility()
  }

  func openAccessibilitySettings() {
    onOpenAccessibilitySettings()
  }

  /// OB5's ask, injected like the accessibility actions: live mode calls
  /// `CGRequestScreenCaptureAccess`, the mock records the click.
  var onRequestScreenRecording: () -> Void = {}
  /// Achieved-state check for the Screen Recording grant, injected like the
  /// ask above: live mode binds `CGPreflightScreenCaptureAccess`, because the
  /// request's own return value is false when it merely shows the dialog and
  /// proves nothing. The fixture default (installed in `init`) simulates
  /// granted-after-request so the mock flow stays demonstrable.
  var onPreflightScreenRecording: () -> Bool = { false }
  /// True once the flow has asked for Screen Recording; the care page's copy
  /// keys off this together with the granted state below.
  var screenRecordingRequested = false
  private(set) var screenRecordingGranted = false

  func requestScreenRecording() {
    screenRecordingRequested = true
    onRequestScreenRecording()
    refreshScreenRecordingGranted()
  }

  /// Re-read the grant. Called after the request and on care page appearance:
  /// the grant can land outside the app (System Settings), so the copy never
  /// trusts a stale answer.
  func refreshScreenRecordingGranted() {
    screenRecordingGranted = onPreflightScreenRecording()
  }

  // MARK: - Size apply seam

  /// The apply seam, closure and state shaped like the permission seams
  /// above. `applySize(displayKey:choice:)` starts an apply; the seam
  /// implementation reports back through `applyCountdownTicked`,
  /// `applyKept`, `applyReverted` and `applyFailed`, and the model owns what
  /// those reports mean. The defaults installed in `init` are the fixture: a
  /// simulated countdown with the shipped semantics. Live wiring replaces
  /// all three closures with the shipped mode-apply path and answers its
  /// preview directly, because the shipped banner's answering surface is
  /// fixed at preview start and renders in the settings window, never here.
  var onApplySize: (_ displayKey: String, _ looksLikeWidth: Int, _ looksLikeHeight: Int) -> Void
  var onKeepSize: () -> Void
  var onRevertSize: () -> Void

  private(set) var applyState: OnboardingApplyState = .idle

  private struct PendingApply {
    let displayKey: String
    let choice: OnboardingSizeChoice
    let looksLikeWidth: Int
    let looksLikeHeight: Int
  }

  /// The choice under countdown. Recorded into `sizeChoices` only when the
  /// countdown is answered; until then the decision does not exist yet.
  private var pendingApply: PendingApply?
  private var applyTicker: Task<Void, Never>?

  static let applyCountdownSeconds = 15

  /// Seconds the installed applier's countdown opens with, used to seed the
  /// synchronous `.counting` state in `applySize`. Only a seed: the applier's
  /// first tick report carries the real remaining seconds and overwrites it.
  /// The fixture installer sets it from its own `seconds`; live wiring sets
  /// it to the shipped preview countdown's length.
  var applierCountdownSeconds = OnboardingFlowModel.applyCountdownSeconds

  private(set) var committed: [OnboardingCommit] = []

  init(environment: OnboardingEnvironment) {
    self.environment = environment
    let designated = OnboardingPlan.initialDesignation(for: environment)
    designatedOleds = designated
    careEnabled = designated
    launchAtLogin = environment.isFirstRun ? true : environment.loginItemEnabled
    // A re-run arrives at the prior telemetry decision (OB3 keeps the
    // recommended measured default for a first run). Only an enrolled
    // display's pref carries a decision: an unenrolled display's stored
    // value is the unwritten default and must not flip the recommendation.
    if !environment.isFirstRun,
      let prior = environment.displays.first(where: \.enrolledInCare)
    {
      measuredTelemetry = prior.measuredTelemetry
    }
    accessibilityGranted = environment.accessibilityGranted
    onCommit = { _ in }
    onApplySize = { _, _, _ in }
    onKeepSize = {}
    onRevertSize = {}
    pages = OnboardingPlan.pages(for: environment, designatedOleds: designated)
    onCommit = { [weak self] in self?.committed.append($0) }
    // Fixture preflight: granted once asked, so the mock flow's measured card
    // reaches its enabled state without a real TCC grant.
    onPreflightScreenRecording = { [weak self] in self?.screenRecordingRequested ?? false }
    installFixtureSizeApplier()
  }

  var currentPage: OnboardingPage { pages[min(index, pages.count - 1)] }
  var canGoBack: Bool { index > 0 }
  var isLastPage: Bool { index >= pages.count - 1 }

  func display(forKey key: String) -> OnboardingDisplayEntry? {
    environment.displays.first { $0.persistenceKey == key }
  }

  func displayName(forKey key: String) -> String {
    // A cleared name field stores an empty rename, which every later page
    // would render as a blank title; a rename that trims to nothing falls
    // back to the environment's name instead.
    if let rename = renames[key],
      !rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return rename
    }
    return display(forKey: key)?.name ?? key
  }

  /// Commit the current page's decisions, then move forward (OB7). The last
  /// page's advance closes the window.
  func advance() {
    // An unanswered countdown never rides an advance: revert it first, so
    // the commit below sees the decision as keeping the current size.
    if case .counting = applyState { revertSize() }
    commitCurrentPage()
    if isLastPage {
      resetApplyState()
      onClose()
    } else {
      index += 1
      resetApplyState()
    }
  }

  func back() {
    guard canGoBack else { return }
    if case .counting = applyState { revertSize() }
    index -= 1
    resetApplyState()
  }

  /// Skip Setup: close without committing the current page. Everything
  /// already applied stays applied (OB7), and an unconfirmed preview is not
  /// applied: it is reverted before the window goes.
  func skip() {
    if case .counting = applyState { revertSize() }
    resetApplyState()
    onClose()
  }

  /// Mid-flow environment change (a display unplugged): re-derive and keep
  /// the position on a still-valid page.
  func update(environment: OnboardingEnvironment) {
    var environment = environment
    // An in-flight apply changes the display's mode, and the re-harvest that
    // follows sees the previewed size as current, so the fresh entry arrives
    // with no suggestion (the suppression working as designed for a display
    // already at its best size). Without the prior suggestion the size page
    // would vanish mid-countdown and its disappearance would revert the very
    // apply the user asked for. Carry the old suggestion forward while the
    // apply is unresolved; once it resolves, the next harvest drops the page
    // normally.
    if applyState != .idle, let pending = pendingApply,
      let prior = display(forKey: pending.displayKey)?.sizeSuggestion,
      let present = environment.displays.firstIndex(
        where: { $0.persistenceKey == pending.displayKey })
    {
      environment.displays[present].sizeSuggestion = prior
    }
    self.environment = environment
    if let pending = pendingApply,
      !environment.displays.contains(where: { $0.persistenceKey == pending.displayKey })
    {
      // The shipped apply path clears its own preview when a display
      // departs, so there is nothing left to answer; the flow forgets the
      // countdown rather than answering into the void.
      resetApplyState()
    }
    designatedOleds = designatedOleds.filter { key in
      environment.displays.contains { $0.persistenceKey == key }
    }
    // didSet already replanned; clamp in case the list shrank.
    index = min(index, pages.count - 1)
  }

  // MARK: - Size apply entry points (called by the size page)

  /// Start the keep and revert countdown for a chosen size. The choice is
  /// held as pending and recorded only when the countdown is answered with a
  /// keep; the `.applySize` commit that eventually rides the advance is a
  /// record of that kept apply, never a trigger.
  func applySize(displayKey: String, choice: OnboardingSizeChoice) {
    let size: (width: Int, height: Int)
    switch choice {
    case .recommended:
      guard let suggestion = display(forKey: displayKey)?.sizeSuggestion else { return }
      size = (suggestion.looksLikeWidth, suggestion.looksLikeHeight)
    case let .custom(width, height):
      size = (width, height)
    case .keepCurrent:
      // Keeping the current size applies nothing; the page records it
      // directly and advances.
      return
    }
    applyTicker?.cancel()
    pendingApply = PendingApply(
      displayKey: displayKey, choice: choice,
      looksLikeWidth: size.width, looksLikeHeight: size.height)
    applyState = .counting(secondsRemaining: applierCountdownSeconds)
    onApplySize(displayKey, size.width, size.height)
  }

  /// The answer routes, guarded on an open countdown so a double click or a
  /// click racing an expiry answers nothing. In live mode the shipped
  /// coordinator refuses a stale answer on its own; this guard mirrors it.
  func keepSize() {
    guard case .counting = applyState else { return }
    onKeepSize()
  }

  func revertSize() {
    guard case .counting = applyState else { return }
    onRevertSize()
  }

  /// Belt and braces at the flow's edge: a countdown the user walks away
  /// from is answered with a revert, so an unconfirmed mode change never
  /// outlives its page. The shipped apply path's own departure and expiry
  /// handling stays authoritative; this only forwards the answer.
  func sizePageDisappeared() {
    guard case .counting = applyState else { return }
    revertSize()
  }

  // MARK: - Size apply reports (called by the seam implementation)

  func applyCountdownTicked(secondsRemaining: Int) {
    guard pendingApply != nil else { return }
    applyState = .counting(secondsRemaining: max(0, secondsRemaining))
  }

  /// A kept apply: the display is already showing the size, so record the
  /// choice for the commit record (OB7) and move on.
  func applyKept() {
    guard let pending = pendingApply else { return }
    applyTicker?.cancel()
    sizeChoices[pending.displayKey] = pending.choice
    applyState = .kept
    advance()
  }

  /// A revert, clicked or by countdown expiry (PD9: expiry reverts, it never
  /// silently keeps). The page stays on its choices and the decision so far
  /// is keeping the current size.
  func applyReverted() {
    guard let pending = pendingApply else { return }
    applyTicker?.cancel()
    sizeChoices[pending.displayKey] = .keepCurrent
    pendingApply = nil
    applyState = .reverted
  }

  /// The apply could not start or resolve. Nothing is recorded; the page
  /// offers the choices again.
  func applyFailed() {
    guard pendingApply != nil else { return }
    applyTicker?.cancel()
    pendingApply = nil
    applyState = .failed
  }

  // MARK: - Size apply state for the page

  /// Seconds remaining for THIS display's open countdown, nil otherwise.
  func applyCountdownSecondsRemaining(forKey key: String) -> Int? {
    guard let pendingApply, pendingApply.displayKey == key,
      case let .counting(seconds) = applyState
    else { return nil }
    return seconds
  }

  /// The size under countdown for this display, for the page's size label.
  func pendingAppliedSize(forKey key: String) -> (width: Int, height: Int)? {
    guard let pendingApply, pendingApply.displayKey == key else { return nil }
    return (pendingApply.looksLikeWidth, pendingApply.looksLikeHeight)
  }

  // MARK: - Fixture applier

  /// Fixture mode: a simulated countdown with the shipped semantics. Expiry
  /// reverts and the page stays; the Stage 1 mock auto-advanced on expiry,
  /// which is the defect this replaces. Installed by `init` so the mock
  /// presenter and tests get it for free; tests shrink `seconds` and `tick`.
  func installFixtureSizeApplier(
    seconds: Int = OnboardingFlowModel.applyCountdownSeconds,
    tick: Duration = .seconds(1)
  ) {
    applierCountdownSeconds = seconds
    onApplySize = { [weak self] _, _, _ in
      self?.beginFixtureCountdown(seconds: seconds, tick: tick)
    }
    onKeepSize = { [weak self] in self?.applyKept() }
    onRevertSize = { [weak self] in self?.applyReverted() }
  }

  private func beginFixtureCountdown(seconds: Int, tick: Duration) {
    applyTicker?.cancel()
    applyCountdownTicked(secondsRemaining: seconds)
    applyTicker = Task { [weak self] in
      var remaining = seconds
      while remaining > 0 {
        try? await Task.sleep(for: tick)
        guard !Task.isCancelled else { return }
        remaining -= 1
        self?.applyCountdownTicked(secondsRemaining: remaining)
      }
      guard !Task.isCancelled else { return }
      self?.applyReverted()
    }
  }

  private func resetApplyState() {
    applyTicker?.cancel()
    pendingApply = nil
    applyState = .idle
  }

  private func replan() {
    let current = currentPage
    pages = OnboardingPlan.pages(for: environment, designatedOleds: designatedOleds)
    if let stillThere = pages.firstIndex(of: current) {
      index = stillThere
    } else {
      index = min(index, pages.count - 1)
    }
  }

  private func commitCurrentPage() {
    switch currentPage {
    case .welcome, .accessibility, .noDisplays:
      break
    case .oledSelect:
      // Un-enrollment is split across two pages on purpose. A deselect can be
      // the very thing that takes the care page out of the plan, so the care
      // arm would never run for it; this arm owns the displays that left the
      // designation, and the care arm owns the ones still in it with their
      // toggle off. The two sets cannot overlap, so nothing is written twice.
      for entry in environment.displays
      where entry.enrolledInCare && !designatedOleds.contains(entry.persistenceKey) {
        onCommit(.unenrollFromCare(displayKey: entry.persistenceKey))
      }
    case .detection:
      for (key, newName) in renames {
        let original = display(forKey: key)?.name
        if !newName.isEmpty, newName != original {
          onCommit(.rename(displayKey: key, name: newName))
        }
      }
    case let .size(displayKey):
      // The commit is a record of a KEPT apply, never a trigger: the display
      // changed through the shipped apply path when the countdown was
      // answered. A page left with no kept apply records nothing.
      switch sizeChoices[displayKey] {
      case .recommended:
        if let suggestion = display(forKey: displayKey)?.sizeSuggestion {
          onCommit(.applySize(
            displayKey: displayKey,
            looksLikeWidth: suggestion.looksLikeWidth,
            looksLikeHeight: suggestion.looksLikeHeight))
        }
      case let .custom(width, height):
        onCommit(.applySize(
          displayKey: displayKey, looksLikeWidth: width, looksLikeHeight: height))
      case .keepCurrent, nil:
        break
      }
    case .oledCare:
      for key in designatedOleds.sorted() {
        let harvested = display(forKey: key)
        if careEnabled.contains(key) {
          onCommit(.enrollInCare(displayKey: key))
          if measuredTelemetry {
            onCommit(.enableMeasuredTelemetry(displayKey: key))
          } else if harvested?.measuredTelemetry == true {
            // Differs-only, against the harvested pref rather than the flow's
            // default: a first run that picks estimated writes nothing, so an
            // absent key keeps meaning "no decision made yet".
            onCommit(.disableMeasuredTelemetry(displayKey: key))
          }
        } else if harvested?.enrolledInCare == true {
          onCommit(.unenrollFromCare(displayKey: key))
        }
      }
    case .finish:
      onCommit(.setLaunchAtLogin(launchAtLogin))
    }
  }
}
