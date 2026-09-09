import Foundation
import Testing

@testable import CandelaKit

@Suite("DDC reply frame validation")
struct DDCReplyFrameTests {
  /// A well-formed Get VCP reply for brightness: max 100, current 42.
  private func goodFrame(command: UInt8 = 0x10, max: UInt16 = 100, current: UInt16 = 42) -> [UInt8] {
    [
      0x6E, 0x88, 0x02, 0x00, command, 0x00,
      UInt8(max >> 8), UInt8(max & 0xFF),
      UInt8(current >> 8), UInt8(current & 0xFF),
      0x00,
    ]
  }

  @Test func aWellFormedReplyIsAccepted() {
    #expect(DDCReplyFrame.rejection(for: goodFrame(), command: 0x10) == nil)
  }

  /// The write-only-panel case: reads come back all zeros, which used to decode as max 0
  /// and current 0, caught only by a `max > 0` check that cannot tell silence from zero.
  @Test func anAllZeroReplyIsRejected() {
    let zeros = [UInt8](repeating: 0, count: 11)
    #expect(DDCReplyFrame.rejection(for: zeros, command: 0x10) == .wrongSourceAddress(0))
  }

  @Test func aTruncatedReplyIsRejected() {
    #expect(DDCReplyFrame.rejection(for: [0x6E, 0x88], command: 0x10) == .wrongLength(2))
  }

  @Test func aNonVCPReplyIsRejected() {
    var frame = goodFrame()
    frame[2] = 0xE3
    #expect(DDCReplyFrame.rejection(for: frame, command: 0x10) == .notAVCPReply(0xE3))
  }

  @Test func aDisplayReportedErrorIsRejected() {
    var frame = goodFrame()
    frame[3] = 0x01
    #expect(DDCReplyFrame.rejection(for: frame, command: 0x10) == .displayReportedError(0x01))
  }

  /// A monitor answering a brightness read with a reply for another VCP code: the
  /// checksum is fine, the bytes decode, and the resulting `max` compresses the range.
  @Test func aReplyEchoingADifferentCommandIsRejected() {
    let frame = goodFrame(command: 0x12)
    #expect(
      DDCReplyFrame.rejection(for: frame, command: 0x10)
        == .echoedDifferentCommand(expected: 0x10, got: 0x12))
  }

  // MARK: - Which rejections are the panel's own answer

  /// The one rejection that ends the retry ladder, enumerated against every
  /// other one: a result code is a display that parsed the request and said no,
  /// and the rest are frames that never carried an answer at all.
  @Test func onlyAResultCodeRefusalIsTheDisplaysOwnAnswer() {
    var refused = goodFrame()
    refused[3] = 0x01
    #expect(DDCReplyFrame.isRefusal(refused, of: 0x10))

    // A usable answer is not a refusal either: the ladder returns on it for its
    // own reason.
    #expect(!DDCReplyFrame.isRefusal(goodFrame(), of: 0x10))
    #expect(!DDCReplyFrame.isRefusal([UInt8](repeating: 0, count: 11), of: 0x10))
    #expect(!DDCReplyFrame.isRefusal([0x6E, 0x88], of: 0x10))
    var notAReply = goodFrame()
    notAReply[2] = 0xE3
    #expect(!DDCReplyFrame.isRefusal(notAReply, of: 0x10))
    #expect(!DDCReplyFrame.isRefusal(goodFrame(command: 0x12), of: 0x10))
  }

  /// Every non-zero result code, not only the 0x01 the spec names: the field's
  /// meaning is "the display processed this and reports an error", and a panel
  /// answering 0x02 has answered.
  @Test func anyNonZeroResultCodeIsARefusal() {
    for code: UInt8 in [0x01, 0x02, 0xFF] {
      var frame = goodFrame()
      frame[3] = code
      #expect(DDCReplyFrame.isRefusal(frame, of: 0x10))
    }
  }

  /// A result code on a frame naming ANOTHER code is a stale or mis-addressed
  /// reply, not an answer about this one, so it keeps its retries. `rejection`
  /// reports the result code before it reaches the echo, which is why this is
  /// checked separately rather than read off that enum.
  @Test func aResultCodeEchoingAnotherCommandIsNotAnAnswerAboutThisOne() {
    var frame = goodFrame(command: 0x12)
    frame[3] = 0x01
    #expect(DDCReplyFrame.rejection(for: frame, command: 0x10) == .displayReportedError(0x01))
    #expect(!DDCReplyFrame.isRefusal(frame, of: 0x10))
    // The panel that really was asked about 0x12 gets the early exit.
    #expect(DDCReplyFrame.isRefusal(frame, of: 0x12))
  }

  // MARK: - Big-endian decode

  /// The IntelDDC bug, pinned: `UInt16(high << 8)` shifts in UInt8 and yields
  /// zero, dropping the entire high byte of max and current.
  @Test func theHighByteSurvivesTheShift() {
    #expect(DDCReplyFrame.value(high: 0x02, low: 0x58) == 600)
    #expect(DDCReplyFrame.value(high: 0xFF, low: 0xFF) == 65535)
    #expect(DDCReplyFrame.value(high: 0x01, low: 0x00) == 256)
  }

  @Test func aHighByteOfZeroStillDecodes() {
    #expect(DDCReplyFrame.value(high: 0x00, low: 0x64) == 100)
  }
}
