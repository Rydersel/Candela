import Testing
@testable import CandelaKit

// MARK: - The sentinel rule

/// The checksum a real panel puts in the last byte, so a fixture frame is a
/// frame rather than eleven bytes that happen to fail validation.
private func sealed(_ frame: [UInt8]) -> [UInt8] {
  var sealed = frame
  sealed[sealed.count - 1] = Arm64DDC.checksum(
    chk: 0x50, data: &sealed, start: 0, end: sealed.count - 2
  )
  return sealed
}

/// `[source][length][reply op][result][command][type][max hi][max lo][cur hi][cur lo][chk]`
private func replyFrame(command: UInt8, current: UInt16, max: UInt16) -> [UInt8] {
  sealed([
    0x6E, 0x88, 0x02, 0x00, command, 0x00,
    UInt8(max >> 8), UInt8(max & 0xFF),
    UInt8(current >> 8), UInt8(current & 0xFF),
    0x00,
  ])
}

/// The same frame carrying a result code instead of a value: the display
/// parsed the Get VCP and refused the code. `0x01` is the MCCS "unsupported VCP
/// code", the one the Dell answers for a register it does not carry.
private func refusalFrame(command: UInt8, code: UInt8 = 0x01) -> [UInt8] {
  sealed([0x6E, 0x88, 0x02, code, command, 0x00, 0, 0, 0, 0, 0x00])
}

/// With a zero fill, a buffer nobody wrote to and a panel that answered zeros
/// are the same bytes.
@Test func theReplySentinelIsNotZero() {
  #expect(Arm64DDC.replySentinel != 0)
}

@Test func anUntouchedBufferIsSilenceRatherThanZeros() {
  let untouched = [UInt8](
    repeating: Arm64DDC.replySentinel, count: DDCReplyFrame.expectedLength
  )
  #expect(Arm64DDC.replyVerdict(untouched) == .silent)
}

@Test func aBufferChangedToZerosIsThePanelAnswering() {
  #expect(Arm64DDC.replyVerdict([UInt8](repeating: 0, count: 11)) == .answeredZeros)
}

@Test func aCleanFrameIsAnAnswer() {
  #expect(Arm64DDC.replyVerdict(replyFrame(command: 0x10, current: 50, max: 100)) == .ok)
}

/// Partially written, so neither all zeros nor the untouched sentinel: the panel
/// said something and it was not an answer.
@Test func aFrameThatFailsItsChecksumIsSilence() {
  var garbled = replyFrame(command: 0x10, current: 50, max: 100)
  garbled[7] &+= 1
  #expect(Arm64DDC.replyVerdict(garbled) == .silent)
}

/// The control for the four cases above: the verdict function distinguishes at
/// all, rather than answering `.silent` to everything.
@Test func theVerdictsAreDistinct() {
  let untouched = Arm64DDC.replyVerdict([UInt8](repeating: Arm64DDC.replySentinel, count: 11))
  let zeros = Arm64DDC.replyVerdict([UInt8](repeating: 0, count: 11))
  let frame = Arm64DDC.replyVerdict(replyFrame(command: 0x10, current: 1, max: 2))
  #expect(untouched != zeros)
  #expect(zeros != frame)
  #expect(frame != untouched)
}

/// A frame that answers a DIFFERENT code than the one asked is not an answer,
/// and it must not end the ladder either (see the retry tests below).
@Test func aFrameAnsweringAnotherCodeIsNotAnAnswer() {
  let frame = replyFrame(command: 0x12, current: 50, max: 100)
  #expect(Arm64DDC.replyVerdict(frame, command: 0x10) == .silent)
  #expect(Arm64DDC.replyVerdict(frame, command: 0x12) == .ok)
}

// MARK: - The retry ladder, driven by a scripted panel

