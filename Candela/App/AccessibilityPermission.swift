import AppKit
// @preconcurrency: `kAXTrustedCheckOptionPrompt` is imported as a mutable C
// global (extern CFStringRef), which Swift 6 otherwise refuses to reference.
// It is de-facto immutable — set once at framework load.
@preconcurrency import ApplicationServices
import Foundation
import Observation

/// Tracks the Accessibility (TCC) grant the media-key event tap needs.
///
/// Polling exists because each ad-hoc re-sign silently drops the grant and
/// there is no notification API for TCC changes: a 2-second timer re-checks
/// while the grant is missing, stops itself once granted, then fires the
/// `onGrant` callback so the caller can start the tap.
@MainActor @Observable
final class AccessibilityPermission {
  private(set) var isGranted: Bool

  @ObservationIgnored private var pollTimer: Timer?
  @ObservationIgnored private var pendingOnGrant: (@MainActor () -> Void)?

  init() {
    isGranted = AXIsProcessTrustedWithOptions(nil)
  }

  /// Shows the system Accessibility prompt when the grant is missing. No
  /// NSAlert — the system prompt plus the panel banner replace the fork's
  /// modal (spec §6).
  func promptIfNeeded() {
    guard !isGranted else { return }
    // Fork precedent (MediaKeyTapManager.readPrivileges): the prompt key is
    // the unmanaged constant, not a string literal.
    let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
    isGranted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
  }

  /// Re-checks the grant every 2 seconds until it appears; then sets
  /// `isGranted`, invalidates the timer, and calls `onGrant`.
  func startPolling(onGrant: @escaping @MainActor () -> Void) {
    guard !isGranted else {
      onGrant()
      return
    }
    pollTimer?.invalidate()
    pendingOnGrant = onGrant
    // The timer body is `@Sendable`-typed but provably runs on the main run
    // loop (added to `RunLoop.main` below). `.common` mode matters: the grant
    // must be noticed (and the panel banner cleared) even while a menu
    // tracking session holds the run loop.
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.checkGrant()
      }
    }
    pollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  static func openSystemSettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    )
  }

  private func checkGrant() {
    guard AXIsProcessTrustedWithOptions(nil) else { return }
    isGranted = true
    pollTimer?.invalidate()
    pollTimer = nil
    let onGrant = pendingOnGrant
    pendingOnGrant = nil
    onGrant?()
  }
}
