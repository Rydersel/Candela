import Foundation
import os

/// What a stranded-mute recovery achieved, as evidence rather than as a request.
///
/// Only `.unmuted` licenses a surface to say the display is no longer muted.
/// The rest are the honest ways the attempt can end with the panel still
/// silent, and they are distinguished because a person can act on the
/// difference: HDR is theirs to turn off, and the other two are theirs to
/// retry.
public enum StrandedMuteOutcome: Sendable, Equatable {
  /// Nothing to undo.
  case notMuted
  /// The unmute was sent, the wire settled, and the register was still free
  /// afterwards.
  case unmuted
  /// The display is in HDR, where DDC goes nowhere. Nothing was sent.
  case blockedByHDR
  /// Nothing here can say whether the panel heard it, so the mute stands.
  case unconfirmed
  /// A recovery on this display is already running; this call did nothing.
  case alreadyRunning
}

/// The recovery from a hardware mute (D29 rule 3): the sequence behind the
/// settings banner's unmute button.
///
/// It lives here rather than in the pane because the ORDER is the rule, and a
/// pane cannot be tested (there is no app test target, D21). The per-display
/// reset runs the same discipline inline for its own reasons: it must also
/// retire the mute strategy, and it may CHANGE the display's HDR because
/// clearing settings is what that button is for. This one may not: it promises
/// an unmute, so it measures HDR and reports rather than dropping it.
public enum StrandedMuteRecovery {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "mute-recovery")

  /// One recovery per volume queue. The guard is load-bearing now in a way it
  /// was not when this ran synchronously: there is an await between the muted
  /// test and the unmute, so a second click lands inside the window and would
  /// drive a second unmute pair onto the wire.
  @MainActor private static var inFlight: Set<ObjectIdentifier> = []

  /// - Parameters:
  ///   - reopenRoutes: clears whatever closed the ordinary routes back (the
  ///     availability prefs). Called FIRST and unconditionally, D29 rule 2:
  ///     a recovery that cannot reach the panel today must still leave the
  ///     slider and the keys working for the moment it can.
  @MainActor
  public static func recover(
    volume: DDCValueController,
    hdrOwner: BrightnessController,
    settlePause: Duration = .milliseconds(400),
    reopenRoutes: () -> Void
  ) async -> StrandedMuteOutcome {
    let token = ObjectIdentifier(volume)
    guard !inFlight.contains(token) else { return .alreadyRunning }
    inFlight.insert(token)
    defer { inFlight.remove(token) }

    reopenRoutes()
    guard volume.command == .volume, volume.isMuted else { return .notMuted }

    // Measured, and it also drops the wire's duplicate memos: the unmute below
    // is exactly the write that a memo built through a closed HDR window would
    // suppress and certify as applied.
    switch await hdrOwner.hdrWriteWindow() {
    case .locked:
      log.error(
        "stranded-mute recovery on display \(hdrOwner.displayID, privacy: .public): the display is in HDR, so no unmute was sent and it stays muted"
      )
      return .blockedByHDR
    case .unknown:
      log.error(
        "stranded-mute recovery on display \(hdrOwner.displayID, privacy: .public): the HDR state is not this call's to vouch for, so no unmute was sent and it stays muted"
      )
      return .unconfirmed
    case .open:
      break
    }

    _ = volume.toggleMute()
    // `toggleMute` refuses silently while the volume command is unavailable,
    // and returns the mute flag unchanged when it does. Unreachable as long as
    // `reopenRoutes` clears the availability prefs first, which is precisely
    // why it is checked here: the failure mode of that contract being broken is
    // a recovery that sends nothing, settles an empty queue and reports the
    // display unmuted, which is this bug again by another road.
    guard !volume.isMuted else {
      log.error(
        "stranded-mute recovery on display \(hdrOwner.displayID, privacy: .public): the unmute was refused before it reached the wire, so the routes back were not open when it ran"
      )
      return .unconfirmed
    }
    // This queue only. The claim being made is about the unmute, and the
    // brightness and contrast queues are neither part of it nor blocked by it;
    // the reset's restore settles the whole wire because it is about to LOCK
    // the register, which is a different obligation.
    let settled = await WireQuiescence.settle(
      [volume], betweenRounds: settlePause, isWireOpen: { volume.isWireOpen }
    )
    // The second read is the one the ACK cannot replace. A submit is queued
    // rather than sent, so HDR engaging while it was in flight swallows it on
    // the panel while the applier reports success, and on a write-only display
    // that is the end of the evidence.
    let windowAfter = await hdrOwner.hdrWriteWindow()
    guard settled, windowAfter == .open else {
      volume.reassertUnconfirmedMute()
      log.error(
        "stranded-mute recovery on display \(hdrOwner.displayID, privacy: .public): the unmute could not be confirmed as applied (settled=\(settled, privacy: .public)), so the mute was left standing"
      )
      return .unconfirmed
    }
    return .unmuted
  }
}
