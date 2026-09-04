//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Based on MediaKeyTap by Nicholas Hurden (MIT)

// @preconcurrency: same mutable-C-global import quirk as AccessibilityPermission.
@preconcurrency import ApplicationServices
import CandelaKit
import CoreGraphics
import Foundation
import os

/// CGEventTap island that intercepts brightness/volume media keys and the
/// F14/F15 + dedicated-brightness keyDown codes, delivering decoded
/// `MediaKeyPress` values to `onPress`. Modernized transplant of the
/// MediaKeyTap internals the MonitorControl fork used.
///
/// Threading model:
/// - The public API (`start`/`stop`/`update`/`isRunning`) is `@MainActor`.
/// - The tap callback runs on a dedicated `Thread` ("MediaKeyEventTap")
///   spinning `CFRunLoopRun()`. It never hops to the main thread: the original
///   library's `DispatchQueue.main.sync` blocked the tap thread for the whole
///   of any menu-tracking session, tripping the tap timeout.
/// - `WatchConfig` crosses to the tap thread through an
///   `OSAllocatedUnfairLock<WatchConfig>` (same lock-not-actor pattern as
///   `BrightnessWriteCoalescer`'s submission slot: the callback must read it
///   synchronously, with no executor hop).
/// - The CF runtime objects (`CFMachPort`/`CFRunLoopSource`/`CFRunLoop`) live
///   in a second lock-protected, nonisolated box rather than `@MainActor`
///   stored properties, because the run loop can only be captured via
///   `CFRunLoopGetCurrent()` on the tap thread itself, and the
///   `tapDisabledByTimeout` re-enable must read the mach port inside the
///   nonisolated callback (the port does not exist until `tapCreate` returns,
///   after the callback closure is built).
/// - Only the `Sendable` `MediaKeyPress` escapes the callback; `onPress` is
///   invoked on the tap thread and the consumer hops actors itself.
/// - **No thread this island owns may touch AppKit or HIToolbox**: not the tap
///   thread, not the prober, not the monitor. None of them is the main queue,
///   and AppKit entry points reach HIToolbox code that asserts on it. That is
///   why the island imports no AppKit at all and decodes the system-defined
///   payload straight off the CGEvent (see `sysDefinedSubtypeField`).
@MainActor
final class MediaKeyEventTap {
  struct WatchConfig: Sendable {
    /// Empty set = watch nothing (all keys pass through to the system).
    var watchedKeys: Set<MediaKey>
    /// Intercept F14/F15 (keycodes 107/113) as brightness keys.
    var interceptAlternateBrightnessKeys: Bool
  }

  enum TapError: Error {
    case creationFailed
    /// The private CGEvent field indices the system-defined decode depends on
    /// did not read back what was written. See `sysDefinedFieldsUsable`.
    case eventFieldsUnrecognized
  }

  /// Watchdog logging. `notice` persists to the unified log by default, so a
  /// post-incident `log show` can reconstruct a wedge without a debug build.
  nonisolated static let watchdogLog = Logger(
    subsystem: "com.rydersel.Candela", category: "tap-watchdog"
  )

  /// Called (on an arbitrary thread) after the watchdog monitor performs an
  /// emergency teardown. The controller uses it to re-check the grant after a
  /// settle delay and rebuild the tap when the teardown was a false alarm.
  var onEmergencyTeardown: (@Sendable () -> Void)?

