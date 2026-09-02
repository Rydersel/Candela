import IOKit.hidsystem

/// Decodes the `data1` payload of an `NX_SYSDEFINED` aux-control event
/// (subtype `NX_SUBTYPE_AUX_CONTROL_BUTTONS`) into a `MediaKeyPress`.
///
/// Lives in the engine rather than the event-tap island so it can be tested:
/// the app target has no test target.
///
/// Layout: bits 16...31 are the `NX_KEYTYPE_*` code, bits 8...15 the key state
/// (`0xA` down, `0xB` up), bit 0 the auto-repeat flag.
public enum AuxControlDecoder {
  /// `nil` when the payload names a key Candela does not route, such as caps
  /// lock or eject. Modifiers come from the event's flags, not from `data1`.
  public static func decode(data1: Int64, modifiers: KeyModifiers) -> MediaKeyPress? {
    let keycode = Int32((data1 & 0xFFFF_0000) >> 16)
    let keyFlags = data1 & 0x0000_FFFF
    let key: MediaKey
    switch keycode {
    case NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
    case NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
    case NX_KEYTYPE_SOUND_UP: key = .volumeUp
    case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
    case NX_KEYTYPE_MUTE: key = .mute
    default: return nil
    }
    return MediaKeyPress(
      key: key,
      isPressed: ((keyFlags & 0xFF00) >> 8) == 0xA,
      isRepeat: (keyFlags & 0x1) == 0x1,
      modifiers: modifiers
    )
  }
}
