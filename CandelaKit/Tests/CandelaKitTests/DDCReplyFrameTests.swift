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

  /// The write-only-panel case: reads come back all zeros. Before this guard
  /// that decoded as max 0 / current 0 and was only caught by a `max > 0`
  /// check further up, which cannot tell silence from a genuine zero.
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

  /// The failure that motivated this: a monitor answering a brightness read
  /// with a reply for some other VCP code. The checksum is fine, the bytes
  /// decode, and the resulting `max` compresses the usable range.
  @Test func aReplyEchoingADifferentCommandIsRejected() {
    let frame = goodFrame(command: 0x12)
    #expect(
      DDCReplyFrame.rejection(for: frame, command: 0x10)
        == .echoedDifferentCommand(expected: 0x10, got: 0x12))
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
