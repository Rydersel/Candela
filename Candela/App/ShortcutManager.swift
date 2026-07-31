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
/// registered once and guard on the CURRENT mode at fire time, so the Keyboard
/// pane's mode popup needs no un/re-registration plumbing.
///
/// These are Carbon hotkeys, not the CGEvent tap — they work without the
/// Accessibility grant, which is why `KeyModePolicy.requiresAccessibility`
/// ignores the custom modes.
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
