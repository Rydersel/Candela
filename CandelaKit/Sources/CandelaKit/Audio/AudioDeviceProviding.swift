/// What Candela asks CoreAudio (D4): the default output device, whether it sets
/// its own volume, and when it changes. Behind a protocol so the routing decisions
/// are testable against a fake.
public struct AudioOutputDevice: Sendable, Equatable {
  public let id: UInt32
  public let name: String
  /// True when `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` is settable
  /// on the output scope, which releases the volume keys to the system.
  public let canSetOwnVolume: Bool

  public init(id: UInt32, name: String, canSetOwnVolume: Bool) {
    self.id = id
    self.name = name
    self.canSetOwnVolume = canSetOwnVolume
  }
}

public protocol AudioDeviceProviding: Sendable {
  /// May serve a snapshot that refreshes on device-change events: install the
  /// change handler first, or a repeated read can stay stale for the object's
  /// lifetime.
  func defaultOutputDevice() -> AudioOutputDevice?
  /// Names of every device with output channels; same freshness contract as
  /// `defaultOutputDevice()`. No production callers: volume-slider gating reads the
  /// DDC capabilities string instead (D24).
  func outputDeviceNames() -> [String]
  /// Fires on default-output-device change (any thread). Pass nil to clear.
  func setOnDefaultOutputChange(_ handler: (@Sendable () -> Void)?)
}
