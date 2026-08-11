import Foundation
import Testing
@testable import CandelaKit

/// The plumbing four display-configuration coordinators used to hold four copies
/// of each (#68). It sat in the app target, which has no test target (#80), so
/// none of it was ever covered; moving it into CandelaKit is what makes these
/// possible at all.
@MainActor
@Suite("Preview queue and countdown driver (#68)")
struct PreviewPlumbingTests {
  /// A recorder that is main-actor confined, so no locking is needed and the
  /// order it records IS the order the operations ran.
  @MainActor
  final class Log {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
  }

  // MARK: - PreviewQueue

  /// The whole point of the type: two reconfigurations of the same kind are
  /// never in flight at once, however fast they are asked for.
  @Test func operationsRunInTheOrderTheyWereQueuedAndNeverOverlap() async {
    let queue = PreviewQueue()
    let log = Log()

    queue.enqueue {
      log.add("a.start")
      try? await Task.sleep(for: .milliseconds(30))
      log.add("a.end")
    }
    queue.enqueue {
      log.add("b.start")
      try? await Task.sleep(for: .milliseconds(5))
      log.add("b.end")
    }
    await queue.enqueueReturning { log.add("c") }

    #expect(log.entries == ["a.start", "a.end", "b.start", "b.end", "c"])
  }

  /// The second half of the chain contract: a returning operation both waits for
  /// what is already queued AND holds up what is queued after it, even though the
  /// chain is Void-typed and cannot carry its result.
  @Test func aReturningOperationJoinsTheSameChainInBothDirections() async {
    let queue = PreviewQueue()
    let log = Log()

    queue.enqueue {
      try? await Task.sleep(for: .milliseconds(20))
      log.add("first")
    }
    let value = await queue.enqueueReturning { () -> Int in
      log.add("returning")
      return 7
    }
    await queue.enqueueReturning { log.add("last") }

    #expect(value == 7)
    #expect(log.entries == ["first", "returning", "last"])
  }

  // MARK: - PreviewCountdownDriver

  /// Waits for a condition rather than for a fixed span. The suite runs in
  /// parallel and detached work shares the cooperative pool, so a fixed window
  /// makes a test that measures machine load rather than behaviour. The first
  /// draft of this file did exactly that and failed the moment it ran alongside
  /// the other 1300 tests instead of on its own.
  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool, within: Duration = .seconds(5)
  ) async -> Bool {
    let deadline = ContinuousClock.now + within
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  @Test func theClockTicksUntilTheSessionReturnsAnOutcomeAndThenStops() async {
    let driver = PreviewCountdownDriver(interval: .milliseconds(10))
    let ticks = Counter()
    let seen = Log()

    driver.start(
      tick: { await ticks.next(spendingAfter: 3) },
      onTick: { outcome in seen.add(outcome.map(String.init(describing:)) ?? "nil") }
    )
    #expect(await waitUntil({ await ticks.count == 3 }))
    // Long enough that a clock which had NOT spent itself would tick again.
    try? await Task.sleep(for: .milliseconds(80))

    #expect(await ticks.count == 3, "spent on the third tick and never ran again")
    #expect(seen.entries == ["nil", "nil", "reverted"])
  }

  /// The expiry is what rescues a display nobody meant to reconfigure, so
  /// stopping it has to actually stop it.
  @Test func stoppingTheClockEndsIt() async {
    let driver = PreviewCountdownDriver(interval: .milliseconds(10))
    let ticks = Counter()

    driver.start(tick: { await ticks.next(spendingAfter: 1000) }, onTick: { _ in })
    #expect(await waitUntil({ await ticks.count > 0 }), "it was running")
    driver.stop()
    let atStop = await ticks.count
    try? await Task.sleep(for: .milliseconds(80))

    #expect(await ticks.count == atStop, "nothing ticked after the stop")
    #expect(driver.isRunning == false)
  }

  /// Restarting supersedes rather than stacking. Two clocks on one session would
  /// spend it in half the time, which on a mode preview means a display snapping
  /// back while its question is still on screen.
  @Test func startingAgainReplacesTheRunningClockRatherThanAddingOne() async {
    let driver = PreviewCountdownDriver(interval: .milliseconds(10))
    let first = Counter()
    let second = Counter()

    driver.start(tick: { await first.next(spendingAfter: 1000) }, onTick: { _ in })
    #expect(await waitUntil({ await first.count > 0 }))
    driver.start(tick: { await second.next(spendingAfter: 1000) }, onTick: { _ in })
    #expect(await waitUntil({ await second.count > 0 }), "the new clock is running")
    let firstNow = await first.count
    try? await Task.sleep(for: .milliseconds(80))

    #expect(await first.count == firstNow, "the superseded clock is dead")
    driver.stop()
  }

  /// The reason the driver is detached: a main actor wedged inside a synchronous
  /// reconfiguration callback must not be able to stop the expiry.
  ///
  /// Asserted by WHERE the tick runs, not by how many ticks fit in a window. The
  /// window version measures how busy the machine is; this one fails if the
  /// detached task ever becomes a plain `Task`, which is the regression that
  /// matters and the one a count cannot distinguish from a slow test host.
  @Test func theClockNeverRunsOnTheMainActor() async {
    let driver = PreviewCountdownDriver(interval: .milliseconds(10))
    let observed = ThreadWitness()

    // `pthread_main_np`, not `Thread.isMainThread`: the latter is unavailable
    // from an async context, which is the only context this closure has.
    driver.start(
      tick: { await observed.record(isMain: pthread_main_np() != 0) },
      onTick: { _ in }
    )
    #expect(await waitUntil({ await observed.ticks > 0 }))
    driver.stop()

    #expect(await observed.everOnMain == false)
  }
}

