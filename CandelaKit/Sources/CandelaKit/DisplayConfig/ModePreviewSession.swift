import CoreGraphics
import Foundation

public enum ModePreviewOutcome: Sendable, Equatable {
  case committed
  case reverted
  case failed(DisplayConfigError)
  /// The answer named a preview that is no longer the outstanding one, so it
  /// resolved nothing and the outstanding preview is untouched. An answer is
  /// given about something a person was looking at; applying it to a different
  /// preview would commit a mode they never saw.
  case stale
}

/// The applied-but-unresolved preview: what a UI renders, and what an answer
/// about that UI carries back.
///
/// It is the *intent* half that makes the guarantee structural. Rendering from
/// the session already removed one class of disagreement; passing the same
/// value back into `confirm`/`revert` removes the other, because an answer can
/// then only ever resolve the preview it was given for. Queue ordering becomes
/// an optimisation rather than the thing preventing a wrong commit.
public struct PreviewedMode: Sendable, Equatable {
  public let displayID: CGDirectDisplayID
  public let mode: DisplayMode

  public init(displayID: CGDirectDisplayID, mode: DisplayMode) {
    self.displayID = displayID
    self.mode = mode
  }
}

/// Preview → confirm → commit, with a countdown that **defaults to revert**.
///
/// The whole reason this exists: a mode can leave a display unreadable, and at
/// that point the user cannot click "Keep". So the safe outcome must be the
/// one that happens when nobody does anything (spec DM4). `.preview` scope is
/// a second backstop — `kCGConfigureForAppOnly` reverts if the app dies.
///
/// An actor because the countdown and the user's answer race by construction.
///
/// Three things the safety argument depends on, all enforced below:
/// - A preview never begins unless the mode to fall back to was read first.
///   Without it the countdown would expire into a no-op, which is the failure
///   this whole type exists to prevent.
/// - Confirming commits the mode that was previewed, not whatever the display
///   reports at confirm time. The two differ exactly when something went wrong
///   (replug, sleep/wake, another process reconfiguring), and committing the
///   drifted value with session scope would make an unapproved mode permanent
///   while reporting success.
/// - **A preview stays outstanding until a resolution actually succeeds.** An
///   apply that throws changes nothing on the display, so the fallback mode is
///   still valid and still needed: `revert()` can be re-attempted, and a fresh
///   `begin()` on the same display keeps the ORIGINAL fallback instead of
///   adopting the unapproved preview as one. Every guard here therefore asks
///   "is a preview still applied?" and never "was an answer given?".
public actor ModePreviewSession {
  /// The three facts that are only ever true together. Modelled as one value so
  /// no code path can leave the display ID pointing at one session and the
  /// fallback mode at another.
  private struct OutstandingPreview {
    let displayID: CGDirectDisplayID
    /// Captured before the preview was applied. Survives failed resolutions.
    let previousMode: DisplayMode
    let previewedMode: DisplayMode
  }

  private let configurator: any DisplayConfiguring
  private let countdownSeconds: Int

  private var outstanding: OutstandingPreview?
  private var remaining = 0
  /// The countdown fires at most once. A failed expiry revert is re-attempted
  /// through `revert()`, not by returning `.failed` from every later tick.
  private var countdownArmed = false
  private var lastOutcome: ModePreviewOutcome?

  /// Thirty seconds, the same as `MirrorPreviewSession`. The two are the same
  /// kind of decision — a reconfiguration that may itself have made the answer
  /// hard to read — so a different timer on each would be arbitrary. It was
  /// fifteen, which is not long enough to find and read a confirmation window
  /// on a display whose text has just halved in size.
  public init(configurator: any DisplayConfiguring, countdownSeconds: Int = 30) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { remaining }

  /// True while a preview is applied and unresolved — including after a
  /// resolution that threw. `revert()` is worth calling exactly while this
  /// holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// What is applied and unresolved, if anything. The authority a UI rebuilds
  /// its own state from.
  public var previewedMode: PreviewedMode? {
    outstanding.map { PreviewedMode(displayID: $0.displayID, mode: $0.previewedMode) }
  }

  /// Whether the countdown can still expire into a revert. Reported rather
  /// than inferred: a failed EXPIRY disarms it while a failed COMMIT leaves it
  /// armed, and a caller that guesses wrong either shows a countdown that will
  /// never fire or hides one that will.
  public var isCountingDown: Bool { countdownArmed && outstanding != nil }

  /// The display is gone. Drops the outstanding preview WITHOUT applying
  /// anything — there is nothing left to apply it to.
  ///
  /// Not cosmetic: `begin()` on another display first reverts an outstanding
  /// preview and REFUSES if that revert fails, so one departed display would
  /// otherwise wedge mode switching for every other display until the app
  /// restarts. `.preview` scope means the departed display keeps nothing: its
  /// mode is app-scoped and renegotiated when it returns, so `.reverted` is the
  /// honest outcome to report.
  @discardableResult
  public func discard(displayID: CGDirectDisplayID) -> Bool {
    guard outstanding?.displayID == displayID else { return false }
    outstanding = nil
    remaining = 0
    countdownArmed = false
    lastOutcome = .reverted
    return true
  }

  public func begin(
    mode: DisplayMode, on displayID: CGDirectDisplayID
  ) -> Result<Void, DisplayConfigError> {
    let previous: DisplayMode

    if let outstanding {
      if outstanding.displayID == displayID {
        // Re-previewing the same display keeps the ORIGINAL fallback. The mode
        // currently on screen is the unconfirmed preview, which is never a safe
        // thing to fall back to — and after a failed resolution it is the mode
        // we are specifically trying to get away from.
        previous = outstanding.previousMode
      } else {
        // A live preview on a DIFFERENT display is ended first: otherwise its
        // fallback would be silently retargeted at the new display, and the old
        // one left in preview with no countdown. If that revert fails, refuse —
        // reporting success here would leave a display nobody named stranded on
        // an unapproved mode.
        if case let .failed(error) = revertOutstanding() { return .failure(error) }
        guard let read = configurator.currentMode(for: displayID) else {
          return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
        }
        previous = read
      }
    } else {
      // Capture BEFORE applying — reverting restores this exact mode, not
      // "whatever macOS thinks the default is".
      guard let read = configurator.currentMode(for: displayID) else {
        // Nothing readable to restore means nothing to undo with. Refusing the
        // preview is the only safe answer; the caller surfaces it.
        return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
      }
      previous = read
    }

    do {
      try configurator.apply(mode, to: displayID, scope: .preview)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    outstanding = OutstandingPreview(
      displayID: displayID, previousMode: previous, previewedMode: mode
    )
    // Cleared HERE, not on entry: a begin() that fails establishes nothing, so
    // the last thing that actually happened to the display is still the last
    // outcome. Wiping it on the way in would make a later confirm() report a
    // reversion that never happened, after a commit that did.
    lastOutcome = nil
    remaining = countdownSeconds
    countdownArmed = true
    return .success(())
  }

  /// Commits the preview the caller was looking at.
  ///
  /// `answered` is the `PreviewedMode` that was RENDERED. If the outstanding
  /// preview has moved on since — a second selection landed between the click
  /// and this call — the answer does not apply to it, and committing anyway
  /// would make a mode the user never saw permanent at session scope while
  /// reporting success. That is the worst failure this type can produce, so it
  /// is refused structurally rather than prevented by call ordering.
  public func confirm(_ answered: PreviewedMode) -> ModePreviewOutcome {
    guard let outstanding else {
      // Nothing is applied: repeat the answer already given rather than
      // inventing a reversion that never happened. Never begun at all is
      // reported as reverted — nothing is being kept.
      return lastOutcome ?? .reverted
    }
    guard matches(answered, outstanding) else { return .stale }
    return resolve(
      applying: outstanding.previewedMode, to: outstanding.displayID, success: .committed
    )
  }

  /// Safe to call repeatedly while `hasOutstandingPreview` names the same
  /// preview. A revert that threw left the display where it was, so trying
  /// again once CoreGraphics recovers is the whole recovery path — the error UI
  /// hangs off this, and it passes back the same `PreviewedMode` it is showing.
  public func revert(_ answered: PreviewedMode) -> ModePreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard matches(answered, outstanding) else { return .stale }
    return revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the
  /// outcome when it expires.
  public func tick() -> ModePreviewOutcome? {
    guard countdownArmed, outstanding != nil else { return nil }
    remaining -= 1
    guard remaining <= 0 else { return nil }
    remaining = 0
    countdownArmed = false
    return revertOutstanding()
  }

  // MARK: - Private

  /// The expiry and the cross-display hand-off revert without an intent check
  /// on purpose: they are the SESSION's own decisions about whatever it is
  /// holding, not a person's answer to a banner. Only answers can be stale.
  private func revertOutstanding() -> ModePreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    return resolve(
      applying: outstanding.previousMode, to: outstanding.displayID, success: .reverted
    )
  }

  private func matches(_ answered: PreviewedMode, _ outstanding: OutstandingPreview) -> Bool {
    answered.displayID == outstanding.displayID && answered.mode == outstanding.previewedMode
  }

  /// Success is what clears the outstanding preview. A throw leaves every piece
  /// of session state intact — the display did not move, so the record of how
  /// to move it back is still the truth.
  ///
  /// A failed COMMIT deliberately leaves the countdown armed: the user asked to
  /// keep a mode that could not be made permanent, and falling back to the mode
  /// they can definitely see is the safe way to end that.
  private func resolve(
    applying mode: DisplayMode, to displayID: CGDirectDisplayID,
    success: ModePreviewOutcome
  ) -> ModePreviewOutcome {
    do {
      try configurator.apply(mode, to: displayID, scope: .session)
    } catch let error as DisplayConfigError {
      lastOutcome = .failed(error)
      return .failed(error)
    } catch {
      let error = DisplayConfigError(cgErrorCode: -1)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    outstanding = nil
    remaining = 0
    countdownArmed = false
    lastOutcome = success
    return success
  }
}
