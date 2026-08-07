//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Based on MediaKeyTap by Nicholas Hurden (MIT)

import AppKit
// @preconcurrency: same mutable-C-global import quirk as AccessibilityPermission.
@preconcurrency import ApplicationServices
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

  /// #59 watchdog logging. `notice` persists to the unified log by default,
  /// so a post-incident `log show` can reconstruct a wedge without a debug
  /// build — the whole investigation depended on exactly that visibility.
  nonisolated static let watchdogLog = Logger(
    subsystem: "com.rydersel.Candela", category: "tap-watchdog"
  )

  /// Called (on an arbitrary thread) after the #59 monitor performs an
  /// emergency teardown. The controller uses it to re-check the grant after a
  /// settle delay and rebuild the tap when the teardown was a false alarm.
  var onEmergencyTeardown: (@Sendable () -> Void)?

  /// #59 self-ping marker carried in `.eventSourceUserData`. Arbitrary value,
  /// distinctive enough not to collide with anything real.
  nonisolated static let pingMagic: Int64 = 0x0059_CAD3_1A

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
    /// #59 heartbeat, shared by the callback, the prober and the monitor:
    /// (ping posted, ping seen by the callback, probe in flight, prober loop
    /// completed). Created before the callback closure so the callback can
    /// stamp `pingSeen`.
    let heartbeat = OSAllocatedUnfairLock<
      (pingPosted: Date?, pingSeen: Date, probing: Date?, alive: Date)
    >(initialState: (nil, Date(), nil, Date()))
    let callback: EventTapCallback = { type, event in
      // #59 self-ping marker: our own prober posted this event. Stamp its
      // arrival and swallow it — it is not for the system.
      if event.getIntegerValueField(.eventSourceUserData) == Self.pingMagic {
        heartbeat.withLock { $0.pingSeen = Date(); $0.pingPosted = nil }
        return nil
      }
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

    // #59 deadman switch. Revoking Accessibility under a live active tap
    // wedges WindowServer until the tap's mach port dies — and in the
    // TCC-entry-DELETE case there is NO in-band signal to react to [MEASURED
    // 2026-08-05]: no distributed notification is posted, and
    // AXIsProcessTrustedWithOptions keeps returning a stale `true` because
    // the delete cannot COMMIT while WindowServer is wedged on our port. A
    // sampled freeze showed this process completely healthy while input was
    // dead. The only reliable detection is the wedge itself:
    //
    // - A PROBER thread makes a cheap WindowServer round-trip every 2 s
    //   (`CGWindowListCopyWindowInfo` — a real RPC, unlike display-bounds
    //   reads, which are locally cached).
    // - A MONITOR thread checks two conditions each second: a committed
    //   revocation (AX poll — covers toggles the notification path misses),
    //   and a probe stuck > 5 s (WindowServer wedged while we hold an active
    //   tap). Either way it invalidates the port via the nonisolated
    //   teardown — the same kernel-level release as process death — which
    //   un-wedges WindowServer and lets a pending TCC delete commit.
    // - 5 s tolerates WindowServer's legitimate stalls (mode changes and
    //   rotation block up to ~1.1 s, measured on #11).
    // - `onEmergencyTeardown` then re-checks the grant after a settle delay
    //   and rebuilds the tap when the teardown was a false alarm.
    nonisolated(unsafe) let watchdogPort = port
    let watchdogRuntime = self.runtime
    let onEmergencyTeardown = self.onEmergencyTeardown

    // #59: revoking Accessibility under a live active tap wedges the event
    // pipeline until the tap's mach port dies, and in the TCC-entry-DELETE
    // case there is NO conventional signal to detect it by [ALL MEASURED
    // 2026-08-05, one instrumented freeze each]:
    //   - no `com.apple.accessibility.api` notification is posted (toggles
    //     post it; deletes do not);
    //   - `AXIsProcessTrustedWithOptions` keeps returning a stale `true`,
    //     because the delete cannot COMMIT while the pipeline is wedged;
    //   - WindowServer keeps answering RPCs (`CGWindowListCopyWindowInfo`
    //     returned normally throughout a live freeze);
    //   - the process is never suspended (state stayed S, all threads ran).
    // Only event DELIVERY stalls. So the detector lives in the event stream
    // itself: the prober posts a marker event every 2 s and the tap callback
    // stamps its arrival. A healthy pipeline round-trips in milliseconds; a
    // posted ping that has not arrived within 5 s means the pipeline is
    // wedged, and the monitor invalidates the port — the same kernel-level
    // release as the process death that recovered the machine each time.
    let prober = Thread {
      Self.watchdogLog.debug("prober started")
      // The trust check and the self-ping run at DIFFERENT cadences, and the
      // reason is a measured platform deadline: WindowServer force-times-out a
      // tap whose owner has lost its Accessibility grant after ~1s, and a wedge
      // that has already formed is cleared only by process death. A 2s poll
      // cannot win that race — it samples strictly slower than the deadline it
      // exists to beat. Trust is therefore sampled every 0.5s.
      //
      // The ping stays at 2s. It is a liveness probe for the event pipeline,
      // not a race against a deadline, and posting it four times as often would
      // put four times the synthetic traffic through a tap whose whole failure
      // mode is stalling.
      let trustPollInterval: TimeInterval = 0.5
      let pollsPerPing = 4
      var pollsSinceLastPing = pollsPerPing
      while true {
        let current = watchdogRuntime.withLockUnchecked { $0.port === watchdogPort }
        guard current else { Self.watchdogLog.debug("prober: port gone, exiting"); return }
        // Post the ping only if the previous one arrived — a stuck ping must
        // keep its original timestamp so the monitor's clock runs from the
        // FIRST unanswered post.
        let dueForPing = pollsSinceLastPing >= pollsPerPing
        let shouldPost = dueForPing && heartbeat.withLock { hb -> Bool in
          guard hb.pingPosted == nil else { return false }
          hb.pingPosted = Date()
          return true
        }
        pollsSinceLastPing = dueForPing ? 1 : pollsSinceLastPing + 1
        if shouldPost {
          // NX_SYSDEFINED with no payload: inside our tap's event mask, so
          // the callback sees and swallows it; inert to the rest of the
          // system if the pipeline delivers it before we do.
          if let ping = CGEvent(source: nil) {
            ping.type = CGEventType(rawValue: UInt32(NX_SYSDEFINED))!
            ping.setIntegerValueField(.eventSourceUserData, value: Self.pingMagic)
            ping.post(tap: .cgSessionEventTap)
          } else {
            // Cannot construct events (should not happen); do not leave a
            // phantom "posted" timestamp for the monitor to time out on.
            heartbeat.withLock { $0.pingPosted = nil }
          }
        }
        // Committed revocations (toggle path) still get a fast, clean
        // teardown even when the distributed notification is missed.
        heartbeat.withLock { $0.probing = Date() }
        let trusted = AXIsProcessTrustedWithOptions(nil)
        heartbeat.withLock { $0.probing = nil; $0.alive = Date() }
        if !trusted {
          Self.watchdogLog.notice("grant revoked, tearing down tap")
          Self.teardown(watchdogRuntime)
          Self.watchdogLog.notice("teardown complete")
          onEmergencyTeardown?()
          return
        }
        Thread.sleep(forTimeInterval: trustPollInterval)
      }
    }
    prober.name = "MediaKeyEventTap.wsProber"
    prober.start()

    // The monitor makes NO IPC calls — it compares clocks and, on staleness,
    // performs the teardown (lock + mach-port destruction, all local, cannot
    // block). Ping unanswered > 5 s: pipeline wedged. Probe/AX in flight
    // > 5 s or prober loop silent > 12 s: the prober is stuck in a call.
    // 5 s tolerates the platform's legitimate stalls (mode changes and
    // rotation block up to ~1.1 s, measured on #11). A system sleep trips
    // these on wake; `onEmergencyTeardown` re-checks the grant after a settle
    // delay and rebuilds the tap, so a false fire self-heals.
    let monitor = Thread {
      Self.watchdogLog.debug("monitor started")
      while true {
        Thread.sleep(forTimeInterval: 1)
        let current = watchdogRuntime.withLockUnchecked { $0.port === watchdogPort }
        guard current else { Self.watchdogLog.debug("monitor: port gone, exiting"); return }
        let hb = heartbeat.withLock { $0 }
        let pingLost = hb.pingPosted.map { Date().timeIntervalSince($0) > 5 } ?? false
        let probeStuck = hb.probing.map { Date().timeIntervalSince($0) > 5 } ?? false
        let proberDead = Date().timeIntervalSince(hb.alive) > 12
        if pingLost || probeStuck || proberDead {
          Self.watchdogLog.fault(
            "EMERGENCY: pingLost=\(pingLost) probeStuck=\(probeStuck) proberDead=\(proberDead)"
          )
          Self.teardown(watchdogRuntime)
          // Invalidating the port is NOT enough once the wedge has formed
          // [MEASURED 2026-08-05: the detector fired, teardown completed, and
          // input stayed frozen until the process was killed]. Only process
          // death clears an established wedge — five out of five times across
          // this investigation. So: spawn a detached relauncher and exit.
          // The relauncher's sleep outlives our death, by which point the
          // pipeline is free again and the app comes back with the banner
          // showing. A false fire (e.g. a wake edge) costs one app blink.
          Self.watchdogLog.fault("event pipeline wedged: exiting to clear it; relauncher spawned")
          let relauncher = Process()
          relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
          relauncher.arguments = [
            "-c", "sleep 2; /usr/bin/open \"\(Bundle.main.bundlePath)\"",
          ]
          try? relauncher.run()
          exit(70)
        }
      }
    }
    monitor.name = "MediaKeyEventTap.revocationMonitor"
    monitor.start()
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
