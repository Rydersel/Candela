import CandelaKit
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let brightnessUp = Self("brightnessUp")
  static let brightnessDown = Self("brightnessDown")
  static let contrastUp = Self("contrastUp")
  static let contrastDown = Self("contrastDown")
  static let volumeUp = Self("volumeUp")
  static let volumeDown = Self("volumeDown")
  static let mute = Self("mute")
}

/// Custom-shortcut dispatch (fork KeyboardShortcutsManager): handlers are
/// registered once and guard on the CURRENT mode at fire time.
///
/// These are Carbon hotkeys, not the CGEvent tap — they work without the
/// Accessibility grant, which is why `KeyModePolicy.requiresAccessibility`
/// ignores the custom modes.
///
/// **Task 12 divergence from fork parity.** The fork keeps every hotkey
/// REGISTERED regardless of mode and only guards at fire time. A Carbon hotkey
/// registration is exclusive and system-wide, so an assigned shortcut whose
/// mode is off still swallows its key combination in every other app while
/// doing nothing here — an invisible dead zone with no control that explains
/// it. `syncRegistration()` makes registration follow the mode instead. The
/// fire-time guards below are KEPT as a backstop: a `defaults write` to a mode
/// pref bypasses the pane and therefore this sync.
@MainActor
final class ShortcutManager {
  private let model: AppModel
  private let executor: KeyActionExecutor

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  init(model: AppModel, executor: KeyActionExecutor) {
    self.model = model
    self.executor = executor

    KeyboardShortcuts.onKeyDown(for: .brightnessUp) { [weak self] in self?.brightness(isUp: true) }
    KeyboardShortcuts.onKeyDown(for: .brightnessDown) { [weak self] in self?.brightness(isUp: false) }
    KeyboardShortcuts.onKeyDown(for: .contrastUp) { [weak self] in self?.contrast(isUp: true) }
    KeyboardShortcuts.onKeyDown(for: .contrastDown) { [weak self] in self?.contrast(isUp: false) }
    KeyboardShortcuts.onKeyDown(for: .volumeUp) { [weak self] in self?.volume(isUp: true) }
    KeyboardShortcuts.onKeyDown(for: .volumeDown) { [weak self] in self?.volume(isUp: false) }
    KeyboardShortcuts.onKeyUp(for: .volumeUp) { [weak self] in self?.volumeKeyUp() }
    KeyboardShortcuts.onKeyUp(for: .volumeDown) { [weak self] in self?.volumeKeyUp() }
    // Fork parity: mute has key-down only.
    KeyboardShortcuts.onKeyDown(for: .mute) { [weak self] in self?.mute() }

    // Registration must match the persisted modes from the first launch
    // onward, not only after the pane is visited.
    Self.syncRegistration()
  }

  /// Shortcut names whose registration follows `keyboardBrightness`.
  private static let brightnessNames: [KeyboardShortcuts.Name] = [
    .brightnessUp, .brightnessDown, .contrastUp, .contrastDown,
  ]

  /// …and `keyboardVolume`.
  private static let volumeNames: [KeyboardShortcuts.Name] = [.volumeUp, .volumeDown, .mute]

  /// Registers each family's hotkeys when its mode fires custom shortcuts and
  /// unregisters them otherwise, so a combination assigned under a mode that is
  /// now off goes back to the rest of the system.
  ///
  /// Static because the only other caller — the Keyboard pane — has no
  /// reference to the instance (`StatusItemController` holds it privately), and
  /// there is nothing instance-scoped to do: `KeyboardShortcuts`' registry is
  /// global, and the modes are read from prefs.
  ///
  /// Safe against the recorder: `Recorder` suspends dispatch with
  /// `KeyboardShortcuts.isPaused` while recording, never `enable`/`disable`, so
  /// it cannot silently re-register a disabled name. A shortcut recorded while
  /// its name is disabled is stored but stays unregistered
  /// (`registerIfNeeded(for:)` consults `disabledNames`) — which cannot happen
  /// from the pane anyway, since the recorders are only shown for the modes
  /// that enable them.
  static func syncRegistration() {
    let prefs = DisplayPrefs(persistenceKey: "app")
    setRegistered(KeyModePolicy.firesCustomShortcuts(prefs.keyboardBrightness), brightnessNames)
    setRegistered(KeyModePolicy.firesCustomShortcuts(prefs.keyboardVolume), volumeNames)
  }

  private static func setRegistered(_ registered: Bool, _ names: [KeyboardShortcuts.Name]) {
    if registered {
      KeyboardShortcuts.enable(names)
    } else {
      KeyboardShortcuts.disable(names)
    }
  }

  private func brightness(isUp: Bool) {
    guard KeyModePolicy.firesCustomShortcuts(prefs.keyboardBrightness) else { return }
    // Fork KeyboardShortcutsManager passes useFineScale straight through as
    // isSmallIncrement (no modifier inversion on the shortcut path).
    executor.execute(
      .stepBrightness(isUp: isUp, isFine: prefs.useFineScaleBrightness, scope: .affected),
      isFresh: true
    )
  }

  private func contrast(isUp: Bool) {
    guard KeyModePolicy.firesCustomShortcuts(prefs.keyboardBrightness) else { return }
    executor.execute(.stepContrast(isUp: isUp, isFine: prefs.useFineScaleBrightness), isFresh: true)
  }

  private func volume(isUp: Bool) {
    guard KeyModePolicy.firesCustomShortcuts(prefs.keyboardVolume) else { return }
    executor.execute(.stepVolume(isUp: isUp, isFine: prefs.useFineScaleVolume), isFresh: true)
  }

  private func volumeKeyUp() {
    guard KeyModePolicy.firesCustomShortcuts(prefs.keyboardVolume) else { return }
    executor.execute(.volumeKeyUp, isFresh: true)
  }

  private func mute() {
    guard KeyModePolicy.firesCustomShortcuts(prefs.keyboardVolume) else { return }
    executor.execute(.toggleMute, isFresh: true)
  }
}
