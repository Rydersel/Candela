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
    // "(vcp(02 10) 62))" parses "cleanly": vcpBody stops at the first depth-0
    // ')' and yields [02, 10], so a stray close-paren would make us answer
    // .unsupported — i.e. grey a working slider on the word of a monitor whose
    // capabilities string is provably malformed. A string we cannot fully
    // account for earns .unknown, never a denial.
    guard isBalanced(capabilities) else { return .unknown }
    guard let body = vcpBody(capabilities) else { return .unknown }
    guard let codes = topLevelCodes(in: body), !codes.isEmpty else { return .unknown }
    return codes.contains(code) ? .supported : .unsupported
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

  /// The characters between `vcp(` and its matching `)`, nested groups
  /// included. `nil` when there is no vcp list or the group never closes (the
  /// truncation case).
  private static func vcpBody(_ capabilities: String) -> [Character]? {
    let chars = Array(capabilities)
    var index = 0
    while index + 4 <= chars.count {
      // Must be the *whole* tag: "vcpname(" and "mccs_vcp(" are different keys
      // and matching them would invent a list out of unrelated data.
      let isTag = chars[index].lowercased() == "v"
        && chars[index + 1].lowercased() == "c"
        && chars[index + 2].lowercased() == "p"
        && chars[index + 3] == "("
      let boundaryBefore = index == 0
        || (!chars[index - 1].isLetter && !chars[index - 1].isNumber && chars[index - 1] != "_")
      if isTag, boundaryBefore {
        var depth = 1
        var body: [Character] = []
        var cursor = index + 4
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
