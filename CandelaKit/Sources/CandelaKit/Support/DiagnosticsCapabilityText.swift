import Foundation

/// An export-only view of device-provided text. Parser verdicts must use the
/// original response, because redaction can change its syntax.
public struct DiagnosticsCapabilityText: Sendable {
  public let text: String
  public let wasRedacted: Bool
  private let source: String?
  private let identifiers: [String]

  public init(_ raw: String, identifiers: [String] = []) {
    guard raw.utf8.count <= 16_384 else {
      text = "[withheld: capability description exceeds 16384 bytes]"
      wasRedacted = true
      source = nil
      self.identifiers = []
      return
    }
    source = raw
    let identifiers = identifiers + Self.identifiers(in: raw)
    self.identifiers = identifiers
    let chars = Array(raw)
    var output = ""
    var index = 0
    while index < chars.count {
      let character = chars[index]
      if character == "(" || character == ")" || character.isWhitespace {
        output.append(character)
        index += 1
        continue
      }
      let start = index
      while index < chars.count, Self.isTagCharacter(chars[index]) { index += 1 }
      guard index > start, index < chars.count, chars[index] == "(" else {
        if index == start { index += 1 }
        output += "[redacted]"
        continue
      }
      let name = String(chars[start..<index])
      let bodyStart = index + 1
      var end = bodyStart
      var depth = 1
      while end < chars.count {
        if chars[end] == "(" { depth += 1 }
        if chars[end] == ")" { depth -= 1 }
        if depth == 0 { break }
        end += 1
      }
      let body = String(chars[bodyStart..<end])
      let knownNames = ["prot", "type", "model", "cmds", "vcp", "mccs_ver", "mswhql",
                        "serial", "serial_number", "sn", "vendor_data", "asset_tag"]
      let safeName = knownNames.contains(name.lowercased()) ? name : "[redacted field]"
      output += safeName + "("
      output += Self.metadata(body, field: name, identifiers: identifiers)
      // Do not repair truncated replies: the missing closing parenthesis is evidence.
      if end < chars.count { output += ")" }
      index = min(end + 1, chars.count)
    }
    text = output
    wasRedacted = output != raw
  }

  /// Parsed metadata uses the same identifier set and size limit as the raw
  /// export, including identifiers learned from the response itself.
  public func metadata(_ field: String) -> String {
    guard let source else { return "withheld (oversized description)" }
    return Self.metadata(CapabilityString.tag(field, in: source), field: field, identifiers: identifiers)
  }

  public static func identifiers(in raw: String) -> [String] {
    guard raw.utf8.count <= 16_384,
          let regex = try? NSRegularExpression(
            pattern: #"(?i)(?<![a-z0-9_])(?:serial(?:[_ -]?(?:number|no))?|sn|asset[_ -]?tag|uuid)\s*\(([^()]*)"#)
    else { return [] }
    return regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { match in
      guard let range = Range(match.range(at: 1), in: raw) else { return nil }
      let value = raw[range].trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
  }

  public static func metadata(_ value: String?, field: String, identifiers: [String] = []) -> String {
    guard let body = value else { return "not stated" }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.lowercased() {
    case "vcp", "cmds":
      return Self.codeList(body)
    case "model":
      let simple = body.count <= 128 && !body.contains("(") && !body.contains(")")
        && body.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
      let labelsIdentity = body.range(
        of: #"\b(?:serial(?:[_ -]?(?:number|no))?|sn|asset[_ -]?tag|uuid|edid)\s*[:=]"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      return simple && !labelsIdentity
        ? Self.redactingIdentifiers(in: body, identifiers: identifiers) : "[redacted]"
    case "prot":
      return trimmed.lowercased() == "monitor" ? body : "[redacted]"
    case "type":
      return ["lcd", "crt", "oled", "led"].contains(trimmed.lowercased()) ? body : "[redacted]"
    case "mccs_ver":
      return trimmed.range(of: #"^[0-9]{1,3}\.[0-9]{1,3}$"#, options: .regularExpression) != nil
        ? body : "[redacted]"
    case "mswhql":
      return trimmed.range(of: #"^[0-9]{1,2}$"#, options: .regularExpression) != nil ? body : "[redacted]"
    default:
      return "[redacted]"
    }
  }

  public static func redactingIdentifiers(in text: String, identifiers: [String]) -> String {
    let patterns = Set(identifiers.filter { !$0.isEmpty }).sorted { $0.count > $1.count }
      .map(NSRegularExpression.escapedPattern(for:))
    guard !patterns.isEmpty,
          let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: .caseInsensitive)
    else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
  }

  private static func isTagCharacter(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || "_-.".contains(character))
  }

  private static func codeList(_ body: String) -> String {
    var output = ""
    var token = ""
    func flush() {
      guard !token.isEmpty else { return }
      // Keep short malformed codes such as ZZ and +1 useful for parser diagnosis.
      let safe = token.count <= 2 && token.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "+-".contains($0))
      }
      output += safe ? token : "[redacted]"
      token = ""
    }
    for character in body {
      if character == "(" || character == ")" || character.isWhitespace {
        flush()
        output.append(character)
      } else {
        token.append(character)
      }
    }
    flush()
    return output
  }
}