  /// Self-ping marker carried in `.eventSourceUserData`. Arbitrary value,
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
  /// closure retains it instead (see `start()`). If the box held the only strong
  /// reference, teardown would release the block while the tap thread could
  /// still be executing it via the unretained `refcon` bit-cast, which is a
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
  /// `TapError.creationFailed` when `tapCreate` returns nil: no Accessibility
  /// grant, or the tap was otherwise denied. Restarts cleanly if already
  /// running.
  func start(config: WatchConfig) throws {
    stop()
    // Arm nothing if the private field indices moved: an unverified decode
    // would swallow every aux key on the system, silently.
    guard Self.sysDefinedFieldsUsable else { throw TapError.eventFieldsUnrecognized }
    configLock.withLock { $0 = config }

    // Capture locals, not self: the trampoline lives for the tap thread's
    // lifetime, so capturing self would pin the controller alive with it, and
    // the callback needs nothing MainActor anyway.
    let configLock = self.configLock
    let runtime = self.runtime
    let onPress = self.onPress
    /// Watchdog heartbeat, shared by the callback, the prober and the monitor:
    /// (ping posted, ping seen by the callback, probe in flight, prober loop
    /// completed). Created before the callback closure so the callback can
    /// stamp `pingSeen`.
    let heartbeat = OSAllocatedUnfairLock<
      (pingPosted: Date?, pingSeen: Date, probing: Date?, alive: Date)
    >(initialState: (nil, Date(), nil, Date()))
    let callback: EventTapCallback = { type, event in
      // Self-ping marker: our own prober posted this event. Stamp its arrival
      // and swallow it, since it is not for the system.
      if event.getIntegerValueField(.eventSourceUserData) == Self.pingMagic {
        heartbeat.withLock { $0.pingSeen = Date(); $0.pingPosted = nil }
        return nil
      }
      if type == .tapDisabledByTimeout {
        // The system disabled us for being slow; re-enable and pass the event
        // through. Reads the port from the shared box, since the callback
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

    // nonisolated(unsafe): CFRunLoopSource is not Sendable in Swift's eyes, but
    // this is a single-threaded handoff, written once here before the thread
    // starts and read only by the tap thread (and CF run-loop sources are
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
        // The run loop reference can only be obtained on the tap thread itself,
        // so it is written into the shared box off-main, before CFRunLoopRun.
        // Generation guard: only claim the box if it still owns THIS start's
        // source, or a rapid start()/start() (or a stop() racing thread spin-up)
        // lets a stale thread overwrite the new thread's run loop.
        let runLoop = CFRunLoopGetCurrent()
        let current = runtime.withLockUnchecked { state -> Bool in
          guard state.source === threadSource else { return false }
          state.runLoop = runLoop
          return true
        }
        guard current else { return }
        // If stop() invalidates the source between the guard above and here,
        // adding an invalidated source is a no-op, the loop has no sources, and
        // CFRunLoopRun returns immediately, so the thread exits instead of
        // spinning orphaned.
        CFRunLoopAddSource(runLoop, threadSource, .commonModes)
        CFRunLoopRun()
      }
    }
    thread.name = "MediaKeyEventTap"
    thread.start()

    // The deadman switch, in two threads. A PROBER polls the grant every 0.5 s
    // (`AXIsProcessTrustedWithOptions`, covering committed revocations the
    // notification path misses) and posts the synthetic self-ping described
    // below every 2 s, so the liveness evidence comes from our own event stream
    // rather than from any WindowServer call. A MONITOR compares clocks each
    // second and makes no calls of its own: a ping unanswered over 5 s, or a
    // probe in flight that long, invalidates the port through the nonisolated
    // teardown, the same kernel-level release as process death.
    //
    // 5 s tolerates the platform's legitimate stalls: mode changes and rotation
    // block up to about 1.1 s. `onEmergencyTeardown` then re-checks the grant
    // after a settle delay and rebuilds the tap when it was a false alarm.
    nonisolated(unsafe) let watchdogPort = port
    let watchdogRuntime = self.runtime
    let onEmergencyTeardown = self.onEmergencyTeardown

    // Revoking Accessibility under a live active tap wedges the event pipeline
    // until the tap's mach port dies, and in the TCC-entry-DELETE case there is
    // NO conventional signal to detect it by [ALL MEASURED 2026-08-05, one
    // instrumented freeze each]:
    //   - no `com.apple.accessibility.api` notification is posted (toggles
    //     post it; deletes do not);
    //   - `AXIsProcessTrustedWithOptions` keeps returning a stale `true`,
    //     because the delete cannot COMMIT while the pipeline is wedged;
    //   - WindowServer keeps answering RPCs (`CGWindowListCopyWindowInfo`
    //     returned normally throughout a live freeze);
    //   - the process is never suspended (state stayed S, all threads ran).
    // Only event DELIVERY stalls, so the detector lives in the event stream
    // itself: the prober posts a marker event every 2 s and the tap callback
    // stamps its arrival. A healthy pipeline round-trips in milliseconds; a
    // posted ping that has not arrived within 5 s means the pipeline is wedged,
    // and the monitor invalidates the port.
    let prober = Thread {
      Self.watchdogLog.debug("prober started")
      // Different cadences, for a measured platform deadline: WindowServer
      // force-times-out a tap whose owner has lost its Accessibility grant after
      // about 1 s, and a wedge that has formed is cleared only by process death.
      // A 2 s poll samples strictly slower than the deadline it exists to beat,
      // so trust is sampled every 0.5 s.
      //
      // The ping stays at 2 s: it is a liveness probe, not a race against a
      // deadline, and posting it four times as often would put four times the
      // synthetic traffic through a tap whose whole failure mode is stalling.
      let trustPollInterval: TimeInterval = 0.5
      let pollsPerPing = 4
      var pollsSinceLastPing = pollsPerPing
      while true {
        let current = watchdogRuntime.withLockUnchecked { $0.port === watchdogPort }
        guard current else { Self.watchdogLog.debug("prober: port gone, exiting"); return }
        // Post the ping only if the previous one arrived: a stuck ping must keep
        // its original timestamp so the monitor's clock runs from the FIRST
        // unanswered post.
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

    // The monitor makes NO IPC calls: it compares clocks and, on staleness,
    // performs the teardown (lock plus mach-port destruction, all local, cannot
    // block). Ping unanswered over 5 s means the pipeline is wedged; probe or AX
    // in flight over 5 s, or the prober loop silent over 12 s, means the prober
    // is stuck in a call. The thresholds and the decision live in
    // `TapWatchdogVerdict`.
    //
    // A system sleep is the one staleness that means nothing: both threads stop
    // with the machine, and at the next wake the monitor can run first and read
    // the prober's stamp exactly as old as the sleep. That shipped as a real
    // exit and relaunch, 87 times in three days, always `proberDead` alone. The
    // verdict compares the wall clock against the uptime clock, which stops
    // during sleep, and a tick that straddled a sleep decides nothing.
    let monitor = Thread {
      Self.watchdogLog.debug("monitor started")
      var previousTick = TapWatchdogClock.now()
      while true {
        Thread.sleep(forTimeInterval: 1)
        let current = watchdogRuntime.withLockUnchecked { $0.port === watchdogPort }
        guard current else { Self.watchdogLog.debug("monitor: port gone, exiting"); return }
        let now = TapWatchdogClock.now()
        let hb = heartbeat.withLock { $0 }
        let outcome = TapWatchdogVerdict.evaluate(
          sample: .init(pingPosted: hb.pingPosted, probing: hb.probing, alive: hb.alive),
          previousTick: previousTick, now: now
        )
        previousTick = now
        switch outcome {
        case .healthy:
          continue
        case .sleptAcrossTick(let seconds):
          Self.watchdogLog.notice(
            "slept \(Int(seconds)) s across a tick; stamps reset, no verdict"
          )
          heartbeat.withLock { $0.pingPosted = nil; $0.probing = nil; $0.alive = now.wall }
          continue
        case .wedged(let pingLost, let probeStuck, let proberDead):
          Self.watchdogLog.fault(
            "EMERGENCY: pingLost=\(pingLost) probeStuck=\(probeStuck) proberDead=\(proberDead)"
          )
          Self.teardown(watchdogRuntime)
          // Invalidating the port is NOT enough once the wedge has formed
          // [MEASURED 2026-08-05: the detector fired, teardown completed, and
          // input stayed frozen until the process was killed]. Only process
          // death clears an established wedge, five times out of five. So spawn
          // a detached relauncher and exit: its sleep outlives our death, by
          // which point the pipeline is free again. A false fire costs one app
          // blink, which is why the sleep case above never reaches here.
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

  /// Nonisolated so `deinit` can share it with `stop()`. Invalidating source and
  /// port ends callback dispatch; the tap thread then exits `CFRunLoopRun()` and
  /// releases the trampoline block it retains, so teardown never frees the block
  /// itself.
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

  /// PRIVATE API: CGEvent integer field indices 99 and 149 are undocumented.
  /// They hold an NX_SYSDEFINED event's subtype and its compound `data1`, the
  /// same two values `NSEvent.subtype` and `NSEvent.data1` expose.
  ///
  /// If an index goes inert on a future macOS, the `sysDefinedFieldsUsable`
  /// self-check below disarms interception loudly (a `.fault` log, `start`
  /// throws, no tap created) rather than misdecoding. An inert field reads back
  /// 0 with no error, and 0 is a valid payload meaning `NX_KEYTYPE_SOUND_UP`
  /// released, so without the check a shift would silently swallow every aux key
  /// on the system.
  ///
  /// The check proves only that each index is still a live writable compound
  /// slot [MEASURED 2026-08-12]. Going inert is caught; a shift ONTO another
  /// live slot is not: probing (99, 150) or (100, 149) reports usable, while
  /// (98, 149), (99, 148), (97, 151) and (250, 999) all disarm. A semantic check
  /// would need `NSEvent`, which is the thing being removed.
  ///
  /// [MEASURED 2026-08-12] Subtypes 0...40 plus 100, 110, 134, 200, 202 and 210,
  /// round-tripped through `NSEvent.otherEvent` and `.cgEvent`: index 99 is the
  /// subtype and index 149 the `data1` in every one of them EXCEPT 6 and 9,
  /// which carry no compound payload at all. Nobody needs to re-measure it.
  ///
  /// Why not `NSEvent(cgEvent:)`, which reads both without any of this: on a
  /// subtype-8 event it runs HIToolbox's caps-lock state machine
  /// (`CreateEventWithCGEvent` to `TSMSetCapsLockKeyTransitionDetected` to
  /// `TSMGetInputSourceProperty`), which asserts it is on the main dispatch
  /// queue. The tap callback is on the tap thread by design, so one Caps Lock
  /// press trapped the process in `_dispatch_assert_queue_fail`. Nothing
  /// mechanical stops someone adding `import AppKit` back and reaching for
  /// NSEvent here; this comment is the only guard.
  private nonisolated static let sysDefinedSubtypeField = CGEventField(rawValue: 99)!
  private nonisolated static let sysDefinedData1Field = CGEventField(rawValue: 149)!

  /// The only NX_SYSDEFINED subtype that carries media keys, and the only one
  /// this tap decodes.
  private nonisolated static let auxControlSubtype = Int64(NX_SUBTYPE_AUX_CONTROL_BUTTONS)

  /// Write-then-read probe of the two private field indices, run once before
  /// the first tap is armed.
  ///
  /// Why this is safe to run [MEASURED 2026-08-12], because the obvious guess is
  /// wrong: a bare event retyped to NX_SYSDEFINED ALREADY carries the compound
  /// payload, with no subtype write at all. Setting the subtype does not grant
  /// the payload; setting it to 6 or 9 TAKES IT AWAY, and the next write to
  /// `sysDefinedData1Field` then aborts in `SLSEventRecordSetCompoundInt`. So the
  /// invariant is narrow: this probe must never write subtype 6 or 9. It holds
  /// because the value is hard-coded to the aux-control subtype. Do not
  /// parameterize it believing the write protects itself.
  private static let sysDefinedFieldsUsable: Bool = {
    let probeData1: Int64 = 0x0002_0A00 // brightness up, pressed, no repeat
    guard let probe = CGEvent(source: nil),
          let sysDefined = CGEventType(rawValue: UInt32(NX_SYSDEFINED))
    else {
      watchdogLog.fault("media keys: cannot build a probe event; interception disarmed")
      return false
    }
    probe.type = sysDefined
    probe.setIntegerValueField(sysDefinedSubtypeField, value: auxControlSubtype)
    probe.setIntegerValueField(sysDefinedData1Field, value: probeData1)
    let subtype = probe.getIntegerValueField(sysDefinedSubtypeField)
    let data1 = probe.getIntegerValueField(sysDefinedData1Field)
    guard subtype == auxControlSubtype, data1 == probeData1 else {
      watchdogLog.fault(
        """
        media keys: CGEvent system-defined field indices moved \
        (subtype read \(subtype), expected \(MediaKeyEventTap.auxControlSubtype); \
        data1 read \(data1), expected \(probeData1)). \
        Interception disarmed rather than misdecoding every aux key.
        """
      )
      return false
    }
    return true
  }()

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
      // Synthesized press: keyDown auto-repeats also arrive as isRepeat: false
      // (fork precedent, since CGEvent keyDowns are not decoded for the
      // autorepeat field), so fresh-press-only combos can re-fire when held via
      // F14. A known limitation, matching the fork's F-key path.
      onPress(MediaKeyPress(
        key: key,
        isPressed: true,
        isRepeat: false,
        modifiers: modifiers(from: event.flags)
      ))
      return nil
    }

    if type.rawValue == UInt32(NX_SYSDEFINED) {
      // Decoded straight off the CGEvent, never via NSEvent(cgEvent:): see
      // `sysDefinedSubtypeField` for why building an NSEvent here traps. The gate
      // order is load-bearing: reading the payload field on a subtype that
      // carries no compound data trips a CoreGraphics assertion
      // (`event_carries_compound_data_field`), so the subtype goes first.
      guard event.getIntegerValueField(Self.sysDefinedSubtypeField) == Self.auxControlSubtype else {
        return event // not a media-key system event
      }
      let press = AuxControlDecoder.decode(
        data1: event.getIntegerValueField(Self.sysDefinedData1Field),
        modifiers: modifiers(from: event.flags)
      )
      // Unwatched keys pass through untouched: this is how volume keys reach the
      // system when the audio-routing rule releases them, and how brightness keys
      // pass through when no external display is connected.
      guard let press, config.watchedKeys.contains(press.key) else { return event }
      onPress(press)
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