/// The clock the Mode, Mirror and Arrangement sessions each held a copy of (#68).
@Suite("Preview countdown (#68)")
struct PreviewCountdownTests {
  @Test func anArmedClockSpendsItselfExactlyOnce() {
    var clock = PreviewCountdown()
    clock.arm(seconds: 3)

    // Hoisted out of `#expect`: the macro captures its expression immutably, so
    // a mutating call cannot be made inside one.
    var fired = clock.tick(); #expect(fired == false)
    fired = clock.tick(); #expect(fired == false)
    #expect(clock.remaining == 1)
    fired = clock.tick(); #expect(fired, "the tick that spends it")
    #expect(clock.remaining == 0)
    #expect(clock.isArmed == false)
  }

  /// THE reason this is a type and not an `Int`. A failed expiry revert disarms
  /// rather than re-attempting from every later tick; re-attempting is
  /// `revert()`'s job, on a person's say-so. If `isArmed` were derived from
  /// `remaining > 0` the two facts would collapse and a spent clock would fire
  /// again the moment anything nudged it.
  @Test func aSpentClockNeverFiresAgainHoweverOftenItIsTicked() {
    var clock = PreviewCountdown()
    clock.arm(seconds: 1)
    var fired = clock.tick(); #expect(fired)

    for _ in 0 ..< 5 {
      fired = clock.tick(); #expect(fired == false)
    }
    #expect(clock.remaining == 0, "and it does not run negative")
  }

  @Test func aClockThatWasNeverArmedDoesNothing() {
    var clock = PreviewCountdown()
    #expect(clock.isArmed == false)
    let fired = clock.tick(); #expect(fired == false)
    #expect(clock.remaining == 0)
  }

  /// Disarming is how every non-expiry ending is spelled: an answer, a discard,
  /// a departure. It must stop the clock without firing it.
  @Test func disarmingStopsTheClockWithoutFiringIt() {
    var clock = PreviewCountdown()
    clock.arm(seconds: 30)
    clock.disarm()

    #expect(clock.isArmed == false)
    #expect(clock.remaining == 0)
    let fired = clock.tick(); #expect(fired == false, "disarming is not a deferred expiry")
  }

