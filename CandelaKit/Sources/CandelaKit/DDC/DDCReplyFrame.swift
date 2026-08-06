import Foundation

/// Validation of a DDC/CI Get VCP Feature reply frame.
///
/// Pure and testable on purpose: the arm64 transport previously accepted any
/// frame whose checksum happened to come out right, then read bytes 6–9 as the
/// max and current values. A checksum is a 1-in-256 guard on its own — a
/// monitor that answers a Get VCP with stale bytes, or answers a DIFFERENT VCP
/// code than the one asked for, produced a plausible-looking `max` that
/// silently compressed the whole brightness range.
///
/// The Intel transport has always checked the op code and result code
/// (`IntelDDC.swift`). This is the same contract, expressed once, so the two
/// transports cannot drift apart again.
enum DDCReplyFrame {
  /// Byte 0 — the display's source address on the DDC/CI bus.
  static let sourceAddress: UInt8 = 0x6E
  /// Byte 2 — "VCP Feature Reply".
  static let getVCPReplyOpCode: UInt8 = 0x02
  /// Byte 3 — 0x00 is "no error"; 0x01 means the display refused the code.
  static let resultCodeNoError: UInt8 = 0x00

  /// The 11-byte frame a Get VCP reply must be.
  static let expectedLength = 11

  enum Rejection: Equatable {
    case wrongLength(Int)
    case wrongSourceAddress(UInt8)
    case notAVCPReply(UInt8)
    case displayReportedError(UInt8)
    case echoedDifferentCommand(expected: UInt8, got: UInt8)
  }

  /// Why this frame is not a usable answer to `command`, or nil if it is.
  ///
  /// Returning the REASON rather than a bool is what lets `DDCReadEvidence`
  /// distinguish "the panel does not answer reads" from "the panel refused
  /// this particular code" — two facts a caller must not conflate.
  static func rejection(for reply: [UInt8], command: UInt8) -> Rejection? {
    guard reply.count == expectedLength else { return .wrongLength(reply.count) }
    guard reply[0] == sourceAddress else { return .wrongSourceAddress(reply[0]) }
    guard reply[2] == getVCPReplyOpCode else { return .notAVCPReply(reply[2]) }
    guard reply[3] == resultCodeNoError else { return .displayReportedError(reply[3]) }
    guard reply[4] == command else {
      return .echoedDifferentCommand(expected: command, got: reply[4])
    }
    return nil
  }

  /// Big-endian 16-bit read.
  ///
  /// Spelled with the widening BEFORE the shift. `UInt16(high << 8)` shifts in
  /// `UInt8` and is always zero — the bug this helper exists to make
  /// unrepeatable.
  static func value(high: UInt8, low: UInt8) -> UInt16 {
    UInt16(high) << 8 | UInt16(low)
  }
}
