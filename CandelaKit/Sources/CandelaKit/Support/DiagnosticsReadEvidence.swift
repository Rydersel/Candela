public enum DiagnosticsReadEvidence {
  public static func describe(_ evidence: DDCReadEvidence) -> String {
    switch evidence {
    case .notAttempted: "No usable read result recorded yet"
    case .answered: "A read returned a value with a nonzero maximum"
    case .allZeros: "Recorded a zero-valued or zero-maximum reply; no usable value"
    case .noReply: "No readable reply recorded (silence or an invalid response)"
    case .refused: "The display reported that this command is unsupported"
    }
  }
}
