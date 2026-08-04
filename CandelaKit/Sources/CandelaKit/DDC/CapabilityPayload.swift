/// Reassembled capability bytes → the string the display meant to send.
///
/// This is the seam between the wire and `CapabilityString`, and it exists so
/// the parser can stay strict. `outerGroupInterior` requires a capability
/// string to be exactly one parenthesised group, tolerating surrounding
/// whitespace and nothing else — a rule that is load-bearing (a string with no
/// outer wrapper otherwise volunteers its own first group and manufactures a
/// denial out of something that is not a capability string at all). Anything
/// the WIRE adds on top of the display's content therefore has to come off
/// here, before the parser sees it, rather than by widening what the parser
/// forgives.
///
/// [MEASURED 2026-08-04] A DELL U2725QE ends its capability string with a
/// single NUL byte: `…mswhql(1))\0`, 607 bytes. Untrimmed, the last character
/// is neither `)` nor whitespace, so the whole 606-byte answer parsed to nil —
/// `codes(in:)` nil instead of 44 codes, `mccs_ver` nil instead of "2.1", and
/// VCP 0x62 `.unknown` instead of `.unsupported`. That left the volume slider
/// enabled on a panel that provably does not list the volume command (D24
/// resolves `.unknown` to enabled), and made the diagnostics pane say Candela
/// "could not read a command list out of this display's description" about a
/// display that answered completely.
enum CapabilityPayload {
  /// `nil` when the bytes are not a capability string this code can hand on
  /// intact. Never "the display has no capabilities" — that distinction is the
  /// whole of D24, and every caller's `nil` already means a failed read.
  ///
  /// **Trailing NULs are trimmed; a NUL anywhere else rejects the payload.**
  /// The two are different animals and the asymmetry is deliberate:
  ///
  /// - A **trailing** NUL is a C string terminator. It is a transport artifact
  ///   carrying no content, the panel's `strcpy` showing through, and dropping
  ///   it loses nothing the display said.
  /// - An **interior** NUL is not a terminator. It means the payload we
  ///   reassembled is not the string the panel sent — a hole, inter-fragment
  ///   padding, or an offset bug. Splicing the two halves together would hand
  ///   the parser something that can parse *cleanly*, and a clean parse is the
  ///   only route to `.unsupported`, the one verdict that greys a control.
  ///   Manufacturing a denial out of a damaged read is precisely what D24
  ///   forbids.
  ///
  /// Leaving an interior NUL in place is not safe either, which is why this
  /// rejects rather than passes through: `"(prot(monitor)\0vcp(10))"` clears
  /// every gate the parser has — it is balanced, it is one wrapped group, and
  /// the tag boundary check reads NUL as a non-identifier character just like a
  /// space — so it reaches `.unsupported` on the strength of bytes we know are
  /// wrong. Pinned in `CapabilityPayloadTests`.
  ///
  /// Only NUL and whitespace are trimmed. Other control bytes are left in, to
  /// be rejected downstream: NUL has a documented meaning at the end of a
  /// string and they do not, so treating them as removable junk would be
  /// guessing at the display's intent instead of reading it.
  static func string(from bytes: [UInt8]) -> String? {
    var start = bytes.startIndex
    var end = bytes.endIndex
    while end > start, bytes[end - 1] == 0x00 || isASCIIWhitespace(bytes[end - 1]) { end -= 1 }
    while start < end, isASCIIWhitespace(bytes[start]) { start += 1 }
    let trimmed = bytes[start ..< end]
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains(0x00) else { return nil }
    // Capability strings are ASCII; anything else decodes to replacement
    // characters and fails the parser's two-hex-digit rule → .unknown.
    return String(decoding: trimmed, as: UTF8.self)
  }

  /// Space, tab, newline, carriage return, vertical tab, form feed — the set
  /// `Character.isWhitespace` recognises in the ASCII range, matched on bytes
  /// so the trim happens before any decoding.
  private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || (0x09 ... 0x0D).contains(byte)
  }
}
