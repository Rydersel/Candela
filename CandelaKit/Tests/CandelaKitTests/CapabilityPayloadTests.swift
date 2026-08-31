import Testing
@testable import CandelaKit

/// The seam between the wire and the parser. The whole-string-wrap rule in
/// `CapabilityString.outerGroupInterior` stops an unwrapped string from volunteering its
/// own first group and manufacturing a denial, but it means anything the wire appends has
/// to come off first. The asymmetry between trailing and interior NULs is the decision.
@Suite("Capability payload reassembly (D24)")
struct CapabilityPayloadTests {
  /// [MEASURED 2026-08-04, `candela-probe caps`] The DELL U2725QE's capability string
  /// verbatim, minus the one trailing NUL the panel sends. The quirks are preserved on
  /// purpose (the stray space in `60( 19 0F 11)`, the unspaced `66(00F2)`, the long value
  /// tokens in `F5(...)`): each is real, and a parser change tripping on one fails here.
  static let dell =
    "(prot(monitor)type(lcd)model(U2725QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 "
      + "04 05 06 08 09 0B 0C) 16 18 1A 52 60( 19 0F 11) 66(00F2) 67 68 87 AA(00 01 04 02) AC AE B2 "
      + "B6 C6(01) C8 C9 CA CC(02 03 04 06 09 0A 0D 0E) D6(01 04 05) DC(00 03 05) DF E0(03) E2(00 02 "
      + "04 0C 0D 0F 10 11 13 0B 1B 1A 3D 14 23 24 27 3A) E5 E7(00 01 FF) E8 E9(00 01 02 21 22 24) "
      + "EA(F800 F801 FE) EE EF(0F) F0(00 05 06 09 0A 31 32 34 36 A1) F1 F2 F5(100 200 500 600 700 "
      + "800 900 A00 B00 C00 D00 E00 F00 1000 1100 1101 1102 1103 1104 1105 1106 1200 1300 1400 1500 "
      + "1600 1700 1A00 1B00 1C00 1D00) FE FD)mccs_ver(2.1)mswhql(1))"

  /// Exactly what the wire delivers: the string above plus one NUL terminator.
  static let dellOnTheWire: [UInt8] = Array(dell.utf8) + [0x00]

  // MARK: - The panel that found the bug

  /// The fixture itself, before any trimming question: this string parses end to end.
  @Test func theDellStringParsesCompletely() {
    #expect(Self.dell.count == 606)
    #expect(CapabilityString.codes(in: Self.dell)?.count == 44)
    #expect(CapabilityString.tag("mccs_ver", in: Self.dell) == "2.1")
    #expect(CapabilityString.tag("model", in: Self.dell) == "U2725QE")
    #expect(CapabilityString.tag("type", in: Self.dell) == "lcd")
  }

  /// The user-visible defect in one assertion: 0x62 is absent from a list this display
  /// stated in full, so `.unsupported` is the honest verdict. Before the trim it was
  /// `.unknown`, which D24 resolves to enabled, leaving a live volume slider on a display
  /// that ignores volume writes.
  @Test func theDellDoesNotListVolumeAndSaysSoCleanly() {
    #expect(CapabilityString.support(forVCP: 0x62, in: Self.dell) == .unsupported)
    // Codes it does list, as the other side of the same evidence: a blanket
    // `.unsupported` would be just as wrong.
    #expect(CapabilityString.support(forVCP: VCP.brightness, in: Self.dell) == .supported)
    #expect(CapabilityString.support(forVCP: VCP.contrast, in: Self.dell) == .supported)
  }

  /// The regression, pinned from the wire end: the bytes the panel actually
  /// sends must reach the parser as the string the panel meant.
  @Test func theWireBytesSurviveReassemblyIntact() {
    let reassembled = CapabilityPayload.string(from: Self.dellOnTheWire)
    #expect(reassembled == Self.dell)
    #expect(CapabilityString.codes(in: reassembled ?? "")?.count == 44)
    #expect(CapabilityString.tag("mccs_ver", in: reassembled ?? "") == "2.1")
    #expect(CapabilityString.support(forVCP: 0x62, in: reassembled ?? "") == .unsupported)
  }

  /// What the untrimmed code did: every one of these is a false statement about a
  /// display that answered completely.
  @Test func theUntrimmedBytesWereTheDefect() {
    let untrimmed = String(decoding: Self.dellOnTheWire, as: UTF8.self)
    #expect(CapabilityString.codes(in: untrimmed) == nil)
    #expect(CapabilityString.tag("mccs_ver", in: untrimmed) == nil)
    #expect(CapabilityString.support(forVCP: 0x62, in: untrimmed) == .unknown)
  }

