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
  /// same order: balance check FIRST, whole-tag match at depth 1 (so a `vcp(`
  /// buried inside another tag's body is not mistaken for the list), and
  /// top-level codes only — each of the two "top-level" claims in that sentence
  /// is a separate depth counter, one over tags and one over codes. A
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
  /// "Top-level" is literal: only a tag immediately inside the outer group
  /// answers. `tag("type", in: "(prot(type(LCD))vcp(10))")` is nil, not "LCD",
  /// because that `type` belongs to `prot` — see `body(ofTag:in:)`.
  ///
  /// nil when the tag is absent, nested, the string is unbalanced, or the group
  /// never closes. An empty STRING is a different answer from nil: the tag was
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

  /// The characters between a **top-level** `<name>(` and its matching `)`,
  /// nested groups included. `nil` when there is no such tag or the group never
  /// closes (the truncation case).
  ///
  /// "Top-level" means immediately inside the outer group — depth 1 — and is
  /// enforced two ways, because a tag name can be wrong about its identity in
  /// two independent directions:
  ///
  /// 1. **Horizontally, by the boundary check.** "vcpname(" and "mccs_vcp(" are
  ///    different keys from "vcp(", and matching them would invent a list out
  ///    of unrelated data. The same check stops `tag("type", …)` from answering
  ///    with `prot_type(`'s body.
  /// 2. **Vertically, by the depth counter.** A textual scan finds the first
  ///    `<name>(` at *any* nesting depth, so `tag("type", in: "(prot(type(LCD))…")`
  ///    answered "LCD" — a nested field's body reported as a top-level field's.
  ///    `prot(type(...))` is a shape real monitors emit, and generalising this
  ///    function from `vcp` to arbitrary tags turned an unlikely collision into
  ///    a plausible one. Reporting one field's value as another's is the same
  ///    invented fact as (1), arriving by the other door.
  ///
  /// "Depth 1" is measured against a real wrapper, not against whatever group
  /// happens to come first (see `outerGroupInterior`). Without that, the
  /// unwrapped `"vcp(vcp(60(01 03)))"` would treat its own leading `vcp(` as
  /// the outer group, read the INNER list as top-level, and answer
  /// `.unsupported` — a denial manufactured out of a string that is not a
  /// capability string at all. Measured: that shape, and only that shape, was
  /// the entire `unknown → .unsupported` class in the differential fuzz.
  ///
  /// That class is not the whole of what the depth fix moves, and the note
  /// used to stop there. The same counter also moves verdicts the other way
  /// round the D24 axis, `.supported → .unsupported`:
  /// `support(forVCP: 0x10, in: "(vcpname(vcp(10))vcp(20))")` answered
  /// `.supported` before it and answers `.unsupported` now. The new answer is
  /// the correct one — the `10` sits inside `vcpname`'s body, where it is a
  /// permitted VALUE and not a feature the display advertises, and the real
  /// top-level list is `vcp(20)` — but it is worth writing down that a
  /// depth-counter fix can *withdraw* support as well as withdraw a denial.
  /// `.unsupported` greys a control, so a wrong answer in this direction is
  /// the expensive kind; it is right here only because the string parsed
  /// cleanly, end to end, and genuinely does not list the code.
  ///
  /// The consequence, taken deliberately: a capability string with no outer
  /// group — `vcp(10)` rather than `(vcp(10))` — is not well-formed MCCS and
  /// returns `nil`.
  ///
  /// That `nil` used to be described as free, on the grounds that D24 lets it
  /// reach the UI as `.unknown`, which `VolumeSliderPolicy` resolves to
  /// *enabled*. That remains true of `VolumeSliderPolicy`, and is false of
  /// `DisplayDiagnosticsSection`, which is now also a consumer and reads the
  /// same `nil` as a statement about the DISPLAY rather than about our parser:
  ///
  /// - `CapabilityString.tag("mccs_ver"/"model"/"type", …)` renders "Not
  ///   stated" — attributing silence to a panel that stated all three.
  /// - `CapabilityString.codes(in:)` renders "The description did not parse,
  ///   so Candela makes no claim about it", which is honest, but sits next to
  ///   a "Capability request: The display answered" row and a disclosure group
  ///   showing the raw string — so the pane displays a legible vcp list while
  ///   telling the reader it could not read one.
  ///
  /// It is reachable without malformed firmware, because
  /// `Arm64DDCService.readCapabilityString` concatenates fragments with no
  /// trimming: one trailing NUL byte turns `"(vcp(10))"` into `"(vcp(10))\0"`,
  /// whose last character is not `)` and is not whitespace, so
  /// `outerGroupInterior` rejects the whole string. A parseable list plus
  /// trailing junk is exactly the shape a display sends and the pane then
  /// disclaims. Fixing that belongs in the reassembly (trim trailing NULs and
  /// control bytes there, where the wire's own noise is), not by loosening the
  /// wrapper rule here — D24 would still rather say nothing than guess at a
  /// wrapper.
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
  /// else is — D24 would rather say nothing than guess at a wrapper.
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
      // Both characters must be ASCII hex digits, checked explicitly rather
      // than left to `UInt8(_:radix:)`. That initialiser accepts a leading sign
      // — `UInt8("+1", radix: 16)` is 1, and "+1" is two Characters, so a
      // count-only guard passed a token that is not a hex pair. The cost was
      // not merely a wrong entry in a diagnostics list: `support(forVCP:in:)`
      // would then answer .unsupported for "(vcp(+1))" and grey a working
      // control on the word of a provably malformed string, inverting D24's
      // doctrine that an unclear answer resolves to *enabled*.
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
