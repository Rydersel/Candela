import AppKit
import CandelaKit

/// The engine's one user-facing choice, as an `NSAlert`. AppKit island behind
/// `EngineAlerting` so `GammaInterferenceMonitor` never touches AppKit.
///
/// The buttons name their actions instead of answering "OK/Cancel", and the
/// recommended harmless action is the default button. DIVERGENCE from the fork:
/// MonitorControl makes "I'll quit the other app" the default and buries the fix
/// in the second button.
@MainActor
final class EngineAlerts: EngineAlerting {
  func offerShadeFallback(displayName: String, onAccept: @escaping @MainActor () -> Void) {
    // Deferred to the next run-loop turn: the monitor is called inline from the
    // synchronous software-dimming leg of a drag or keypress, and a modal run
    // loop must never start from inside it. The monitor's own state has already
    // transitioned synchronously, so nothing here races it.
    Task { @MainActor in
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Another app is adjusting this display's colors"
      alert.informativeText = """
      Software dimming and apps like f.lux fight over the display's gamma table. \
      Candela can switch “\(displayName)” to shade-based dimming instead.
      """
      alert.addButton(withTitle: "Use Shade Dimming")
      let notNow = alert.addButton(withTitle: "Not Now")
      notNow.keyEquivalent = "\u{1b}" // Escape dismisses without switching
      // LSUIElement app: without this the modal can open behind whatever the
      // user is actually looking at.
      NSApp.activate()
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      onAccept()
    }
  }
}
