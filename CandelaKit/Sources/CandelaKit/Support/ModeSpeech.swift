import Foundation

/// Spoken-form rendering of a display mode for accessibility values.
/// "2560 × 1440 · 60 Hz" is display text; VoiceOver needs words, grouped
/// digits, and no glyphs (× is read inconsistently at most verbosities).
public enum ModeSpeech {
  public static func spoken(logicalWidth: Int, logicalHeight: Int, refreshHz: Double?) -> String {
    let size = "\(grouped(logicalWidth)) by \(grouped(logicalHeight))"
    guard let hz = refreshHz else { return size }
    // Callers hand over raw CoreGraphics rates, which carry float noise
    // (59.9998); unquantized they would be spoken digit by digit.
    let q = DisplayMode.quantizedRefresh(hz)
    let rate = q == q.rounded() ? String(Int(q)) : String(q)
    return "\(size) at \(rate) hertz"
  }

  private static func grouped(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")  // D25: English only, deterministic output
    return f.string(from: NSNumber(value: n)) ?? String(n)
  }
}