/// One scripted reply per read call: `nil` fails, `[]` reports success and
/// writes nothing, bytes are what the panel puts in the buffer. The last entry
/// repeats once the script runs out.
///
/// `@unchecked Sendable`: `runTransaction` calls both closures synchronously and
/// has returned before the test reads the counters.
private final class ScriptedPanel: @unchecked Sendable {
  private var replies: [[UInt8]?]
  private var writeResults: [Int32]
  private(set) var writes = 0
  private(set) var reads = 0
  /// Packets and sleeps in the order spent, as `write`, `read` and
  /// `sleep:<microseconds>`; the pacing tests are about that order.
  private(set) var trace: [String] = []

  /// When set, a slept microsecond is a microsecond of fake time. I2C calls cost
  /// nothing on this clock, so every gap is a sleep.
  var clock: FakeClock?

  init(_ replies: [[UInt8]?], writeResults: [Int32] = [0], clock: FakeClock? = nil) {
    self.replies = replies
    self.writeResults = writeResults
    self.clock = clock
  }

  var transport: Arm64DDC.I2CTransport {
    Arm64DDC.I2CTransport(
      write: { _, _, _ in
        self.writes += 1
        self.trace.append("write")
        return self.writeResults.count > 1 ? self.writeResults.removeFirst() : (self.writeResults.first ?? 0)
      },
      read: { _, buffer, count in
        self.reads += 1
        self.trace.append("read")
        let reply = self.replies.count > 1 ? self.replies.removeFirst() : (self.replies.first ?? nil)
        guard let reply, !reply.isEmpty else { return reply == nil ? -1 : 0 }
        reply.withUnsafeBytes { bytes in
          buffer.copyMemory(from: bytes.baseAddress!, byteCount: min(bytes.count, Int(count)))
        }
        return 0
      },
      sleep: {
        self.trace.append("sleep:\($0)")
        self.clock?.advance(microseconds: UInt64($0))
      }
    )
  }
}

/// Time the tests move by hand. Starts away from zero so rewinding stays in range.
///
/// `@unchecked Sendable`: every mutation happens on the test's own thread, from
/// closures `runTransaction` calls synchronously.
private final class FakeClock: @unchecked Sendable {
  private var nanos: UInt64 = 1_000_000_000

  var reader: @Sendable () -> UInt64 { { self.nanos } }
  func advance(microseconds: UInt64) { self.nanos += microseconds * 1000 }
  func rewind(microseconds: UInt64) { self.nanos -= microseconds * 1000 }
}

private func runRead(
  _ panel: ScriptedPanel, command: UInt8 = 0x10, reply: inout [UInt8]
) -> Arm64DDC.TransactionOutcome {
  var send: [UInt8] = [command]
  return Arm64DDC.runTransaction(
    service: nil, send: &send, reply: &reply, replyCommand: command,
    writeSleepTime: 0, numOfWriteCycles: nil, readSleepTime: 0,
    numOfRetryAttemps: 4, retrySleepTime: 0, pacer: nil, transport: panel.transport
  )
}

/// The write lands, the reply read fails, and the transaction used to return on
/// attempt one carrying the write's success.
@Test func aFailedReplyReadSpendsTheWholeLadder() {
  let panel = ScriptedPanel([nil])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .silent)
  #expect(panel.writes == 5)
  #expect(panel.reads == 5)
}

/// A read call that succeeds and writes nothing must not read as a panel
/// answering zeros. Delete the sentinel fill and this test says `answeredZeros`.
@Test func aReadThatWritesNothingIsSilenceRatherThanZeros() {
  let panel = ScriptedPanel([[]])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .silent)
}

/// The panel that lies: a checksum-clean frame answering a DIFFERENT code is
/// retried like any other failed read, and the good frame behind it wins.
@Test func aFrameAnsweringAnotherCodeIsRetriedAndTheGoodOneWins() {
  let asked = replyFrame(command: 0x10, current: 50, max: 100)
  let panel = ScriptedPanel([replyFrame(command: 0x12, current: 99, max: 99), asked])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .ok)
  #expect(reply == asked)
  #expect(panel.reads == 2)
}

