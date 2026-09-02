import Foundation

/// Whether a display implements one VCP feature. Three states, never a Bool:
/// `unknown` is the honest answer to a failed or unintelligible read,
/// and it must resolve to *enabled*, because a false grey removes a working
/// control with no visible reason while a false enable costs one pointless
/// slider.
public enum VCPSupport: Sendable, Equatable, CaseIterable {
  case supported
  case unsupported
  case unknown
}

/// Parsing for the DDC/CI Capabilities Request (VCP 0xF3): the wire frames the
/// display answers with, and the MCCS capability string they reassemble into.
///
/// The governing rule: capability strings are unreliable in the
/// field — monitors truncate them, omit codes they support, and advertise
/// codes they ignore. **Every path that does not fully understand its input
/// returns `.unknown`.** `.unsupported` is reachable only from a string whose
/// vcp list parsed cleanly, end to end, and did not contain the code.
public enum CapabilityString {
  public static func support(forVCP code: UInt8, in capabilities: String) -> VCPSupport {
    // Balance check FIRST (the fail-to-.unknown rule). Without it,
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
  /// Same fail-to-.unknown rule as `support(forVCP:in:)` and the same three gates in the
  /// same order: balance check FIRST, whole-tag match at depth 1 (so a `vcp(`
  /// buried inside another tag's body is not mistaken for the list), and
  /// top-level codes only. Those are two separate depth counters, one over tags
  /// and one over codes. A partially-parsed string never produces a partial
  /// answer: a pane listing "the codes we could make out" reads as the display's
  /// advertised list.
  ///
  /// `nil` and an empty set are deliberately not both reachable: an empty vcp
  /// list means "we did not understand this", not "this display advertises
  /// nothing".
  public static func codes(in capabilities: String) -> Set<UInt8>? {
    guard isBalanced(capabilities) else { return nil }
    guard let body = body(ofTag: "vcp", in: capabilities) else { return nil }
    guard let codes = topLevelCodes(in: body), !codes.isEmpty else { return nil }
    return codes
  }

  /// The body of a top-level tag — `tag("mccs_ver", in:)` → "2.1".
  ///
  /// "Top-level" is literal: only a tag immediately inside the outer group
  /// answers. `tag("type", in: "(prot(type(LCD))vcp(10))")` is nil, not "LCD",
  /// because that `type` belongs to `prot` — see `body(ofTag:in:)`.
  ///
  /// nil when the tag is absent, nested, the string is unbalanced, or the group
  /// never closes. An empty STRING is a different answer from nil: the tag was
  /// declared and its body is blank. Flattening the two reports
  /// "the display did not say" and "the display said nothing" as one fact.
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

  /// The characters between a **top-level** `<name>(` and its matching `)`,
  /// nested groups included. `nil` when there is no such tag or the group never
  /// closes (the truncation case).
  ///
  /// "Top-level" means immediately inside the outer group, depth 1, and is
  /// enforced two ways, because a tag name can be wrong about its identity in
  /// two independent directions:
  ///
  /// 1. **Horizontally, by the boundary check.** "vcpname(" and "mccs_vcp(" are
  ///    different keys from "vcp(", and matching them invents a list out of
  ///    unrelated data. The same check stops `tag("type", …)` from answering
  ///    with `prot_type(`'s body.
  /// 2. **Vertically, by the depth counter.** A textual scan finds the first
  ///    `<name>(` at ANY nesting depth, so `tag("type", in: "(prot(type(LCD))…")`
  ///    reports a nested field's body as a top-level field's.
  ///    `prot(type(...))` is a shape real monitors emit.
  ///
  /// "Depth 1" is measured against a real wrapper, not against whatever group
  /// comes first (see `outerGroupInterior`). Without that, the unwrapped
  /// `"vcp(vcp(60(01 03)))"` treats its own leading `vcp(` as the outer group,
  /// reads the INNER list as top-level, and answers `.unsupported`: a denial
  /// manufactured out of a string that is not a capability string at all.
  /// Measured: that shape, and only that shape, was the entire
  /// `unknown -> .unsupported` class in the differential fuzz.
  ///
  /// The same counter moves verdicts the other way round the capabilities-denial axis too.
  /// `support(forVCP: 0x10, in: "(vcpname(vcp(10))vcp(20))")` is `.unsupported`,
  /// because the `10` sits inside `vcpname`'s body as a permitted VALUE and the
  /// real top-level list is `vcp(20)`. Correct, and worth writing down: a depth
  /// counter can WITHDRAW support as well as withdraw a denial, and
  /// `.unsupported` greys a control.
  ///
  /// The consequence, taken deliberately: a capability string with no outer
  /// group (`vcp(10)` rather than `(vcp(10))`) is not well-formed MCCS and
  /// returns `nil`.
  ///
  /// That `nil` is not free. `VolumeSliderPolicy` resolves it to enabled under
  /// the capabilities-denial rule, but `DiagnosticsPage` reads the same `nil` as a statement about the
  /// DISPLAY rather than about our parser: `tag("mccs_ver"/"model"/"type", …)`
  /// renders "Not stated" about a panel that stated all three, and `codes(in:)`
  /// disclaims a vcp list the same page is showing verbatim.
  ///
  /// A real panel reached it without malformed firmware: the DELL U2725QE's one
  /// trailing NUL left a last character that is neither `)` nor whitespace, so
  /// `outerGroupInterior` rejected all 606 bytes of a complete answer [MEASURED
  /// 2026-08-04: 44 codes and `mccs_ver` "2.1" once trimmed, nil with the NUL].
  /// Fixed in the reassembly, where the wire's own noise is
  /// (`CapabilityPayload.string(from:)`), and deliberately NOT by loosening the
  /// wrapper rule here: the capabilities-denial rule would rather say nothing than guess at a wrapper,
  /// and the nine measured `unknown -> .unsupported` moves that rule prevents
  /// cost more than the bug it caused.
  ///
  /// The scan is hand-rolled rather than a regex because capability strings
  /// nest: only a depth counter can tell `60(0F 11 12)`'s closing paren from
  /// the vcp list's own, and only a depth counter can tell the two `vcp(` in
  /// `(vcpname(vcp(10))vcp(20))` apart.
  static func body(ofTag name: String, in capabilities: String) -> [Character]? {
    let tag = Array(name.lowercased())
    guard !tag.isEmpty else { return nil }
    let chars = Array(capabilities)
    guard let interior = outerGroupInterior(chars) else { return nil }
    // Depth is relative to the interior, so a top-level tag sits at depth 0.
    var depth = 0
    var index = interior.lowerBound
    while index < interior.upperBound {
      if depth == 0, index + tag.count < interior.upperBound {
        let isTag = chars[index + tag.count] == "("
          && (0 ..< tag.count).allSatisfy { chars[index + $0].lowercased() == String(tag[$0]) }
        // `interior.lowerBound` is always >= 1 — it sits just after the outer
        // '(' — so the look-behind needs no index == 0 special case, and at the
        // first position it reads that '(', which is a boundary.
        let boundaryBefore = !chars[index - 1].isLetter
          && !chars[index - 1].isNumber && chars[index - 1] != "_"
        if isTag, boundaryBefore {
          var groupDepth = 1
          var body: [Character] = []
          var cursor = index + tag.count + 1
          while cursor < interior.upperBound {
            let character = chars[cursor]
            if character == "(" { groupDepth += 1 }
            if character == ")" {
              groupDepth -= 1
              if groupDepth == 0 { return body }
            }
            body.append(character)
            cursor += 1
          }
          // The tag opened and never closed: truncation. Return nil rather than
          // resuming the scan — a second `vcp(` later in a truncated string is
          // not evidence we can trust either.
          return nil
        }
      }
      if chars[index] == "(" { depth += 1 }
      if chars[index] == ")" { depth -= 1 }
      index += 1
    }
    return nil
  }

  /// The interior of the one outer group, when the string is exactly `(…)`.
  ///
  /// A well-formed MCCS capability string is a single parenthesised group
  /// wrapping every tag. Requiring that — rather than inferring the wrapper
  /// from the first `(` we happen to meet — is what keeps `body(ofTag:in:)`'s
  /// notion of "top-level" anchored to something real. `"(a)(b)"`, `"vcp(10)"`
  /// and `"junk(vcp(10))"` are all rejected: each would otherwise donate an
  /// arbitrary group to stand in for the wrapper, and every tag read out of it
  /// would be a claim about a string we do not actually understand.
  ///
  /// Surrounding whitespace is tolerated because it changes no meaning. Nothing
  /// else is — the capabilities-denial rule would rather say nothing than guess at a wrapper.
  private static func outerGroupInterior(_ chars: [Character]) -> Range<Int>? {
    var start = 0
    var end = chars.count
    while start < end, chars[start].isWhitespace { start += 1 }
    while end > start, chars[end - 1].isWhitespace { end -= 1 }
    guard end - start >= 2, chars[start] == "(", chars[end - 1] == ")" else { return nil }
    // The opening paren must close on the LAST character, not merely somewhere.
    var depth = 0
    for index in start ..< end {
      if chars[index] == "(" { depth += 1 }
      if chars[index] == ")" {
        depth -= 1
        guard depth >= 0 else { return nil }
        if depth == 0 { return index == end - 1 ? (start + 1) ..< index : nil }
      }
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
      // Both characters must be ASCII hex digits, checked here rather than left
      // to `UInt8(_:radix:)`. That initialiser accepts a leading sign, so
      // `UInt8("+1", radix: 16)` is 1 and a count-only guard passes a token that
      // is not a hex pair. `support(forVCP:in:)` would then answer .unsupported
      // for "(vcp(+1))" and grey a working control on the word of a provably
      // malformed string, inverting the capabilities-denial rule.
      //
      // `isASCII` is load-bearing alongside `isHexDigit`: the latter is true
      // for fullwidth forms like "１", which `UInt8(_:radix:)` then rejects.
      guard token.count == 2, token.allSatisfy({ $0.isASCII && $0.isHexDigit }),
            let code = UInt8(token, radix: 16) else { return false }
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
