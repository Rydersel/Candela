/// Reassembled capability bytes → the string the display meant to send.
///
/// The seam between the wire and `CapabilityString`, and it exists so the
/// parser can stay strict. `outerGroupInterior` requires exactly one
/// parenthesised group, tolerating surrounding whitespace and nothing else,
/// because a string with no outer wrapper otherwise volunteers its own first
/// group and manufactures a denial. Whatever the WIRE adds on top of the
/// display's content comes off here, not by widening what the parser forgives.
///
/// [MEASURED 2026-08-04] A DELL U2725QE ends its capability string with a
/// single NUL byte: `…mswhql(1))\0`, 607 bytes. Untrimmed, the last character
/// is neither `)` nor whitespace, so the whole answer parsed to nil: no codes,
/// no `mccs_ver`, and VCP 0x62 `.unknown` instead of `.unsupported`. That left
/// the volume slider enabled on a panel that provably does not list the volume
/// command (D24 resolves `.unknown` to enabled).
enum CapabilityPayload {
  /// `nil` when the bytes are not a capability string this code can hand on
  /// intact. Never "the display has no capabilities" — that distinction is the
  /// whole of D24, and every caller's `nil` already means a failed read.
  ///
  /// Trailing NULs are trimmed; a NUL anywhere else rejects the payload. A
  /// trailing NUL is a C string terminator, a transport artifact carrying no
  /// content. An interior NUL means the payload we reassembled is not the
  /// string the panel sent, and splicing the halves together hands the parser
  /// something that can parse CLEANLY, which is the only route to
  /// `.unsupported`, the one verdict that greys a control. Manufacturing a
  /// denial out of a damaged read is what D24 forbids.
  ///
  /// Passing an interior NUL through is not safe either:
  /// `"(prot(monitor)\0vcp(10))"` clears every gate the parser has, because the
  /// tag boundary check reads NUL as a non-identifier character just like a
  /// space.
  ///
  /// Only NUL and whitespace are trimmed. NUL has a documented meaning at the
  /// end of a string and other control bytes do not, so dropping those would be
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
