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

/// A real MAG-shaped capability string, plus the malformed variants D24 exists
/// for. Same matrix as the `support(forVCP:in:)` suite above, because the new
/// API inherits the same rule and inheriting a rule is not the same as obeying
/// it.
@Suite("Capability string detail (D24)")
struct CapabilityStringDetailTests {
  private let real = "(prot(monitor)type(LCD)model(MAG341CQR)cmds(01 02 03 07 0C E3 F3)"
    + "vcp(02 04 05 08 10 12 14(01 05 08 0B) 16 18 1A 52 60(0F 11 12) 62 6C 6E 70 8D AC AE B6 C6 C8 C9 D6(01 04 05) DF)"
    + "mccs_ver(2.1))"

  @Test func everyTopLevelCodeIsReportedAndNestedValuesAreNot() {
    let codes = CapabilityString.codes(in: real)
    #expect(codes?.contains(0x10) == true)
    #expect(codes?.contains(0x62) == true)
    #expect(codes?.contains(0x8D) == true)
    #expect(codes?.contains(0x12) == true)
    // 0x0F, 0x11 and 0x05 appear only INSIDE 60(...) and 14(...) as permitted
    // VALUES. 0x05 is separately a top-level code here, so the one that proves
    // the rule is 0x0F.
    #expect(codes?.contains(0x0F) == false)
    #expect(codes?.contains(0x11) == false)
  }

  @Test func theMCCSVersionAndTheDescriptiveTagsAreReadable() {
    #expect(CapabilityString.tag("mccs_ver", in: real) == "2.1")
    #expect(CapabilityString.tag("type", in: real) == "LCD")
    #expect(CapabilityString.tag("model", in: real) == "MAG341CQR")
    #expect(CapabilityString.tag("prot", in: real) == "monitor")
  }

  @Test func anAbsentTagIsNilRatherThanEmpty() {
    #expect(CapabilityString.tag("mswhql", in: real) == nil)
  }

  /// The whole-tag boundary check, generalised. `prot_type(` is a different
  /// key from `type(`, and matching it would report another field's value as
  /// this one's — a fact invented out of unrelated data.
  @Test func aTagOnlyMatchesAWholeTagNeverASuffixOfALongerOne() {
    #expect(CapabilityString.tag("type", in: "(prot_type(RGB)vcp(10))") == nil)
    #expect(CapabilityString.codes(in: "(vcpname(brightness)vcp(10))")?.contains(0x10) == true)
    #expect(CapabilityString.codes(in: "(mccs_vcp(99))") == nil)
  }

  /// D24's fail-to-nil rule, in every shape the field produces. A string we
  /// cannot fully account for earns silence, never a partial answer that reads
  /// like a complete one.
  @Test func anythingWeCannotFullyAccountForIsNilNotAPartialAnswer() {
    // Truncated: the vcp group never closes.
    #expect(CapabilityString.codes(in: "(prot(monitor)vcp(02 10 12") == nil)
    // Unbalanced: a close-paren that never opened.
    #expect(CapabilityString.codes(in: "(vcp(02 10) 62))") == nil)
    #expect(CapabilityString.tag("prot", in: "(prot(monitor)vcp(10) ))") == nil)
    // No vcp tag at all.
    #expect(CapabilityString.codes(in: "(prot(monitor)type(LCD))") == nil)
    // Empty vcp list.
    #expect(CapabilityString.codes(in: "(vcp())") == nil)
    // Non-hex, 1-digit and 3-digit tokens.
    #expect(CapabilityString.codes(in: "(vcp(10 ZZ))") == nil)
    #expect(CapabilityString.codes(in: "(vcp(10 2))") == nil)
    #expect(CapabilityString.codes(in: "(vcp(10 123))") == nil)
    // U+FFFD replacement characters from a lossy ASCII decode.
    #expect(CapabilityString.codes(in: "(vcp(10 \u{FFFD}\u{FFFD}))") == nil)
  }

  /// A tag whose body is empty is a real answer ("declared, and blank") and is
  /// NOT the same as an absent tag. nil ≠ empty (DT30 rule e).
  @Test func aDeclaredButEmptyTagIsEmptyNotAbsent() {
    #expect(CapabilityString.tag("model", in: "(model()vcp(10))") == "")
    #expect(CapabilityString.tag("model", in: "(vcp(10))") == nil)
  }

  /// Degenerate inputs that must not crash or index out of bounds. The empty
  /// string and a bare tag name with no group are what a garbled or
  /// zero-length DDC read decodes to on hardware like the MAG 341C, and both
  /// must be silence rather than a fabricated answer.
  @Test func degenerateInputsAreSilentNotFatal() {
    #expect(CapabilityString.codes(in: "") == nil)
    #expect(CapabilityString.codes(in: "   ") == nil)
    #expect(CapabilityString.tag("", in: real) == nil)
    #expect(CapabilityString.tag("model", in: "") == nil)
    #expect(CapabilityString.tag("mccs_ver", in: "mccs_ver") == nil)
    // A tag name longer than the whole string: the scan must simply not run.
    #expect(CapabilityString.tag("mccs_ver", in: "(m)") == nil)
    // Balanced, but the group we want never closes is unreachable — an
    // unbalanced string is rejected before the scan, which is the point of
    // running the balance check first.
    #expect(CapabilityString.tag("vcp", in: "(vcp(10)") == nil)
  }