  // MARK: - What comes off, and what does not

  @Test func trailingNULsAndSurroundingWhitespaceComeOff() {
    #expect(CapabilityPayload.string(from: Array("(vcp(10))\0".utf8)) == "(vcp(10))")
    // Some panels pad rather than terminate once.
    #expect(CapabilityPayload.string(from: Array("(vcp(10))\0\0\0".utf8)) == "(vcp(10))")
    // Either order — the trim does not care whether the pad precedes the NUL.
    #expect(CapabilityPayload.string(from: Array("(vcp(10)) \0".utf8)) == "(vcp(10))")
    #expect(CapabilityPayload.string(from: Array("(vcp(10))\0 ".utf8)) == "(vcp(10))")
    #expect(CapabilityPayload.string(from: Array("  (vcp(10))\r\n\0".utf8)) == "(vcp(10))")
  }

  /// Nothing but padding is not an answer. `nil` here means the read failed,
  /// which is the truth: the display sent no content.
  @Test func aPayloadOfNothingButPaddingIsNotAnAnswer() {
    #expect(CapabilityPayload.string(from: []) == nil)
    #expect(CapabilityPayload.string(from: [0x00]) == nil)
    #expect(CapabilityPayload.string(from: Array("   \0\0".utf8)) == nil)
  }

  /// Only NUL and whitespace are trimmable: a trailing 0x01 has no documented meaning,
  /// so removing it would be guessing at the display's intent.
  @Test func otherTrailingControlBytesAreNotTrimmed() {
    let payload = CapabilityPayload.string(from: Array("(vcp(10))".utf8) + [0x01])
    #expect(payload == "(vcp(10))\u{01}")
    #expect(CapabilityString.support(forVCP: 0x10, in: payload ?? "") == .unknown)
  }

  // MARK: - The interior-NUL decision

  /// Interior NULs reject the payload rather than being stripped or passed on. A NUL in
  /// the middle means what we reassembled is not what the panel sent: a hole, padding, or
  /// an offset bug. Stripping it splices the halves into something that parses cleanly,
  /// and a clean parse is the only route to `.unsupported`, the verdict that greys a control.
  @Test func anInteriorNULRejectsThePayload() {
    #expect(CapabilityPayload.string(from: Array("(prot(monitor)\0vcp(10))".utf8)) == nil)
    // Including one that sits inside the vcp list itself.
    #expect(CapabilityPayload.string(from: Array("(vcp(10\0 20))".utf8)) == nil)
    // A leading NUL is interior too: only a TRAILING NUL is a terminator.
    #expect(CapabilityPayload.string(from: Array("\0(vcp(10))".utf8)) == nil)
    // A real terminator after a hole does not redeem the hole.
    #expect(CapabilityPayload.string(from: Array("(prot(monitor)\0vcp(10))\0".utf8)) == nil)
  }

  /// Passing an interior NUL to the parser is not the safe default. Outside the vcp list
  /// a NUL clears every gate: the string is balanced, it is one wrapped group, and the tag
  /// boundary check reads NUL like a space, so it reaches `.unsupported` on bytes known to
  /// be damaged. That is a denial manufactured from a bad read, which D24 forbids.
  @Test func anInteriorNULWouldOtherwiseManufactureADenial() {
    let spliced = "(prot(monitor)\0vcp(10))"
    #expect(CapabilityString.support(forVCP: 0x62, in: spliced) == .unsupported)
    #expect(CapabilityString.codes(in: spliced) == [0x10])
    // Which is why the payload never becomes a String at all.
    #expect(CapabilityPayload.string(from: Array(spliced.utf8)) == nil)
  }

  // MARK: - What the trim must NOT rescue

  /// Trimming removes transport bytes; it does not invent a wrapper for a string that
  /// never had one. Widening the trim until these parse brings back the nine measured
  /// `unknown → .unsupported` moves the rule prevents.
  @Test func trimmingDoesNotRescueAStringWithNoOuterWrapper() {
    for raw in ["vcp(10)", "vcp(vcp(60(01 03)))", "(vcp(10))(vcp(20))", "junk(vcp(10))"] {
      let payload = CapabilityPayload.string(from: Array(raw.utf8) + [0x00])
      #expect(payload == raw)
      #expect(CapabilityString.codes(in: payload ?? "") == nil)
      #expect(CapabilityString.support(forVCP: 0x10, in: payload ?? "") == .unknown)
    }
  }
}
