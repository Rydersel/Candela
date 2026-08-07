/// VESA MCCS VCP feature codes used by Candela.
public enum VCP {
  public static let brightness: UInt8 = 0x10
  public static let contrast: UInt8 = 0x12
  public static let audioSpeakerVolume: UInt8 = 0x62
  /// Fork name kept for greppability; per spec 1 = mute, 2 = unmute.
  public static let audioMuteScreenBlank: UInt8 = 0x8D
  /// DPM power mode (MCCS D6). 0x01 on, 0x04 off. Write-only on the MAG, so
  /// neither the value's acceptance nor its effect can be read back there; the
  /// Dell advertises `D6(01 04 05)` — no dedicated standby code — which is why
  /// off is 0x04 rather than a standby value (spec §3, hardware-checklist item).
  public static let powerMode: UInt8 = 0xD6
}
