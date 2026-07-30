import CoreAudio
import Foundation
import os

/// Minimal CoreAudio wrapper (D4) — SimplyCoreAudio is archived, and this is
/// the whole surface Candela needs from it.
public final class CoreAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
  // @unchecked: the mutable state (change handler + device snapshot) lives
  // behind OSAllocatedUnfairLocks; the CoreAudio property API is thread-safe C.
  private let handlerLock = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
  private let listenerInstalled = OSAllocatedUnfairLock(initialState: false)
  private let listenerQueue = DispatchQueue(label: "com.rydersel.Candela.audio-listener")
  /// Change-refreshed snapshot (concurrency F7): the blocking HAL read runs
  /// on the listener queue at change time (and lazily on first read), never
  /// on the MainActor re-arm path — coreaudiod is most likely to stall
  /// exactly when the default-output listener fires. D4's "recompute at key
  /// time" mandate concerns the display MATCH SET, not the device fetch:
  /// matching against a change-refreshed snapshot still fixes the fork's
  /// stale-cache defect. Outer nil = never fetched; inner nil = no device.
  private let snapshot = OSAllocatedUnfairLock<AudioOutputDevice??>(initialState: AudioOutputDevice??.none)

  public init() {}

  public func defaultOutputDevice() -> AudioOutputDevice? {
    if let fetched = snapshot.withLock({ $0 }) { return fetched }
    let fresh = readDefaultOutputDevice()
    snapshot.withLock { $0 = .some(fresh) }
    return fresh
  }

  public func setOnDefaultOutputChange(_ handler: (@Sendable () -> Void)?) {
    handlerLock.withLock { $0 = handler }
    // App-lifetime listener, installed once on the first non-nil handler
    // (fork parity: its observer is never removed either).
    let install = listenerInstalled.withLock { installed -> Bool in
      guard !installed, handler != nil else { return false }
      installed = true
      return true
    }
    guard install else { return }
    var address = Self.defaultOutputAddress
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue
    ) { [weak self] _, _ in
      guard let self else { return }
      // Snapshot on the listener queue BEFORE notifying, so the notified
      // MainActor re-arm reads the cache instead of blocking on HAL.
      self.snapshot.withLock { $0 = .some(self.readDefaultOutputDevice()) }
      self.handlerLock.withLock { $0 }?()
    }
  }

  private func readDefaultOutputDevice() -> AudioOutputDevice? {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = Self.defaultOutputAddress
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return AudioOutputDevice(
      id: deviceID,
      name: deviceName(deviceID) ?? "",
      canSetOwnVolume: canSetVolume(deviceID)
    )
  }

  private static let defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  private func deviceName(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
      return nil
    }
    return name?.takeRetainedValue() as String?
  }

  private func canSetVolume(_ deviceID: AudioObjectID) -> Bool {
    // kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc') is
    // declared in AudioToolbox's deprecated AudioHardwareService.h — spelled
    // literally to keep the import surface at CoreAudio alone.
    // DIVERGENCE (deliberate, stricter than the fork — fork-parity F3): the
    // fork's SimplyCoreAudio canSetVirtualMainVolume(scope: .output) only
    // checks the property EXISTS; Candela additionally requires it to be
    // SETTABLE — a device exposing 'vmvc' read-only cannot actually set its
    // own volume, so its keys stay watched by Candela.
    var address = AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(0x766D_7663), // 'vmvc'
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
    return settable.boolValue
  }
}
