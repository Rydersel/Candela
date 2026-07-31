//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Based on MediaKeyTap by Nicholas Hurden (MIT)

import AppKit
import CandelaKit
import CoreGraphics
import os

/// CGEventTap island that intercepts brightness/volume media keys and the
/// F14/F15 + dedicated-brightness keyDown codes, delivering decoded
/// `MediaKeyPress` values to `onPress`. Modernized transplant of the
/// MediaKeyTap internals the MonitorControl fork used.
///
/// Threading model (hammered out for Swift 6 strict concurrency):
/// - The public API (`start`/`stop`/`update`/`isRunning`) is `@MainActor`.
/// - The tap callback runs on a dedicated `Thread` ("MediaKeyEventTap")
///   spinning `CFRunLoopRun()`. It never hops to the main thread — the
///   original library's `DispatchQueue.main.sync` blocked the tap thread for
///   the whole of any menu-tracking session, tripping the tap timeout.
/// - `WatchConfig` crosses to the tap thread through an
///   `OSAllocatedUnfairLock<WatchConfig>` (same lock-not-actor pattern as
///   `BrightnessWriteCoalescer`'s submission slot: the callback must read it
///   synchronously, with no executor hop).
/// - The CF runtime objects (`CFMachPort`/`CFRunLoopSource`/`CFRunLoop`) live
///   in a second lock-protected, nonisolated box — not `@MainActor` stored
///   properties — because (1) the run loop can only be captured via
///   `CFRunLoopGetCurrent()` on the tap thread itself, so it is necessarily
///   written off-main, and (2) the `tapDisabledByTimeout` re-enable must read
///   the mach port inside the nonisolated callback (the port doesn't exist
///   until `tapCreate` returns, after the callback closure is built).
/// - Only the `Sendable` `MediaKeyPress` escapes the callback; `onPress` is
///   invoked on the tap thread and the consumer hops actors itself.
@MainActor
final class MediaKeyEventTap {
  struct WatchConfig: Sendable {
    /// Empty set = watch nothing (all keys pass through to the system).
    var watchedKeys: Set<MediaKey>
    /// Intercept F14/F15 (keycodes 107/113) as brightness keys.
    var interceptAlternateBrightnessKeys: Bool
  }

  enum TapError: Error { case creationFailed }

  /// The Swift side of the C-callback trampoline. `@Sendable` both for the
  /// hop onto the tap thread and so the closure literal in `start()` is
  /// nonisolated rather than inheriting `@MainActor`.
  private typealias EventTapCallback = @Sendable @convention(block) (CGEventType, CGEvent) -> CGEvent?

  /// CF objects backing a live tap. All three CF types are thread-safe; the
  /// lock (accessed via `withLockUnchecked` because they are not `Sendable`
  /// in Swift's eyes) serializes the *references*: main actor writes
  /// port+source after `tapCreate`, the tap thread writes its run loop just
  /// before `CFRunLoopRun()`, and the callback and `stop()`/`deinit` read
  /// from the same box.
  ///
  /// The trampoline block is deliberately NOT stored here: the tap thread's
  /// closure retains it instead (see `start()`). If the box held the only
  /// strong reference, teardown would release the block while the tap thread
  /// could still be executing it via the unretained `refcon` bit-cast —
  /// use-after-free at the C boundary.
  private struct TapRuntime {
    var port: CFMachPort?
    var source: CFRunLoopSource?
    var runLoop: CFRunLoop?
  }

  private(set) var isRunning = false

  private let onPress: @Sendable (MediaKeyPress) -> Void
  /// Current watch config, read synchronously by the callback on the tap
  /// thread; replaced whole under the lock by `update(config:)`.
  private let configLock: OSAllocatedUnfairLock<WatchConfig>
  private let runtime = OSAllocatedUnfairLock(
    uncheckedState: TapRuntime()
  )

  /// `onPress` is invoked on the tap thread; the consumer is responsible for
  /// hopping to the main actor (`Task { @MainActor in … }`).
  init(onPress: @escaping @Sendable (MediaKeyPress) -> Void) {
    self.onPress = onPress
    self.configLock = OSAllocatedUnfairLock(
      initialState: WatchConfig(watchedKeys: [], interceptAlternateBrightnessKeys: false)
    )
  }

