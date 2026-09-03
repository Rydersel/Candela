//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from
//  Support/AppDelegate.swift (`playVolumeChangedSound`, `getSystemSettings`).

import AVFoundation
import Foundation

/// Fork AppDelegate.playVolumeChangedSound: the system volume-feedback blip,
/// honoring the user's "Play feedback when volume is changed" Sound setting.
@MainActor
final class VolumeFeedbackSound {
  private static let soundURL = URL(
    fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
  )

  /// Built once and retained: this fires on every volume keypress, and the fork's
  /// per-press player re-read and re-decoded the file each time. A local would
  /// also deallocate mid-play.
  private lazy var player: AVAudioPlayer? = {
    let player = try? AVAudioPlayer(contentsOf: Self.soundURL)
    player?.volume = 1
    player?.prepareToPlay()
    return player
  }()

  func play() {
    guard Self.feedbackEnabled(), let player else { return }
    // A press during the previous blip restarts it rather than being swallowed:
    // `play()` on a playing player is a no-op.
    player.currentTime = 0
    player.play()
  }

  /// The global domain is in every app's defaults search list, the same route
  /// `_HIHideMenuBar` is read by. The fork parsed
  /// `~/Library/Preferences/.GlobalPreferences.plist` per keypress instead, which
  /// also reads behind cfprefsd's cache.
  private static func feedbackEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: "com.apple.sound.beep.feedback")
  }
}