  /// A second preview supersedes the first rather than nesting, so re-arming
  /// restarts rather than adding time.
  @Test func armingAgainRestartsRatherThanExtending() {
    var clock = PreviewCountdown()
    clock.arm(seconds: 30)
    _ = clock.tick()
    clock.arm(seconds: 30)

    #expect(clock.remaining == 30)
    #expect(clock.isArmed)
  }

  /// A one-second clock fires on its first tick. Off by one here would either
  /// revert a preview immediately or leave it up a second past its deadline.
  @Test func aOneSecondClockFiresOnTheFirstTick() {
    var clock = PreviewCountdown()
    clock.arm(seconds: 1)
    let fired = clock.tick(); #expect(fired)
  }
}

/// The other half of #68's consolidation: the five-term geometry match that was
/// spelled out in `ModeReapplyPolicy` and in the apply cross-check.
@Suite("Mode geometry matching (#68)")
struct ModeGeometryMatchTests {
  private func mode(
    id: Int32 = 1, logical: (Int, Int) = (2560, 1440), pixels: (Int, Int) = (5120, 2880),
    hz: Double = 60, native: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz, isNative: native
    )
  }

  /// The reason the rule exists at all: `ioModeID` is a positional handle
  /// reassigned across reconfiguration, so it is evidence of nothing in either
  /// direction. Comparing modes with `==` would get this backwards twice.
  @Test func theModeIdIsIgnoredInBothDirections() {
    #expect(mode(id: 3).matchesGeometry(of: mode(id: 91)))
    #expect(!mode(id: 3).matchesGeometry(of: mode(id: 3, logical: (1920, 1080))))
  }

  /// CoreGraphics reports 59.997 for what everything else calls 60. An exact
  /// comparison would decide the display is never already where it is, which on
  /// the reapply path means re-applying a mode on every single wake.
  @Test func refreshComparesWithTheTolerance() {
    #expect(mode(hz: 59.997).matchesGeometry(of: mode(hz: 60)))
    #expect(!mode(hz: 60).matchesGeometry(of: mode(hz: 120)))
  }

  /// Excluded deliberately: it is a fact about the panel, not part of a mode's
  /// identity. Folding it in would make the apply cross-check throw on a mode it
  /// had just correctly resolved.
  @Test func nativenessIsNotPartOfTheIdentity() {
    #expect(mode(native: true).matchesGeometry(of: mode(native: false)))
  }

  /// All four size terms are load-bearing. Point size alone would call a HiDPI
  /// mode and its 1x twin the same mode, which is the entire distinction the
  /// revealed-modes feature exists to offer.
  @Test func everySizeTermIsChecked() {
    let base = mode()
    #expect(!base.matchesGeometry(of: mode(logical: (2560, 1441))))
    #expect(!base.matchesGeometry(of: mode(logical: (2561, 1440))))
    #expect(!base.matchesGeometry(of: mode(pixels: (2560, 1440))), "the 1x twin")
    #expect(!base.matchesGeometry(of: mode(pixels: (5120, 2881))))
    #expect(base.matchesGeometry(of: base))
  }

  @Test func theRelationIsSymmetric() {
    #expect(mode(hz: 59.997).matchesGeometry(of: mode(hz: 60)))
    #expect(mode(hz: 60).matchesGeometry(of: mode(hz: 59.997)))
  }
}

/// Records which thread the clock ticked on. Never spends itself, so the clock
/// keeps running until the test stops it.
private actor ThreadWitness {
  private(set) var ticks = 0
  private(set) var everOnMain = false

  func record(isMain: Bool) -> Int? {
    ticks += 1
    if isMain { everOnMain = true }
    return nil
  }
}

/// Counts ticks and reports an outcome once it has been asked `spendingAfter`
/// times, standing in for a preview session's own clock.
private actor Counter {
  private(set) var count = 0

  func next(spendingAfter limit: Int) -> PreviewOutcome? {
    count += 1
    return count >= limit ? .reverted : nil
  }
}
