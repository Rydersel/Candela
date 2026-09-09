import CandelaKit
import Foundation
import Observation
import os
import Testing

@Suite("Default audio output observation", .timeLimit(.minutes(1))) @MainActor
struct AudioOutputObservationTests {
  private let speakers = AudioOutputDevice(id: 1, name: "Speakers", canSetOwnVolume: true)
  private let monitor = AudioOutputDevice(id: 2, name: "Monitor", canSetOwnVolume: false)

  private func model(_ audio: SignalingAudio) -> AppModel {
    AppModel(shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(),
             audioDevices: audio, safeMode: true)
  }

  // Removing the publication from the real listener hop must fail even when
  // nothing else in AppModel changes. Each callback is completed before checking.
  @Test func initialOutputChangesRemovalAndReturnNotifyObservers() async {
    let audio = SignalingAudio()
    let model = model(audio)
    let (events, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    var callbacks = events.makeAsyncIterator()
    model.startObservingAudioOutput { continuation.yield(()) }
    #expect(model.defaultAudioOutput == nil)

    let renamed = AudioOutputDevice(id: 2, name: "Monitor renamed", canSetOwnVolume: false)
    let native = AudioOutputDevice(id: 2, name: "Monitor renamed", canSetOwnVolume: true)
    let cases: [(AudioOutputDevice?, Bool)] = [
      (nil, false), (speakers, true), (monitor, true), (nil, true),
      (speakers, true), (speakers, false), (renamed, true), (native, true),
    ]
    for (output, shouldNotify) in cases {
      let notified = OSAllocatedUnfairLock(initialState: false)
      withObservationTracking {
        _ = model.defaultAudioOutput
      } onChange: {
        notified.withLock { $0 = true }
      }
      await Task.detached { audio.publish(output) }.value
      _ = await callbacks.next()
      #expect(model.defaultAudioOutput == output)
      #expect(notified.withLock { $0 } == shouldNotify)
    }
  }

  // UI reads must never initiate a cold HAL fetch. The initial provider result
  // arrives through the same callback as subsequent route changes.
  @Test func constructionAndUIReadsWaitForInitialPublication() async {
    let audio = SignalingAudio()
    let model = model(audio)
    let (events, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    var callbacks = events.makeAsyncIterator()
    model.startObservingAudioOutput { continuation.yield(()) }
    _ = model.defaultAudioOutput
    #expect(audio.readCount == 0)
    let initialOutput = monitor
    await Task.detached { audio.publish(initialOutput) }.value
    _ = await callbacks.next()
    #expect(model.defaultAudioOutput?.name == "Monitor")
  }

  // A key arriving before the listener's main-actor hop must still ask the
  // provider. Replacing audioMatchingDisplays' live read with UI state breaks it.
  @Test func keyExecutionReadsProviderBeforeUIReceivesRouteChange() async {
    let audio = SignalingAudio()
    let model = model(audio)
    let (events, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    var callbacks = events.makeAsyncIterator()
    model.startObservingAudioOutput { continuation.yield(()) }
    audio.publish(speakers)
    _ = await callbacks.next()

    do {
      // No suspension while this process-local test preference is changed.
      let previous = UserDefaults.standard.object(forKey: "multiKeyboardVolume")
      defer {
        if let previous { UserDefaults.standard.set(previous, forKey: "multiKeyboardVolume") }
        else { UserDefaults.standard.removeObject(forKey: "multiKeyboardVolume") }
      }
      DisplayPrefs(persistenceKey: "app").multiKeyboardVolume = .audioDeviceNameMatching
      audio.publish(monitor)
      let readsBeforePress = audio.readCount
      KeyActionExecutor(model: model, hud: nil).execute(.stepVolume(isUp: true, isFine: false))
      #expect(audio.readCount == readsBeforePress + 1)
      #expect(model.defaultAudioOutput?.name == "Speakers")
    }
    _ = await callbacks.next()
    #expect(model.defaultAudioOutput?.name == "Monitor")
  }
}

/// Replaces only CoreAudio I/O. Real app callback registration, main-actor
/// delivery and Observation remain under test. Locking permits background events.
private final class SignalingAudio: AudioDeviceProviding, Sendable {
  private struct State {
    var device: AudioOutputDevice?
    var handler: (@Sendable () -> Void)?
    var reads = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  var readCount: Int { state.withLock { $0.reads } }
  func defaultOutputDevice() -> AudioOutputDevice? {
    state.withLock { $0.reads += 1; return $0.device }
  }
  func outputDeviceNames() -> [String] { [] }
  func setOnDefaultOutputChange(_ handler: (@Sendable () -> Void)?) {
    state.withLock { $0.handler = handler }
  }
  func publish(_ device: AudioOutputDevice?) {
    let handler = state.withLock { state in
      state.device = device
      return state.handler
    }
    handler?()
  }
}