/// The control for the test above: with nothing better behind it, the lying
/// panel is silence rather than an answer, and it costs the whole ladder.
@Test func aFrameAnsweringAnotherCodeAloneIsSilence() {
  let panel = ScriptedPanel([replyFrame(command: 0x12, current: 99, max: 99)])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .silent)
  #expect(panel.reads == 5)
}

/// Zeros on the bus are the more specific finding and outlive a later attempt
/// that got nothing usable.
@Test func zerosSurviveALaterRejectedFrame() {
  let panel = ScriptedPanel([
    [UInt8](repeating: 0, count: 11),
    replyFrame(command: 0x12, current: 9, max: 9),
  ])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .answeredZeros)
}

/// And a valid frame still supersedes them: a panel that answers is not reported
/// write-only because one attempt caught it mid-sentence.
@Test func aValidFrameSupersedesEarlierZeros() {
  let panel = ScriptedPanel([
    [UInt8](repeating: 0, count: 11),
    replyFrame(command: 0x10, current: 30, max: 100),
  ])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .ok)
}

// MARK: - A refusal is an answer, and it ends the ladder

/// A refused register costs ONE transaction, as it did before the reply frame
/// was validated at all. Retrying re-asks a question the panel answered, and the
/// value controller spends this ladder `pollingTries` times per pass.
@Test func aRefusedRegisterEndsTheLadderOnTheAttemptThatCarriedIt() {
  let panel = ScriptedPanel([refusalFrame(command: 0x10)])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .silent)
  #expect(panel.reads == 1)
  #expect(panel.writes == 1)
}

/// The evidence is unchanged by the early exit: a refusal is not a readable
/// register, so it reads as silence and the skip latch counts it as before.
@Test func aRefusalStillReadsAsSilenceRatherThanAnAnswer() {
  #expect(Arm64DDC.replyVerdict(refusalFrame(command: 0x10), command: 0x10) == .silent)
  #expect(Arm64DDC.attemptVerdict(refusalFrame(command: 0x10), command: 0x10).isRefusal)
}

/// The ordering `isRefusal` rests on: `attemptVerdict` checks the checksum
/// FIRST, so a result code carried in bytes that failed their own integrity
/// check is not the panel answering. `isRefusal` deliberately does not check the
/// checksum itself, so nothing but that ordering keeps a corrupted frame from
/// ending the ladder.
@Test func aRefusalWithABrokenChecksumIsNotAnAnswerAndKeepsRetrying() {
  var corrupted = refusalFrame(command: 0x10)
  corrupted[corrupted.count - 1] &+= 1
  // The frame still SAYS refusal; only the checksum says not to believe it.
  #expect(DDCReplyFrame.isRefusal(corrupted, of: 0x10))
  #expect(!Arm64DDC.attemptVerdict(corrupted, command: 0x10).isRefusal)

  let panel = ScriptedPanel([corrupted])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .silent)
  #expect(panel.reads == 5)
}

/// The control for the early exit, and the rule it rests on: only a result-code
/// refusal is an answer. A malformed, mis-addressed or stale frame proves
/// nothing about the register and keeps every retry it had.
@Test func onlyARefusalEndsTheLadderAndEveryOtherRejectionRetries() {
  // Re-sealed after the edit: a broken checksum would end these transactions
  // for a reason that has nothing to do with which rejection they carry.
  var wrongSource = refusalFrame(command: 0x10)
  wrongSource[0] = 0x6F
  var notAReply = refusalFrame(command: 0x10)
  notAReply[2] = 0xE3
  for frame in [sealed(wrongSource), sealed(notAReply), refusalFrame(command: 0x12)] {
    let panel = ScriptedPanel([frame])
    var reply = [UInt8](repeating: 0, count: 11)
    #expect(runRead(panel, reply: &reply) == .silent)
    #expect(panel.reads == 5)
  }
}

