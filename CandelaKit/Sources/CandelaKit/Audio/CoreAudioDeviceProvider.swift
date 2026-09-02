import CoreAudio
import Foundation
import os

/// Minimal CoreAudio wrapper: SimplyCoreAudio is archived, and this is all
/// Candela needs from it.
public final class CoreAudioDeviceProvider: AudioDeviceProviding, Sendable {
  private let handlerLock = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
  private let listenerInstalled = OSAllocatedUnfairLock(initialState: false)
  private let listenerQueue = DispatchQueue(label: "com.rydersel.Candela.audio-listener")
  /// Change-refreshed snapshot: the blocking HAL read runs on the listener queue at
  /// change time (and lazily on the first read), never on the MainActor re-arm path,
  /// because coreaudiod is most likely to stall exactly when the default-output
  /// listener fires. The "recompute at key time" rule governs the display MATCH SET, not
  /// the device fetch. Outer nil = never fetched; inner nil = no device.
  private let snapshot = OSAllocatedUnfairLock<AudioOutputDevice??>(initialState: AudioOutputDevice??.none)
  /// Second change-refreshed snapshot, same rules as `snapshot`: the device
  /// LIST changes on its own events (plug/unplug), not on default-output
  /// changes, so it gets its own listener. nil = never fetched.
  private let outputNames = OSAllocatedUnfairLock<[String]?>(initialState: nil)

  public init() {}

  public func defaultOutputDevice() -> AudioOutputDevice? {
    if let fetched = snapshot.withLock({ $0 }) { return fetched }
    let fresh = readDefaultOutputDevice()
    snapshot.withLock { $0 = .some(fresh) }
    return fresh
  }

  public func outputDeviceNames() -> [String] {
    if let cached = outputNames.withLock({ $0 }) { return cached }
    let fresh = readOutputDeviceNames()
    outputNames.withLock { $0 = fresh }
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
    // Prime off the caller's thread so the first defaultOutputDevice() never pays
    // a HAL round-trip on the MainActor.
    listenerQueue.async { [weak self] in
      guard let self else { return }
      let fresh = self.readDefaultOutputDevice()
      self.snapshot.withLock { $0 = .some(fresh) }
      let names = self.readOutputDeviceNames()
      self.outputNames.withLock { $0 = names }
    }
    // Device-list listener: refreshes the output-name snapshot only. It
    // deliberately does NOT notify the handler, which re-arms the key tap on a rule
    // that depends on the DEFAULT output.
    var deviceListAddress = Self.deviceListAddress
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, listenerQueue
    ) { [weak self] _, _ in
      guard let self else { return }
      let names = self.readOutputDeviceNames()
      self.outputNames.withLock { $0 = names }
    }
    var address = Self.defaultOutputAddress
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue
    ) { [weak self] _, _ in
      guard let self else { return }
      // Snapshot on the listener queue BEFORE notifying, so the MainActor re-arm
      // reads the cache instead of blocking on HAL. The read stays OUTSIDE the lock:
      // holding it across ~ms of coreaudiod IPC would stall any concurrent reader.
      let fresh = self.readDefaultOutputDevice()
      self.snapshot.withLock { $0 = .some(fresh) }
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

  /// Every device with at least one output channel, by name. A display appears here
  /// only when its EDID declares an audio sink, the closest passive signal macOS
  /// offers for "this panel can play sound".
  private func readOutputDeviceNames() -> [String] {
    var address = Self.deviceListAddress
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    ) == noErr else { return [] }
    return ids.filter(hasOutputChannels).compactMap(deviceName)
  }

  private func hasOutputChannels(_ deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
      return false
    }
    let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
    return list.contains { $0.mNumberChannels > 0 }
  }

  private static let deviceListAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

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
    // kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc') is declared in
    // AudioToolbox's deprecated AudioHardwareService.h, spelled literally here to
    // keep the imports at CoreAudio alone.
    // DIVERGENCE (deliberate, stricter than the fork): the fork only checks that the
    // property EXISTS; Candela also requires it SETTABLE, since a device exposing
    // 'vmvc' read-only cannot set its own volume, so its keys stay watched.
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
