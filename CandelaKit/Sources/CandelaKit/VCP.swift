/// VESA MCCS VCP feature codes used by Candela.
public enum VCP {
  public static let brightness: UInt8 = 0x10
  public static let contrast: UInt8 = 0x12
  public static let audioSpeakerVolume: UInt8 = 0x62
  /// Fork name kept for greppability; per spec 1 = mute, 2 = unmute.
  public static let audioMuteScreenBlank: UInt8 = 0x8D
}