/// A refusal on attempt two does not erase what attempt one proved: zeros are
/// the more specific finding and the fold keeps them.
@Test func aRefusalDoesNotEraseEarlierZeros() {
  let panel = ScriptedPanel([
    [UInt8](repeating: 0, count: 11),
    refusalFrame(command: 0x10),
  ])
  var reply = [UInt8](repeating: 0, count: 11)
  #expect(runRead(panel, reply: &reply) == .answeredZeros)
  #expect(panel.reads == 2)
}

/// The write path, which none of this changes: an acknowledged write with no
/// reply expected ends the transaction on the first attempt.
@Test func anAcknowledgedWriteReturnsOnTheFirstAttempt() {
  let panel = ScriptedPanel([])
  var send: [UInt8] = [0x10, 0x00, 0x32]
  var reply: [UInt8] = []
  let outcome = Arm64DDC.runTransaction(
    service: nil, send: &send, reply: &reply, replyCommand: nil,
    writeSleepTime: 0, numOfWriteCycles: nil, readSleepTime: 0,
    numOfRetryAttemps: 4, retrySleepTime: 0, pacer: nil, transport: panel.transport
  )
  #expect(outcome == .ok)
  #expect(panel.writes == 1)
  #expect(panel.reads == 0)
}

// MARK: - The bus floor, measured rather than assumed

/// Every transaction below runs through this: a scripted panel, a pacer on the
/// same fake clock the sleeps advance, and a 10 ms floor.
private func runPaced(
  _ panel: ScriptedPanel, pacer: DDCBusPacer?, send: [UInt8], replyLength: Int = 0,
  writeCycles: UInt8? = nil, retries: UInt8 = 4
) -> Arm64DDC.TransactionOutcome {
  var send = send
  var reply = [UInt8](repeating: 0, count: replyLength)
  return Arm64DDC.runTransaction(
    service: nil, send: &send, reply: &reply, replyCommand: send.count == 1 ? send[0] : nil,
    writeSleepTime: 10000, numOfWriteCycles: writeCycles, readSleepTime: 50000,
    numOfRetryAttemps: retries, retrySleepTime: 20000, pacer: pacer,
    transport: panel.transport
  )
}

private let setBrightness: [UInt8] = [0x10, 0x00, 0x32]

/// A pacer whose display has been quiet for longer than the floor. Construction
/// seeds the bus as JUST USED, so an idle-bus test has to let that seed age.
private func pacerOnAQuietBus(_ clock: FakeClock) -> DDCBusPacer {
  let pacer = DDCBusPacer(now: clock.reader)
  clock.advance(microseconds: 60000)
  return pacer
}

/// The 10 ms used to be spent before every packet, even the first to reach a bus
/// quiet for minutes, on a transaction measured at about 14 ms.
@Test func aWriteOnAQuietBusGoesOutWithoutWaiting() {
  let clock = FakeClock()
  let panel = ScriptedPanel([], clock: clock)
  #expect(runPaced(panel, pacer: pacerOnAQuietBus(clock), send: setBrightness) == .ok)
  #expect(panel.trace == ["write"])
}

/// And the gap that exists today survives: a burst still puts 10 ms between
/// packets, because the floor is measured from the last call rather than
/// skipped.
@Test func backToBackWritesKeepTheirTenMillisecondGap() {
  let clock = FakeClock()
  let panel = ScriptedPanel([], clock: clock)
  let pacer = pacerOnAQuietBus(clock)
  _ = runPaced(panel, pacer: pacer, send: setBrightness)
  _ = runPaced(panel, pacer: pacer, send: setBrightness)
  #expect(panel.trace == ["write", "sleep:10000", "write"])
}

/// Only the remainder is owed. A bus quiet for 6 of the 10 ms waits 4, not 10
/// and not nothing.
@Test func aPartlyIdleBusWaitsOnlyTheRemainder() {
  let clock = FakeClock()
  let panel = ScriptedPanel([], clock: clock)
  let pacer = pacerOnAQuietBus(clock)
  _ = runPaced(panel, pacer: pacer, send: setBrightness)
  clock.advance(microseconds: 6000)
  _ = runPaced(panel, pacer: pacer, send: setBrightness)
  #expect(panel.trace == ["write", "sleep:4000", "write"])
}

