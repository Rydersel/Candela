import Testing
@testable import CandelaKit

@Suite("Capability text exported in reports")
struct DiagnosticsCapabilityTextTests {
  @Test func preservesOrdinaryResponsesIncludingMalformedCommandTokens() {
    for raw in ["(prot(monitor)type(lcd)model(P32U)cmds(01 03 F3)vcp(10 60(01 03 62))mccs_ver(2.2))",
                "(VCP(10 12)\n model(P32U) mswhql(1))", "(vcp(10 ZZ +1))", "vcp(10 12)",
                "(vcp(10 12)", "(vcp(10 12)))"] {
      let result = DiagnosticsCapabilityText(raw)
      #expect(result.text == raw)
      #expect(!result.wasRedacted)
    }
  }

  @Test func withholdsUnknownAndNestedIdentifierPayloadsWithoutRepairingTruncation() {
    let cases = [
      ("(serial(PRIVATE-123)vcp(10 12))", "(serial([redacted])vcp(10 12))"),
      ("(vendor_data(nested(PRIVATE-123))vcp(10 12))", "(vendor_data([redacted])vcp(10 12))"),
      ("(model(serial(PRIVATE-123))vcp(10))", "(model([redacted])vcp(10))"),
      ("(vcp(PRIVATE-123))", "(vcp([redacted]))"),
      ("(vcp(10)serial(PRIVATE-123", "(vcp(10)serial([redacted]"),
      ("(vcp(10))PRIVATE-123", "(vcp(10))[redacted]"),
      ("(PRIVATE123(value)vcp(10))", "([redacted field]([redacted])vcp(10))"),
      ("(PRIVATESERIAL(value)vcp(10))", "([redacted field]([redacted])vcp(10))"),
    ]
    for (raw, expected) in cases {
      let result = DiagnosticsCapabilityText(raw)
      #expect(result.text == expected)
      #expect(result.wasRedacted)
      #expect(!result.text.contains("PRIVATE"))
    }
  }

  @Test func removesKnownIdentifiersFromModelWithoutChangingCommandValues() {
    let result = DiagnosticsCapabilityText("(model(P32U PRIVATE-123)vcp(10 12))", identifiers: ["PRIVATE-123"])
    #expect(result.text == "(model(P32U [redacted])vcp(10 12))")
    #expect(result.wasRedacted)
  }

  @Test func boundsUntrustedPayloads() {
    let result = DiagnosticsCapabilityText("(model(" + String(repeating: "a", count: 20_000) + "))")
    #expect(result.wasRedacted)
    #expect(result.text == "[withheld: capability description exceeds 16384 bytes]")
    #expect(result.metadata("model") == "withheld (oversized description)")
  }

  @Test func separatelyExportedMetadataCannotBypassRedaction() {
    #expect(DiagnosticsCapabilityText.metadata("serial(PRIVATE)", field: "model") == "[redacted]")
    #expect(DiagnosticsCapabilityText.metadata("PRIVATE", field: "mccs_ver") == "[redacted]")
    #expect(DiagnosticsCapabilityText.metadata("PRIVATE", field: "type") == "[redacted]")
    #expect(DiagnosticsCapabilityText.metadata("P32U secret", field: "model", identifiers: ["secret"]) == "P32U [redacted]")
    #expect(DiagnosticsCapabilityText.metadata("P32U serial=PRIVATE123", field: "model") == "[redacted]")
    #expect(DiagnosticsCapabilityText.metadata("P32U Serial Number: PRIVATE123", field: "model") == "[redacted]")
  }

  @Test func identifyingFieldsAlsoRedactCopiesElsewhereInTheResponse() {
    for raw in ["(serial(PRIVATE123)model(P32U PRIVATE123)vcp(10))",
                "(model(P32U PRIVATE123)serial(PRIVATE123)vcp(10))",
                "(model(P32U PRIVATE123)asset_tag(PRIVATE123)vcp(10))"] {
      let exported = DiagnosticsCapabilityText(raw)
      #expect(!exported.text.contains("PRIVATE123"))
      #expect(exported.text.contains("model(P32U [redacted])"))
      #expect(exported.text.contains("vcp(10)"))
      #expect(exported.metadata("model") == "P32U [redacted]")
    }
  }

  @Test func preservesWhitespaceWithinRecognizedScalarFields() {
    let raw = "(prot( monitor )type( LCD )mccs_ver( 2.2 )mswhql( 1 )vcp(10))"
    #expect(DiagnosticsCapabilityText(raw).text == raw)
    #expect(!DiagnosticsCapabilityText(raw).wasRedacted)
  }

  @Test func redactsIdentifiersOnceWithoutRewritingInsertedMarkers() {
    #expect(DiagnosticsCapabilityText.redactingIdentifiers(in: "secret redacted", identifiers: ["secret", "redacted"])
      == "[redacted] [redacted]")
  }
}