  deinit {
    Self.teardown(runtime)
  }

  /// Creates the tap and starts the dedicated run-loop thread. Throws
  /// `TapError.creationFailed` when `tapCreate` returns nil — no Accessibility
  /// grant, or the tap was otherwise denied. Restarts cleanly if already
  /// running.
  func start(config: WatchConfig) throws {
    stop()
    configLock.withLock { $0 = config }

    // Capture locals, not self: the trampoline lives for the tap thread's
    // lifetime, so capturing self would pin the controller alive with it —
    // and the callback needs nothing MainActor anyway.
    let configLock = self.configLock
    let runtime = self.runtime
    let onPress = self.onPress
    let callback: EventTapCallback = { type, event in
      if type == .tapDisabledByTimeout {
        // The system disabled us for being slow; re-enable and pass the
        // event through. Reads the port from the shared box — the callback
        // closure exists before `tapCreate` ever returns it.
        if let port = runtime.withLockUnchecked({ $0.port }) {
          CGEvent.tapEnable(tap: port, enable: true)
        }
        return event
      }
      if type == .tapDisabledByUserInput {
        return event
      }
      let config = configLock.withLock { $0 }
      return Self.process(type: type, event: event, config: config, onPress: onPress)
    }

    // C-callback trampoline, exactly as the original library: the block is
    // bit-cast to a pointer and carried through `refcon`, then bit-cast back
    // inside the @convention(c) callback (which cannot capture anything).
    let cCallback: CGEventTapCallBack = { _, type, event, refcon in
      let block = unsafeBitCast(refcon, to: EventTapCallback.self)
      return block(type, event).map(Unmanaged.passUnretained)
    }
    let refcon = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)

    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(1 << NX_KEYDOWN) | CGEventMask(1 << NX_SYSDEFINED),
      callback: cCallback,
      userInfo: refcon
    ) else {
      throw TapError.creationFailed
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, port, 0) else {
      CFMachPortInvalidate(port)
      throw TapError.creationFailed
    }

    runtime.withLockUnchecked { state in
      state.port = port
      state.source = source
    }

    // nonisolated(unsafe): CFRunLoopSource is not Sendable in Swift's eyes,
    // but this is a single-threaded handoff — written once here before the
    // thread starts, read only by the tap thread (and CF run-loop sources are
    // thread-safe regardless).
    nonisolated(unsafe) let threadSource = source
    let thread = Thread {
      // The thread closure retains the trampoline block (`callback`) for the
      // thread's whole lifetime. That is exactly the window callbacks can
      // execute in: the C side holds only an unretained bit-cast, the thread
      // cannot exit `CFRunLoopRun()` while a callback is running on it, and
      // no callback dispatches after the source/port are invalidated — so
      // teardown can never free the block under a mid-flight callback.
      withExtendedLifetime(callback) {
        // The run loop reference can only be obtained on the tap thread
        // itself, so it is written into the shared box off-main, before
        // CFRunLoopRun. Generation guard: only claim the box if it still owns
        // THIS start's source — a rapid start()→start() (or a stop() racing
        // thread spin-up) must not let a stale thread overwrite the new
        // thread's run loop or run an already-torn-down tap.
        let runLoop = CFRunLoopGetCurrent()
        let current = runtime.withLockUnchecked { state -> Bool in
          guard state.source === threadSource else { return false }
          state.runLoop = runLoop
          return true
        }
        guard current else { return }
        // If stop() invalidates the source between the guard above and here,
        // adding an invalidated source is a no-op, the loop has no sources,
        // and CFRunLoopRun returns immediately — the thread exits instead of
        // spinning orphaned.
        CFRunLoopAddSource(runLoop, threadSource, .commonModes)
        CFRunLoopRun()
      }
    }
    thread.name = "MediaKeyEventTap"
    thread.start()
    isRunning = true
  }

  /// Invalidates the tap and stops the run-loop thread. Safe to call when not
  /// running.
  func stop() {
    Self.teardown(runtime)
    isRunning = false
  }

  /// Replaces the watch config; safe while running (the callback reads the
  /// current value under the lock on every event).
  func update(config: WatchConfig) {
    configLock.withLock { $0 = config }
  }

  /// Nonisolated so `deinit` (which is nonisolated) can share it with
  /// `stop()`. Invalidating source+port ends callback dispatch; the tap
  /// thread then exits `CFRunLoopRun()` and releases the trampoline block it
  /// retains (see `start()`), so teardown never frees the block itself.
  private nonisolated static func teardown(_ runtime: OSAllocatedUnfairLock<TapRuntime>) {
    let old = runtime.withLockUnchecked { state -> TapRuntime in
      let old = state
      state = TapRuntime()
      return old
    }
    if let source = old.source {
      CFRunLoopSourceInvalidate(source)
    }
    if let port = old.port {
      CFMachPortInvalidate(port)
    }
    if let runLoop = old.runLoop {
      CFRunLoopStop(runLoop)
    }
  }

  // MARK: - Tap-thread event handling

  /// Runs on the tap thread. Returns the event to pass it through to the
  /// system, or nil to swallow it after delivering a `MediaKeyPress`.
  private nonisolated static func process(
    type: CGEventType,
    event: CGEvent,
    config: WatchConfig,
    onPress: @Sendable (MediaKeyPress) -> Void
  ) -> CGEvent? {
    if type == .keyDown {
      let keycode = event.getIntegerValueField(.keyboardEventKeycode)
      let key: MediaKey?
      switch keycode {
      case 107: // F14
        key = config.interceptAlternateBrightnessKeys ? .brightnessDown : nil
      case 113: // F15
        key = config.interceptAlternateBrightnessKeys ? .brightnessUp : nil
      case 144: // dedicated brightness-up keyDown some keyboards/KVMs send
        key = .brightnessUp
      case 145: // dedicated brightness-down ditto
        key = .brightnessDown
      default:
        key = nil
      }
      guard let key, config.watchedKeys.contains(key) else { return event }
      // Synthesized press: keyDown auto-repeats also arrive as
      // isRepeat: false (fork precedent — CGEvent keyDowns aren't decoded for
      // the autorepeat field), so fresh-press-only combos (e.g. mirroring)
      // can re-fire when held via F14. Known M2 limitation, matches the
      // fork's F-key path.
      onPress(MediaKeyPress(
        key: key,
        isPressed: true,
        isRepeat: false,
        modifiers: modifiers(from: event.flags)
      ))
      return nil
    }

    if type.rawValue == UInt32(NX_SYSDEFINED) {
      // NSEvent(cgEvent:) is a pure data wrapper over the CGEvent — no UI,
      // no main-thread requirement — and is used off-main here deliberately:
      // hopping to the main thread inside the callback (as the original
      // library did with DispatchQueue.main.sync) blocks the tap thread for
      // the whole of any menu-tracking session until the tap times out.
      guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return event // not a media-key system event
      }
      let data1 = nsEvent.data1
      let keycode = Int32((data1 & 0xFFFF_0000) >> 16)
      let keyFlags = data1 & 0x0000_FFFF
      let isPressed = ((keyFlags & 0xFF00) >> 8) == 0xA
      let isRepeat = (keyFlags & 0x1) == 0x1
      let key: MediaKey?
      switch keycode {
      case NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
      case NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
      case NX_KEYTYPE_SOUND_UP: key = .volumeUp
      case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
      case NX_KEYTYPE_MUTE: key = .mute
      default: key = nil
      }
      // Unwatched keys pass through untouched: this is how volume keys reach
      // the system when the audio-routing rule releases them (M4), and how
      // brightness keys pass through when no external display is connected.
      guard let key, config.watchedKeys.contains(key) else { return event }
      onPress(MediaKeyPress(
        key: key,
        isPressed: isPressed,
        isRepeat: isRepeat,
        modifiers: modifiers(from: event.flags)
      ))
      return nil
    }

    return event
  }

  /// Normalizes CGEvent flags down to the 4-flag `KeyModifiers` domain.
  private nonisolated static func modifiers(from flags: CGEventFlags) -> KeyModifiers {
    var modifiers: KeyModifiers = []
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    return modifiers
  }
}
