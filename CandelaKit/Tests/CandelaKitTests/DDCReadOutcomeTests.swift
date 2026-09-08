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

/// One scripted reply per read call: `nil` is a read call that fails, `[]` is a
/// read call that reports success and writes nothing, bytes are what the panel
/// puts in the buffer. The last entry keeps answering once the script runs out,
/// so a test says what it is about and no more.
///
/// `@unchecked Sendable`: `runTransaction` calls both closures synchronously on
/// the calling thread and has returned before the test reads the counters, so
/// there is no concurrent access to confine.
private final class ScriptedPanel: @unchecked Sendable {
  private var replies: [[UInt8]?]
  private(set) var writes = 0
  private(set) var reads = 0

  init(_ replies: [[UInt8]?]) { self.replies = replies }

  var transport: Arm64DDC.I2CTransport {
    Arm64DDC.I2CTransport(
      write: { _, _, _ in
        self.writes += 1
        return 0
      },
      read: { _, buffer, count in
        self.reads += 1
        let reply = self.replies.count > 1 ? self.replies.removeFirst() : (self.replies.first ?? nil)
        guard let reply, !reply.isEmpty else { return reply == nil ? -1 : 0 }
        reply.withUnsafeBytes { bytes in
          buffer.copyMemory(from: bytes.baseAddress!, byteCount: min(bytes.count, Int(count)))
        }
        return 0
      }
    )
  }
}

private func runRead(
  _ panel: ScriptedPanel, command: UInt8 = 0x10, reply: inout [UInt8]
) -> Arm64DDC.TransactionOutcome {
  var send: [UInt8] = [command]
  return Arm64DDC.runTransaction(
    service: nil, send: &send, reply: &reply, replyCommand: command,
    writeSleepTime: 0, numOfWriteCycles: nil, readSleepTime: 0,
    numOfRetryAttemps: 4, retrySleepTime: 0, transport: panel.transport
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

/// The write path, which none of this changes: an acknowledged write with no
/// reply expected ends the transaction on the first attempt.
@Test func anAcknowledgedWriteReturnsOnTheFirstAttempt() {
  let panel = ScriptedPanel([])
  var send: [UInt8] = [0x10, 0x00, 0x32]
  var reply: [UInt8] = []
  let outcome = Arm64DDC.runTransaction(
    service: nil, send: &send, reply: &reply, replyCommand: nil,
    writeSleepTime: 0, numOfWriteCycles: nil, readSleepTime: 0,
    numOfRetryAttemps: 4, retrySleepTime: 0, transport: panel.transport
  )
  #expect(outcome == .ok)
  #expect(panel.writes == 1)
  #expect(panel.reads == 0)
}

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
