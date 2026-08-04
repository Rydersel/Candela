import Foundation

/// Whether a display implements one VCP feature. Three states, never a Bool
/// (D24): `unknown` is the honest answer to a failed or unintelligible read,
/// and it must resolve to *enabled*, because a false grey removes a working
/// control with no visible reason while a false enable costs one pointless
/// slider.
public enum VCPSupport: Sendable, Equatable {
  case supported
  case unsupported
  case unknown
}

/// Parsing for the DDC/CI Capabilities Request (VCP 0xF3): the wire frames the
/// display answers with, and the MCCS capability string they reassemble into.
///
/// The governing rule, from D24: capability strings are unreliable in the
/// field — monitors truncate them, omit codes they support, and advertise
/// codes they ignore. **Every path that does not fully understand its input
/// returns `.unknown`.** `.unsupported` is reachable only from a string whose
/// vcp list parsed cleanly, end to end, and did not contain the code.
public enum CapabilityString {
  public static func support(forVCP code: UInt8, in capabilities: String) -> VCPSupport {
    // Balance check FIRST (D24's fail-to-.unknown rule). Without it,
    // "(vcp(02 10) 62))" parses "cleanly": body(ofTag:in:) stops at the first
    // depth-0 ')' and yields [02, 10], so a stray close-paren would make us
    // answer .unsupported — i.e. grey a working slider on the word of a monitor
    // whose capabilities string is provably malformed. A string we cannot fully
    // account for earns .unknown, never a denial.
    guard isBalanced(capabilities) else { return .unknown }
    guard let body = body(ofTag: "vcp", in: capabilities) else { return .unknown }
    guard let codes = topLevelCodes(in: body), !codes.isEmpty else { return .unknown }
    return codes.contains(code) ? .supported : .unsupported
  }

  /// Every feature code at depth 0 of the vcp list, or nil when the string is
  /// not fully understood.
  ///
  /// Same D24 rule as `support(forVCP:in:)`, and the same three gates in the
  /// same order: balance check FIRST, whole-tag match, top-level codes only. A
  /// partially-parsed string never produces a partial answer — a pane listing
  /// "the codes we could make out" would read as the display's advertised list
  /// and be wrong in the one direction that matters.
  ///
  /// `nil` and an empty set are deliberately not both reachable: an empty vcp
  /// list is "we did not understand this", not "this display advertises
  /// nothing". Collapsing the two would let a truncated read render as a
  /// display that genuinely supports no features at all.
  public static func codes(in capabilities: String) -> Set<UInt8>? {
    guard isBalanced(capabilities) else { return nil }
    guard let body = body(ofTag: "vcp", in: capabilities) else { return nil }
    guard let codes = topLevelCodes(in: body), !codes.isEmpty else { return nil }
    return codes
  }