/// A read leaves the bus busy at its REPLY read, so the write behind it is paced
/// from there and keeps its 10 ms; the read's own 50 ms settle is untouched.
@Test func aWriteRightAfterAReadKeepsItsGapAndTheSettleIsUntouched() {
  let clock = FakeClock()
  let panel = ScriptedPanel([replyFrame(command: 0x10, current: 50, max: 100)], clock: clock)
  let pacer = pacerOnAQuietBus(clock)
  #expect(runPaced(panel, pacer: pacer, send: [0x10], replyLength: 11) == .ok)
  _ = runPaced(panel, pacer: pacer, send: setBrightness)
  #expect(panel.trace == ["write", "sleep:50000", "read", "sleep:10000", "write"])
}

/// A read is paced like anything else, so the request behind a fresh write waits
/// its floor. Run twice to show the settle is the same 50 ms either way.
@Test func aReadIsPacedFromTheBusToo() {
  let clock = FakeClock()
  let panel = ScriptedPanel([replyFrame(command: 0x10, current: 50, max: 100)], clock: clock)
  let pacer = pacerOnAQuietBus(clock)
  _ = runPaced(panel, pacer: pacer, send: setBrightness)
  _ = runPaced(panel, pacer: pacer, send: [0x10], replyLength: 11)
  #expect(panel.trace == ["write", "sleep:10000", "write", "sleep:50000", "read"])
}

/// Retries are untouched: the retry sleep and the next attempt's own sleep both
/// stand. Only the FIRST packet of a transaction is paced from the bus.
@Test func aRetryKeepsBothOfItsSleeps() {
  let clock = FakeClock()
  let panel = ScriptedPanel([], writeResults: [-1], clock: clock)
  let outcome = runPaced(
    panel, pacer: pacerOnAQuietBus(clock), send: setBrightness, retries: 1
  )
  #expect(outcome == .silent)
  #expect(panel.writes == 2)
  #expect(panel.trace == ["write", "sleep:20000", "sleep:10000", "write", "sleep:20000"])
}

/// Same rule inside one attempt: a second write cycle is not the first packet,
/// so it keeps the full sleep and the two packets stay 10 ms apart.
@Test func aSecondWriteCycleKeepsItsFullSleep() {
  let clock = FakeClock()
  let panel = ScriptedPanel([], clock: clock)
  _ = runPaced(
    panel, pacer: pacerOnAQuietBus(clock), send: setBrightness, writeCycles: 2
  )
  #expect(panel.trace == ["write", "sleep:10000", "write"])
}

/// A refresh retires the service, so the replacement starts by assuming the bus
/// was busy; otherwise its first packet could follow the retired service's traffic
/// by microseconds, silently on the write-only MAG.
@Test func aFreshServiceStartsOwingTheFullFloor() {
  let clock = FakeClock()
  let panel = ScriptedPanel([], clock: clock)
  _ = runPaced(panel, pacer: DDCBusPacer(now: clock.reader), send: setBrightness)
  #expect(panel.trace == ["sleep:10000", "write"])
}

/// No pacer, no memory of the bus, so the floor is paid in full. The control for
/// the tests above.
@Test func aTransactionWithNoPacerPaysTheFloorInFull() {
  let panel = ScriptedPanel([])
  _ = runPaced(panel, pacer: nil, send: setBrightness)
  #expect(panel.trace == ["sleep:10000", "write"])
}

/// The arithmetic on its own, including the two ends a ladder test cannot
/// reach: a pacer at the moment it is built, and a clock that went backwards.
@Test func theFloorIsWhatTheBusStillOwes() {
  let clock = FakeClock()
  let pacer = DDCBusPacer(now: clock.reader)
  // Built, not used: the bus is assumed busy, so the whole floor is owed.
  #expect(pacer.deficit(floor: 10000) == 10000)
  pacer.recordBusUse()
  #expect(pacer.deficit(floor: 10000) == 10000)
  clock.advance(microseconds: 4000)
  #expect(pacer.deficit(floor: 10000) == 6000)
  clock.advance(microseconds: 60000)
  #expect(pacer.deficit(floor: 10000) == 0)
  pacer.recordBusUse()
  clock.rewind(microseconds: 5000)
  #expect(pacer.deficit(floor: 10000) == 10000)
}

