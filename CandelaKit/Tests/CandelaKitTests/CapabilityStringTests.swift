import Testing
@testable import CandelaKit

@Suite("DDC/CI capability string (D24)")
struct CapabilityStringTests {
  /// Shape of a real MCCS 2.x reply: an outer group, tagged sub-groups, and a
  /// vcp list whose entries may carry their own value lists.
  static let realistic = "(prot(monitor)type(lcd)model(MAG341C)cmds(01 02 03 07 0C E3 F3)"
    + "vcp(02 04 05 08 10 12 14(05 08 0B) 16 18 1A 52 60(01 03 11 12) 62 8D AC AE B6 C0 C6 C8 DF)"
    + "mccs_ver(2.2))"

  @Test func listedCodeIsSupported() {
    #expect(CapabilityString.support(forVCP: 0x62, in: Self.realistic) == .supported)
    #expect(CapabilityString.support(forVCP: 0x10, in: Self.realistic) == .supported)
    #expect(CapabilityString.support(forVCP: 0x8D, in: Self.realistic) == .supported)
  }

  @Test func absentCodeInAWellFormedListIsTheOnlyDenial() {
    // The single case D24 lets grey the slider: the string parsed cleanly and
    // the monitor did not list 62.
    let noVolume = "(prot(monitor)type(lcd)vcp(02 10 12 14(05 08) 60(01 03) 8D)mccs_ver(2.1))"
    #expect(CapabilityString.support(forVCP: 0x62, in: noVolume) == .unsupported)
  }

  @Test func nestedValueListsAreNotMistakenForCodes() {
    // 62 here is a *value* of feature 60 (input source), not a feature.
    let nested = "(vcp(02 10 60(01 03 62) 8D))"
    #expect(CapabilityString.support(forVCP: 0x62, in: nested) == .unsupported)
    #expect(CapabilityString.support(forVCP: 0x60, in: nested) == .supported)
  }