  /// A feature code is exactly two ASCII hex digits — no sign, ever.
  ///
  /// `UInt8("+1", radix: 16)` is `1` and `"+1"` is two Characters, so a
  /// `token.count == 2` check that leans on `UInt8(_:radix:)` to reject
  /// non-digits lets a signed token through. Two consequences, the second one
  /// shipping: the pane would report "this display advertises VCP 0x01" from a
  /// token that is not a hex pair, and `support(forVCP:in:)` would answer
  /// `.unsupported` for a string that is provably malformed — greying a working
  /// control, which is the exact inversion of D24's doctrine that an unclear
  /// answer resolves to *enabled*.
  @Test func aSignedTokenIsNotAHexPairAndPoisonsTheWholeString() {
    #expect(CapabilityString.codes(in: "(vcp(+1))") == nil)
    #expect(CapabilityString.codes(in: "(vcp(-0))") == nil)
    #expect(CapabilityString.codes(in: "(vcp(+A))") == nil)
    #expect(CapabilityString.codes(in: "(vcp(+f))") == nil)
    // The shipping consequence, stated as a verdict: never a denial.
    #expect(CapabilityString.support(forVCP: 0x62, in: "(vcp(+1))") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x01, in: "(vcp(+1))") == .unknown)
    // A signed token anywhere poisons the list, not just the token.
    #expect(CapabilityString.codes(in: "(vcp(10 +1 62))") == nil)
  }

  /// ...and rejecting signs must not have cost us any real hex pair. Both
  /// letter cases, the boundary values, and a nested value list.
  @Test func everyGenuineHexPairStillParsesInEitherCase() {
    #expect(CapabilityString.codes(in: "(vcp(0a Ff))") == [0x0A, 0xFF])
    #expect(CapabilityString.codes(in: "(vcp(00 ff FF aA Bb cC dD eE))")
      == [0x00, 0xFF, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
    #expect(CapabilityString.codes(in: "(vcp(10 60(0f 1A) e3))") == [0x10, 0x60, 0xE3])
  }

  /// The tag scan is depth-aware: a tag nested inside another tag's body is
  /// that tag's content, not a top-level field.
  ///
  /// `prot(type(LCD))` is a shape real monitors emit, and a textual scan would
  /// answer `tag("type", …)` with a body that belongs to `prot`. That is one
  /// field's value reported as another's — the same "fact invented out of
  /// unrelated data" the whole-tag boundary check exists to prevent, arriving
  /// by the other door. Only a match immediately inside the outer group counts.
  @Test func aNestedTagIsNotATopLevelTag() {
    #expect(CapabilityString.tag("type", in: "(prot(type(LCD))vcp(10))") == nil)
    #expect(CapabilityString.tag("prot", in: "(prot(type(LCD))vcp(10))") == "type(LCD)")
    // The real top-level list wins over one buried inside another tag's body.
    #expect(CapabilityString.codes(in: "(vcpname(vcp(10))vcp(20))") == [0x20])
    // A tag that exists ONLY nested is absent, not present.
    #expect(CapabilityString.codes(in: "(vcpname(vcp(10)))") == nil)
    #expect(CapabilityString.tag("mccs_ver", in: "(model(mccs_ver(2.1)))") == nil)
  }

  /// "Top-level" is measured against a real wrapper: the whole string must be
  /// one parenthesised group. Anything else earns silence.
  ///
  /// Inferring the wrapper from whichever `(` came first is not merely untidy,
  /// it manufactures denials. `"vcp(vcp(60(01 03)))"` has no outer group, so a
  /// first-paren-wins reading treats the leading `vcp(` as the wrapper, reads
  /// the INNER list as top-level, parses it cleanly, and answers `.unsupported`
  /// for 0x10 — a grey slider derived from a string that is not a capability
  /// string at all. A differential fuzz found this shape to be the *entire*
  /// class of inputs where the depth fix could turn a non-denial into a denial,
  /// which is the one direction D24 forbids.
  ///
  /// The rest is the safe direction and is free at the UI:
  /// `VolumeSliderPolicy.isEnabled` greys on `.unsupported` alone, so a
  /// `.supported → .unknown` move changes no control's state.
  @Test func onlyASingleOuterGroupSpanningTheWholeStringIsACapabilityString() {
    // The shape that would have manufactured a denial.
    #expect(CapabilityString.codes(in: "vcp(vcp(60(01 03)))") == nil)
    #expect(CapabilityString.support(forVCP: 0x10, in: "vcp(vcp(60(01 03)))") == .unknown)
    // No wrapper at all.
    #expect(CapabilityString.codes(in: "vcp(10)") == nil)
    #expect(CapabilityString.support(forVCP: 0x10, in: "vcp(10)") == .unknown)
    #expect(CapabilityString.support(forVCP: 0x62, in: "vcp(10)") == .unknown)
    #expect(CapabilityString.tag("model", in: "model(MAG341CQR)") == nil)
    // Two sibling groups: neither is "the" wrapper.
    #expect(CapabilityString.codes(in: "(vcp(10))(vcp(20))") == nil)
    // A wrapper with anything outside it is not a wrapper.
    #expect(CapabilityString.codes(in: "junk(vcp(10))") == nil)
    #expect(CapabilityString.codes(in: "(vcp(10))junk") == nil)
    // Surrounding whitespace changes no meaning and is tolerated.
    #expect(CapabilityString.codes(in: "  (vcp(10))\n") == [0x10])
    #expect(CapabilityString.tag("model", in: " (model(MAG341CQR)vcp(10)) ") == "MAG341CQR")
  }
}