/// The pacer outlives the service: `DisplayDiscovery.discover()` rebuilds it on
/// every refresh while the retired one can still drain a queued write.
@Test func twoServicesForOneDisplayShareTheFloor() {
  let clock = FakeClock()
  let first = DDCBusPacerRegistry.shared.pacer(for: 0xFACE_0001, now: clock.reader)
  clock.advance(microseconds: 60000)
  #expect(first.deficit(floor: 10000) == 0)
  first.recordBusUse()

  // The rebuild. The clock argument is ignored for a key already registered,
  // which is the point: a new service does not get to restart the floor.
  let second = DDCBusPacerRegistry.shared.pacer(for: 0xFACE_0001, now: clock.reader)
  #expect(second === first)
  #expect(second.deficit(floor: 10000) == 10000)
}

/// And the other direction, which is what a per-display key is for: a write to
/// one panel never delays a write to another.
@Test func twoDisplaysDoNotPaceEachOther() {
  let clock = FakeClock()
  let one = DDCBusPacerRegistry.shared.pacer(for: 0xFACE_0002, now: clock.reader)
  let other = DDCBusPacerRegistry.shared.pacer(for: 0xFACE_0003, now: clock.reader)
  #expect(one !== other)
  clock.advance(microseconds: 60000)
  one.recordBusUse()
  #expect(one.deficit(floor: 10000) == 10000)
  #expect(other.deficit(floor: 10000) == 0)
}

/// The fold's own contract. The ladder returns on a valid frame rather than
/// folding it, so the `.ok` arms exist to keep the function total, not for a path
/// anything takes today.
@Test func theFoldKeepsTheMoreSpecificFinding() {
  #expect(Arm64DDC.fold(.answeredZeros, .silent) == .answeredZeros)
  #expect(Arm64DDC.fold(.silent, .answeredZeros) == .answeredZeros)
  #expect(Arm64DDC.fold(.silent, .silent) == .silent)
  #expect(Arm64DDC.fold(.answeredZeros, .ok) == .ok)
}

// MARK: - What a read outcome publishes

@Test func aFrameWithARealMaximumIsAnAnsweredPanel() {
  let outcome = DDCReadOutcome.frame(current: 50, max: 100)
  #expect(outcome.evidence == .answered)
  #expect(outcome.value?.current == 50)
  #expect(outcome.value?.max == 100)
}

/// A frame carrying a zero maximum is the same admission as a buffer of zeros,
/// and both sites read that mapping from here rather than deriving it twice.
@Test func aFrameWithAZeroMaximumIsTheWriteOnlySignature() {
  #expect(DDCReadOutcome.frame(current: 0, max: 0).evidence == .allZeros)
}

@Test func zerosOnTheBusAndSilenceStaySeparate() {
  #expect(DDCReadOutcome.allZeros.evidence == .allZeros)
  #expect(DDCReadOutcome.allZeros.value == nil)
  #expect(DDCReadOutcome.noReply.evidence == .noReply)
  #expect(DDCReadOutcome.noReply.value == nil)
}

// MARK: - The default a writer with no transport of its own inherits

@Test func aWriterThatOnlyReturnsAValueCannotClaimZerosOnTheBus() async {
  #expect(await FakeDDC(readResult: nil).readOutcome(command: VCP.brightness) == .noReply)
  #expect(
    await FakeDDC(readResult: (current: 0, max: 0)).readOutcome(command: VCP.brightness)
      == .frame(current: 0, max: 0)
  )
  #expect(
    await FakeDDC(readResult: (current: 50, max: 100)).readOutcome(command: VCP.brightness)
      == .frame(current: 50, max: 100)
  )
}
