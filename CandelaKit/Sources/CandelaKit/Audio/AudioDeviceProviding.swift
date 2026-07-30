/// The three audio questions Candela asks (D4): what is the default output
/// device, can it set its own volume, and when does it change. Behind a
/// protocol so the routing decisions are fake-testable — CoreAudio is
/// hardware truth.
public struct AudioOutputDevice: Sendable, Equatable {
  public let id: UInt32
  public let name: String
  /// Whether macOS can drive this device's volume itself
  /// (kAudioHardwareServiceDeviceProperty_VirtualMainVolume settable on the
  /// output scope). True → volume keys are released to the system.
  public let canSetOwnVolume: Bool

  public init(id: UInt32, name: String, canSetOwnVolume: Bool) {
    self.id = id
    self.name = name
    self.canSetOwnVolume = canSetOwnVolume
  }
}

public protocol AudioDeviceProviding: Sendable {
  func defaultOutputDevice() -> AudioOutputDevice?
  /// Fires on default-output-device change (any thread). Pass nil to clear.
  func setOnDefaultOutputChange(_ handler: (@Sendable () -> Void)?)
}
