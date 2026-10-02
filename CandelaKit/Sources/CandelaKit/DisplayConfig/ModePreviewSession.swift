import CoreGraphics
import Foundation

/// The applied-but-unresolved preview a UI renders, and the value an answer
/// carries back so it can only ever resolve the preview it was given for.
public struct PreviewedMode: Sendable, Equatable {
  public let displayID: CGDirectDisplayID
  public let mode: DisplayMode
  /// Latest evidence of a commit that did not achieve its request. Once set,
  /// this preview offers recovery only; choosing a mode starts a fresh preview.
  /// Answers still match by display and mode, so an older caption cannot block
  /// a revert or bypass recovery-only confirmation.
  public let unhonouredCommit: DisplayConfigError.UnhonouredCommit?

  public init(
    displayID: CGDirectDisplayID,
    mode: DisplayMode,
    unhonouredCommit: DisplayConfigError.UnhonouredCommit? = nil
  ) {
    self.displayID = displayID
    self.mode = mode
    self.unhonouredCommit = unhonouredCommit
  }
}

/// Preview, confirm, commit, with a countdown that defaults to revert.
///
/// A mode can leave a display unreadable, and then nobody can click "Keep", so
/// the safe outcome is the one that happens when nobody answers.
/// `.preview` scope is a second backstop: `kCGConfigureForAppOnly` reverts if
/// the app dies. An actor because the countdown and the answer race.
///
/// Invariants the safety argument rests on:
/// - No preview begins until the fallback mode has been read.
/// - Confirm never commits a mode after a known unhonoured commit. A fresh
///   preview is required before that mode can be kept.
/// - A preview stays outstanding until a resolution succeeds, which is why every
///   guard asks "is a preview applied?" and never "was an answer given?". A
///   throw never invalidates the fallback: a refusal left the display alone, and
///   an unhonoured commit moved it without touching the pre-preview mode.
public actor ModePreviewSession {
  /// One value so no path can pair one preview's display ID with another's
  /// fallback mode.
  private struct OutstandingPreview {
    let displayID: CGDirectDisplayID
    /// Captured before the preview was applied. Survives failed resolutions.
    let previousMode: DisplayMode
    let previewedMode: DisplayMode
    /// The fallback must not follow a reused display ID onto new hardware.
    let displayIdentity: DisplayConfigIdentity
    /// Updated only after a committed failure; precommit refusals move nothing.
    var unhonouredCommit: DisplayConfigError.UnhonouredCommit?
  }

  private let configurator: any DisplayConfiguring
  private let countdownSeconds: Int

  private var outstanding: OutstandingPreview?
  private var countdown = PreviewCountdown()
  private var lastOutcome: PreviewOutcome?

  /// Thirty seconds, matching `MirrorPreviewSession`. Fifteen was not long
  /// enough to find and read a confirmation on a display whose text just halved.
  public init(configurator: any DisplayConfiguring, countdownSeconds: Int = 30) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { countdown.remaining }

  /// True while a preview is applied and unresolved, including after a
  /// resolution that threw. `revert()` is worth calling exactly while it holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// What is applied and unresolved. A UI rebuilds its state from this.
  public var previewedMode: PreviewedMode? {
    outstanding.map {
      PreviewedMode(
        displayID: $0.displayID, mode: $0.previewedMode, unhonouredCommit: $0.unhonouredCommit
      )
    }
  }

  /// Reported rather than inferred: a failed expiry disarms the countdown
  /// while a failed commit leaves it armed.
  public var isCountingDown: Bool { countdown.isArmed && outstanding != nil }

  /// The display is gone: drop the preview without applying anything.
  ///
  /// `begin()` on another display refuses when it cannot revert an outstanding
  /// preview, so one departed display would otherwise wedge mode switching for
  /// every other display. The departed mode was app-scoped and is renegotiated
  /// on return, so `.reverted` is the honest outcome.
  @discardableResult
  public func discard(displayID: CGDirectDisplayID) -> Bool {
    guard outstanding?.displayID == displayID else { return false }
    outstanding = nil
    countdown.disarm()
    lastOutcome = .reverted
    return true
  }

  public func begin(
    mode: DisplayMode, on displayID: CGDirectDisplayID
  ) -> Result<Void, DisplayConfigError> {
    if let outstanding, !displayStillMatches(outstanding.displayID, identity: outstanding.displayIdentity) {
      discard(displayID: outstanding.displayID)
      lastOutcome = .stale
      return .failure(DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue))
    }
    // An unknown identity would make every later identity check pass, so a
    // fallback could follow a reused display ID onto other hardware.
    guard let displayIdentity = outstanding?.displayID == displayID
      ? outstanding?.displayIdentity
      : configurator.displays().first(where: { $0.id == displayID })?.identity
    else {
      return .failure(DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue))
    }
    let previous: DisplayMode

    if let outstanding {
      if outstanding.displayID == displayID {
        // Keep the ORIGINAL fallback: the mode on screen is the unconfirmed
        // preview, which is never safe to fall back to.
        previous = outstanding.previousMode
      } else {
        // End a live preview on another display first, or its fallback gets
        // retargeted here and that display is left in preview with no
        // countdown. Refuse if the revert fails rather than strand it.
        //
        // That error describes the OTHER display; `DisplayConfigError` carries no
        // display ID, and widening it would touch every caller.
        if case let .failed(error) = revertOutstanding() { return .failure(error) }
        guard let read = configurator.currentMode(for: displayID) else {
          return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
        }
        previous = read
      }
    } else {
      // Capture before applying: revert restores this exact mode, not
      // whatever macOS considers the default.
      guard let read = configurator.currentMode(for: displayID) else {
        // No readable mode means no way back, so refuse the preview.
        return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
      }
      previous = read
    }

    var unhonoured: DisplayConfigError.UnhonouredCommit?
    guard displayStillMatches(displayID, identity: displayIdentity) else {
      discard(displayID: displayID)
      lastOutcome = .stale
      return .failure(DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue))
    }
    do {
      try configurator.apply(mode, to: displayID, scope: .preview)
    } catch let error as DisplayConfigError {
      // A commit the display did not honour is not a refusal: the display is on a
      // mode nobody picked, and failing here would leave it there with no
      // countdown. So it is captured like a success; the fallback read before the
      // apply is still the way back, and the countdown takes it.
      guard let commit = error.unhonouredCommit else { return .failure(error) }
      unhonoured = commit
      guard displayStillMatches(displayID, identity: displayIdentity) else {
        discard(displayID: displayID)
        lastOutcome = .stale
        return .failure(error)
      }
      if commit.scanoutTiming != nil {
        // A confirmed controller mismatch needs no visual vote. Try the
        // captured fallback now; a failed restore keeps the countdown below.
        do {
          try configurator.restore(previous, to: displayID, scope: .session)
          guard displayStillMatches(displayID, identity: displayIdentity) else {
            discard(displayID: displayID)
            lastOutcome = .stale
            return .failure(error)
          }
          outstanding = nil
          countdown.disarm()
          lastOutcome = .reverted
          return .failure(DisplayConfigError(unhonouredCommit: .init(
            requested: commit.requested, achieved: commit.achieved,
            scanoutTiming: commit.scanoutTiming, fallbackRestored: true)))
        } catch {
          // Retain the original failure and fallback for recovery and retry.
        }
      }
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    guard displayStillMatches(displayID, identity: displayIdentity) else {
      discard(displayID: displayID)
      lastOutcome = .stale
      return .failure(DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue))
    }
    // Retain the requested mode to match answers, even when recovery is the
    // only available action.
    outstanding = OutstandingPreview(
      displayID: displayID, previousMode: previous, previewedMode: mode,
      displayIdentity: displayIdentity,
      unhonouredCommit: unhonoured
    )
    // Cleared here, not on entry: a begin() that fails establishes nothing, so
    // the last thing that really happened to the display stays the last outcome.
    lastOutcome = nil
    countdown.arm(seconds: countdownSeconds)
    return .success(())
  }

  /// Keep the original safe target when an unattended apply and its immediate
  /// rollback both failed. It is recovery-only and cannot replace a live preview.
  @discardableResult
  public func retainRecovery(
    after commit: DisplayConfigError.UnhonouredCommit, previousMode: DisplayMode,
    on displayID: CGDirectDisplayID, identity: DisplayConfigIdentity
  ) -> Bool {
    guard outstanding == nil,
          configurator.displays().contains(where: { $0.id == displayID && $0.identity == identity })
    else { return false }
    outstanding = OutstandingPreview(
      displayID: displayID, previousMode: previousMode, previewedMode: commit.requested,
      displayIdentity: identity, unhonouredCommit: commit)
    lastOutcome = nil
    countdown.arm(seconds: countdownSeconds)
    return true
  }

  /// Commits the preview the caller was looking at.
  ///
  /// `answered` is the `PreviewedMode` that was rendered. If a second selection
  /// landed since, the answer is stale: committing would make a mode the user
  /// never saw permanent at session scope while reporting success.
  public func confirm(_ answered: PreviewedMode) -> PreviewOutcome {
    guard let outstanding else {
      // Nothing applied: repeat the last outcome rather than invent a
      // reversion. Never begun reports reverted, since nothing is kept.
      return lastOutcome ?? .reverted
    }
    guard matches(answered, outstanding) else { return .stale }
    if let commit = outstanding.unhonouredCommit {
      let failure = PreviewOutcome.failed(DisplayConfigError(unhonouredCommit: commit))
      lastOutcome = failure
      return failure
    }
    guard answered.unhonouredCommit == nil else { return .stale }
    return resolve(
      applying: outstanding.previewedMode, to: outstanding.displayID, success: .committed,
      restoring: false
    )
  }

  /// Safe to retry for the same preview. Failed attempts preserve the original
  /// fallback, even when the display committed a different mode.
  public func revert(_ answered: PreviewedMode) -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard matches(answered, outstanding) else { return .stale }
    return revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the
  /// outcome when it expires.
  public func tick() -> PreviewOutcome? {
    guard outstanding != nil, countdown.tick() else { return nil }
    return revertOutstanding()
  }

  // MARK: - Private

  /// The expiry and the cross-display hand-off skip the intent check: they are
  /// the session's own decisions, not a person's answer. Only answers go stale.
  private func revertOutstanding() -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    return resolve(
      applying: outstanding.previousMode, to: outstanding.displayID, success: .reverted,
      restoring: true
    )
  }

  private func displayStillMatches(_ displayID: CGDirectDisplayID, identity: DisplayConfigIdentity?) -> Bool {
    guard let identity else { return false }
    return configurator.displays().contains {
      $0.id == displayID && $0.identity == identity
    }
  }

  private func matches(_ answered: PreviewedMode, _ outstanding: OutstandingPreview) -> Bool {
    answered.displayID == outstanding.displayID && answered.mode == outstanding.previewedMode
  }

  /// Only success clears the outstanding preview. A refusal moved nothing, and an
  /// unhonoured commit moved the display to a third mode without touching the
  /// record of the pre-preview mode, so session state is kept in both cases.
  ///
  /// A failed commit leaves the countdown armed on purpose, so a mode that
  /// could not be made permanent still falls back to one the user can see.
  private func resolve(
    applying mode: DisplayMode, to displayID: CGDirectDisplayID,
    success: PreviewOutcome, restoring: Bool
  ) -> PreviewOutcome {
    let displayIdentity = outstanding?.displayIdentity
    if let outstanding, !displayStillMatches(displayID, identity: displayIdentity) {
      discard(displayID: outstanding.displayID)
      lastOutcome = .stale
      return .stale
    }
    do {
      if restoring {
        try configurator.restore(mode, to: displayID, scope: .session)
      } else {
        try configurator.apply(mode, to: displayID, scope: .session)
      }
    } catch let error as DisplayConfigError {
      if let commit = error.unhonouredCommit {
        outstanding?.unhonouredCommit = commit
        guard displayStillMatches(displayID, identity: displayIdentity) else {
          discard(displayID: displayID)
          lastOutcome = .failed(error)
          return .failed(error)
        }
        if commit.scanoutTiming != nil, success == .committed,
           revertOutstanding() == .reverted,
           displayStillMatches(displayID, identity: displayIdentity) {
          let restored = DisplayConfigError(unhonouredCommit: .init(
            requested: commit.requested, achieved: commit.achieved,
            scanoutTiming: commit.scanoutTiming, fallbackRestored: true))
          lastOutcome = .failed(restored)
          return .failed(restored)
        }
      }
      lastOutcome = .failed(error)
      return .failed(error)
    } catch {
      let error = DisplayConfigError(cgErrorCode: -1)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    guard displayStillMatches(displayID, identity: displayIdentity) else {
      discard(displayID: displayID)
      lastOutcome = .stale
      return .stale
    }
    outstanding = nil
    countdown.disarm()
    lastOutcome = success
    return success
  }
}
