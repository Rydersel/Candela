/// The media keys Candela can route.
public enum MediaKey: Sendable, Hashable {
  case brightnessUp
  case brightnessDown
  case volumeUp
  case volumeDown
  case mute
}

/// Modifier flags on a media-key press. The event tap normalizes NSEvent flags
/// down to exactly these four, so `== [.option]` comparisons are safe.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let shift = KeyModifiers(rawValue: 1 << 0)
  public static let control = KeyModifiers(rawValue: 1 << 1)
  public static let option = KeyModifiers(rawValue: 1 << 2)
  public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// A single media-key event as delivered by the event tap.
public struct MediaKeyPress: Sendable {
  public let key: MediaKey
  public let isPressed: Bool // true on keyDown, false on keyUp
  public let isRepeat: Bool
  public let modifiers: KeyModifiers

  public init(key: MediaKey, isPressed: Bool, isRepeat: Bool, modifiers: KeyModifiers) {
    self.key = key
    self.isPressed = isPressed
    self.isRepeat = isRepeat
    self.modifiers = modifiers
  }
}

/// Routing preferences consulted by `KeyRouter`.
public struct KeyRouterConfig: Sendable {
  /// Inverts coarse/fine meaning for brightness keys (fork: useFineScaleBrightness).
  public var useFineScaleBrightness: Bool
  /// Inverts coarse/fine meaning for volume keys (fork: useFineScaleVolume).
  public var useFineScaleVolume: Bool

  public init(useFineScaleBrightness: Bool = false, useFineScaleVolume: Bool = false) {
    self.useFineScaleBrightness = useFineScaleBrightness
    self.useFineScaleVolume = useFineScaleVolume
  }
}
