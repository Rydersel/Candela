/// The tunable DDC command set (fork: Command.brightness / .audioSpeakerVolume
/// / .contrast). `rawValue` doubles as the per-command pref-key component
/// ("curveDDC.volume.<persistenceKey>"), so renaming a case is a prefs
/// migration — don't.
public enum DDCCommand: String, Sendable, CaseIterable, Equatable {
  case brightness
  case volume
  case contrast

  public var code: UInt8 {
    switch self {
    case .brightness: VCP.brightness
    case .volume: VCP.audioSpeakerVolume
    case .contrast: VCP.contrast
    }
  }
}