  @Test func caseAndWhitespaceDoNotMatter() {
    #expect(CapabilityString.support(forVCP: 0x62, in: "(VCP(02\n10\t62))") == .supported)
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp( 02  10  62 ))") == .supported)
  }

  @Test func truncatedStringIsUnknownNeverUnsupported() {
    // Monitors truncate. An unterminated vcp( group tells us nothing about
    // what was cut off, so it must NOT read as a denial (D24).
    let truncated = "(prot(monitor)type(lcd)cmds(01 02 03)vcp(02 04 05 08 10 12 14(05"
    #expect(CapabilityString.support(forVCP: 0x62, in: truncated) == .unknown)
  }

  @Test func missingOrEmptyVCPListIsUnknown() {
    #expect(CapabilityString.support(forVCP: 0x62, in: "(prot(monitor)type(lcd))") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp())") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x62, in: "") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x62, in: "   ") == .unknown)
  }

  @Test func tokensWeDoNotUnderstandPoisonTheWholeVerdict() {
    // A code is exactly two hex digits. Anything else means we are not reading
    // what we think we are reading — fail to .unknown, never to .unsupported.
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(02 10 hello))") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(2 10 12))") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(002 010))") == .unknown)
  }

  @Test func adversarialGroupingIsRejectedNotGuessedAt() {
    // Unbalanced in the other direction: a stray close-paren inside the list.
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(02 10) 62))") == .unknown)
    // Deeply nested garbage must not leak a top-level code.
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(60(01(62))))") == .unsupported)
    // A capabilities string that is nothing but the tag.
    #expect(CapabilityString.support(forVCP: 0x62, in: "vcp(") == .unknown)
    // Non-ASCII bytes decoded to replacement characters (what a garbled read
    // produces) must poison the verdict, not be skipped.
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(02 \u{FFFD}\u{FFFD} 62))") == .unknown)
  }

  @Test func vcpnameIsNotTheVCPList() {
    // "vcpname(...)" appears in some strings; matching it would invent a list.
    #expect(CapabilityString.support(forVCP: 0x62, in: "(type(lcd)vcpname(62))") == .unknown)
    // ...and neither is a key that merely ends in "vcp".
    #expect(CapabilityString.support(forVCP: 0x62, in: "(mccs_vcp(62))") == .unknown)
  }

  // MARK: - Wire frames (shared by both architectures)

  /// Builds a well-formed 0xE3 capabilities reply frame, padded to the 38-byte
  /// buffer the transport always reads.
  static func frame(offset: UInt16, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = [0x6E, UInt8(0x80 | (payload.count + 3)), 0xE3,
                          UInt8(offset >> 8), UInt8(offset & 0xFF)]
    bytes.append(contentsOf: payload)
    var checksum: UInt8 = 0x50
    for byte in bytes { checksum ^= byte }
    bytes.append(checksum)
    return bytes + [UInt8](repeating: 0xFF, count: 38 - bytes.count)
  }

  @Test func wellFormedFrameYieldsItsPayload() {
    let payload = Array("(vcp(62".utf8)
    #expect(CapabilityString.fragment(fromFrame: Self.frame(offset: 0, payload: payload),
                                      expectedOffset: 0) == payload)
  }

  @Test func emptyPayloadIsTheTerminator() {
    #expect(CapabilityString.fragment(fromFrame: Self.frame(offset: 32, payload: []),
                                      expectedOffset: 32) == [])
  }

  @Test func badChecksumWrongOpcodeAndOffsetMismatchAllReject() {
    var corrupt = Self.frame(offset: 0, payload: [0x41, 0x42])
    corrupt[5] ^= 0x01  // last payload byte, checksum no longer matches
    #expect(CapabilityString.fragment(fromFrame: corrupt, expectedOffset: 0) == nil)

    var wrongOp = Self.frame(offset: 0, payload: [0x41])
    wrongOp[2] = 0x02   // a Get-VCP reply, not a capabilities reply
    #expect(CapabilityString.fragment(fromFrame: wrongOp, expectedOffset: 0) == nil)

    // The MAG's all-zeros answer: length 0, no opcode, nothing.
    #expect(CapabilityString.fragment(fromFrame: [UInt8](repeating: 0, count: 38),
                                      expectedOffset: 0) == nil)
    // A display that echoes the wrong offset is not answering our question.
    #expect(CapabilityString.fragment(fromFrame: Self.frame(offset: 0, payload: [0x41]),
                                      expectedOffset: 32) == nil)
    // A length byte claiming more than the buffer holds.
    var overlong = Self.frame(offset: 0, payload: [0x41])
    overlong[1] = 0x80 | 60
    #expect(CapabilityString.fragment(fromFrame: overlong, expectedOffset: 0) == nil)
  }

  @Test func truncatedBuffersNeverIndexOutOfBounds() {
    // A bus that returns fewer bytes than the frame needs must be a `nil`,
    // never a crash: this is the shape a half-answered fragment arrives in.
    //
    // DEVIATION from the task brief, which looped `0 ..< good.count` (38) and
    // expected `nil` for every prefix. That assertion is false against the
    // brief's own implementation and would have been a permanently red test:
    // the frame here is 9 bytes (5 header + 3 payload + checksum) inside a
    // 38-byte buffer, and `fragment` derives the frame length from the length
    // byte precisely so it can validate a short answer sitting in a long
    // buffer. Every prefix of length >= 9 therefore contains the WHOLE frame
    // and must decode — a `nil` there would reject every real fragment, since
    // the transport always reads 38 bytes for a frame that is almost always
    // shorter. The genuine boundary is 9: below it, nil; at or above it, the
    // payload. Both halves are asserted.
    let good = Self.frame(offset: 0, payload: [0x41, 0x42, 0x43])
    let frameLength = 9
    for length in 0 ..< frameLength {
      #expect(CapabilityString.fragment(fromFrame: Array(good.prefix(length)),
                                        expectedOffset: 0) == nil, "prefix \(length)")
    }
    for length in frameLength ... good.count {
      #expect(CapabilityString.fragment(fromFrame: Array(good.prefix(length)),
                                        expectedOffset: 0) == [0x41, 0x42, 0x43], "prefix \(length)")
    }
  }
}
