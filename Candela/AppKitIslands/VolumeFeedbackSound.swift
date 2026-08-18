//  The feedback-sound behaviour (the system blip's path, the global "play
//  feedback" pref) follows MonitorControl (MIT); both are facts about macOS.
//  The code is Candela's own.

import AVFoundation
import Foundation

/// Fork AppDelegate.playVolumeChangedSound: the system volume-feedback blip,
/// honoring the user's "Play feedback when volume is changed" Sound setting.
@MainActor
final class VolumeFeedbackSound {
  /// Retained across the async playback (a local would deallocate mid-play).
  private var player: AVAudioPlayer?

  func play() {
    guard Self.feedbackEnabled() else { return }
    let url = URL(
      fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    )
    player = try? AVAudioPlayer(contentsOf: url)
    player?.volume = 1
    player?.play()
  }

  /// Fork parity: the setting lives in another domain, so the global prefs
  /// plist is parsed directly (`UserDefaults.standard` won't surface it).
  private static func feedbackEnabled() -> Bool {
    let path = NSString(string: "~/Library/Preferences/.GlobalPreferences.plist").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
          as? [String: Any]
    else { return false }
    return plist["com.apple.sound.beep.feedback"] as? Int == 1
  }
}
