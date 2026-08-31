import Foundation
import IOKit.pwr_mgt
import Observation

/// Creates and releases the process's display-sleep assertion. Injected so the
/// pairing can be tested without asking IOKit for a real one.
public protocol PowerAssertionHolding: AnyObject {
  /// The assertion's id, or nil when the system refused it.
  func createPreventDisplaySleep(named name: String) -> UInt32?
  func release(_ id: UInt32)
}

public final class IOKitPowerAssertion: PowerAssertionHolding {
  public init() {}

  public func createPreventDisplaySleep(named name: String) -> UInt32? {
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      name as CFString,
      &id)
    return result == kIOReturnSuccess ? id : nil
  }

  public func release(_ id: UInt32) {
    IOPMAssertionRelease(id)
  }
}

/// Keeps the display awake for as long as it is on, and no longer.
///
/// SESSION-ONLY by design: this defeats a power setting the user chose, so it
/// has no pref, no storage and no schema key. A launch always starts off, and
/// nothing here can leave a Mac awake across a restart.
///
/// The assertion dies with the process, which covers the crash case for free: an
/// assertion is owned by the pid that took it, so a kill -9 releases it as surely
/// as `setOn(false)` does.
///
/// There is deliberately NO `deinit` release: a nonisolated deinit cannot touch
/// this actor's state under strict concurrency, and process death already covers
/// that case. The cost is the one rule this type places on its owner, hold ONE
/// of these for the life of the process. An owner that discards a live instance
/// and builds another leaks the first assertion until the app quits.
///
/// PREVENT-DISPLAY-SLEEP only, never `PreventSystemSleep`: keeping the screen lit
/// implies the system stays up, while the reverse would let the panel sleep under
/// a control that says it will not.
@MainActor
@Observable
public final class KeepAwake {
  /// The name the assertion carries in `pmset -g assertions`. A person reading
  /// that list is entitled to know which app is holding their display awake.
  public static let assertionName = "Candela Keep Awake"

  public private(set) var isOn = false

  @ObservationIgnored private let holder: any PowerAssertionHolding
  @ObservationIgnored private var assertionID: UInt32?

  public init(holder: any PowerAssertionHolding = IOKitPowerAssertion()) {
    self.holder = holder
  }

  /// Idempotent in both directions: a second `true` does not take a second
  /// assertion, which would leave one held after a single `false`.
  public func setOn(_ on: Bool) {
    guard on != isOn else { return }
    if on {
      // `isOn` follows the SYSTEM, not the request: a refused assertion with the
      // switch left on is a control reporting a hold it does not have.
      guard let id = holder.createPreventDisplaySleep(named: Self.assertionName) else { return }
      assertionID = id
      isOn = true
    } else {
      if let id = assertionID { holder.release(id) }
      assertionID = nil
      isOn = false
    }
  }

  public func toggle() { setOn(!isOn) }
}