  /// The body of a top-level tag — `tag("mccs_ver", in:)` → "2.1".
  ///
  /// nil when the tag is absent, the string is unbalanced, or the group never
  /// closes. An empty STRING is a different answer from nil: the tag was
  /// declared and its body is blank (DT30 rule e). A caller that flattened the
  /// two would report "the display did not say" and "the display said nothing"
  /// as the same fact, which is exactly the conflation D24 and DT30 exist to
  /// prevent.
  public static func tag(_ name: String, in capabilities: String) -> String? {
    guard isBalanced(capabilities) else { return nil }
    guard let body = body(ofTag: name, in: capabilities) else { return nil }
    return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Every '(' closes, nothing closes that never opened.
  private static func isBalanced(_ capabilities: String) -> Bool {
    var depth = 0
    for character in capabilities {
      if character == "(" { depth += 1 }
      if character == ")" {
        depth -= 1
        if depth < 0 { return false }
      }
    }
    return depth == 0
  }

  /// The characters between `<name>(` and its matching `)`, nested groups
  /// included. `nil` when there is no such tag or the group never closes (the
  /// truncation case).
  ///
  /// GENERALISED from `vcpBody` so `tag(_:in:)` inherits the whole-tag
  /// boundary check already pinned by tests: "vcpname(" and "mccs_vcp(" are
  /// different keys from "vcp(", and matching them would invent a list out of
  /// unrelated data. The same check is what stops `tag("type", …)` from
  /// answering with `prot_type(`'s body — one field's value reported as
  /// another's is a fact invented out of unrelated data, the same defect in a
  /// different costume.
  ///
  /// The scan is deliberately hand-rolled rather than a regex: capability
  /// strings nest, and only a depth counter can tell `60(0F 11 12)`'s closing
  /// paren from the vcp list's own.
  static func body(ofTag name: String, in capabilities: String) -> [Character]? {
    let tag = Array(name.lowercased())
    guard !tag.isEmpty else { return nil }
    let chars = Array(capabilities)
    var index = 0
    // `index + tag.count` must be a valid subscript for the '(' check, so the
    // scan stops one character before the end — a name longer than the string
    // simply never enters the loop.
    while index + tag.count + 1 <= chars.count {
      let isTag = chars[index + tag.count] == "("
        && (0 ..< tag.count).allSatisfy { chars[index + $0].lowercased() == String(tag[$0]) }
      let boundaryBefore = index == 0
        || (!chars[index - 1].isLetter && !chars[index - 1].isNumber && chars[index - 1] != "_")
      if isTag, boundaryBefore {
        var depth = 1
        var body: [Character] = []
        var cursor = index + tag.count + 1
        while cursor < chars.count {
          let character = chars[cursor]
          if character == "(" { depth += 1 }
          if character == ")" {
            depth -= 1
            if depth == 0 { return body }
          }
          body.append(character)
          cursor += 1
        }
        // The tag opened and never closed: truncation. Return nil rather than
        // resuming the scan — a second `vcp(` later in a truncated string is
        // not evidence we can trust either.
        return nil
      }
      index += 1
    }
    return nil
  }

  /// Feature codes at depth 0 of the vcp list. Codes inside a nested group are
  /// that feature's permitted VALUES, not features — "60(01 03 62)" means
  /// input-source 62, which has nothing to do with audio volume.
  private static func topLevelCodes(in body: [Character]) -> Set<UInt8>? {
    var codes: Set<UInt8> = []
    var token = ""
    var depth = 0
    func flush() -> Bool {
      defer { token = "" }
      guard !token.isEmpty else { return true }
      guard token.count == 2, let code = UInt8(token, radix: 16) else { return false }
      codes.insert(code)
      return true
    }
    for character in body {
      if character == "(" {
        // The token that precedes a nested list is still a feature code.
        guard flush() else { return nil }
        depth += 1
        continue
      }
      if character == ")" {
        depth -= 1
        guard depth >= 0 else { return nil }
        continue
      }
      guard depth == 0 else { continue }
      if character.isWhitespace {
        guard flush() else { return nil }
        continue
      }
      token.append(character)
    }
    guard depth == 0, flush() else { return nil }
    return codes
  }

  /// One capabilities reply frame → its payload bytes.
  ///
  /// Layout: `[source 0x6E][0x80 | messageLength][0xE3][offsetHi][offsetLo]
  /// [payload…][checksum]`. The checksum covers **exactly the framed bytes**,
  /// not the whole read buffer — a short fragment leaves the buffer's tail
  /// undefined, so the fork's whole-buffer xor (correct for the fixed 11-byte
  /// Get-VCP reply) would reject every valid short answer here.
  ///
  /// An empty payload is the terminator: the display has no more string.
  static func fragment(fromFrame reply: [UInt8], expectedOffset: UInt16) -> [UInt8]? {
    guard reply.count >= 6 else { return nil }
    let messageLength = Int(reply[1] & 0x7F)
    // opcode + two offset bytes is the floor.
    guard messageLength >= 3 else { return nil }
    let frameLength = 2 + messageLength + 1
    guard frameLength <= reply.count else { return nil }
    var checksum: UInt8 = 0x50
    for index in 0 ..< (frameLength - 1) { checksum ^= reply[index] }
    guard checksum == reply[frameLength - 1] else { return nil }
    guard reply[2] == 0xE3 else { return nil }
    guard UInt16(reply[3]) * 256 + UInt16(reply[4]) == expectedOffset else { return nil }
    return Array(reply[5 ..< (frameLength - 1)])
  }
}
