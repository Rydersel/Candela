import Foundation

/// Spoken-form rendering of a display mode for accessibility values.
/// "2560 × 1440 · 60 Hz" is display text; VoiceOver needs words, grouped
/// digits, and no glyphs (× is read inconsistently at most verbosities).
public enum ModeSpeech {
  public static func spoken(logicalWidth: Int, logicalHeight: Int, refreshHz: Double?) -> String {
    let size = "\(grouped(logicalWidth)) by \(grouped(logicalHeight))"
    guard let hz = refreshHz else { return size }
    return "\(size) at \(spokenRate(hz))"
  }

  /// A rate on its own, for the callers that speak one without a size — the
  /// hero's "(max 175 Hz)" annotation is the first. Same rules as the clause
  /// inside `spoken`, because it IS that clause: "Hz" is read inconsistently
  /// at most verbosities, so the unit is spelled out.
  public static func spokenRate(_ hz: Double) -> String {
    // Belt and braces. Live modes are already quantized at the construction
    // boundary (`CoreGraphicsDisplayConfigurator`, `CGSModeRevelation`), but
    // this is a public entry point taking a bare `Double` — a caller with a raw
    // CoreGraphics rate would otherwise have 59.9998 spoken digit by digit.
    let q = DisplayMode.quantizedRefresh(hz)
    return "\(q == q.rounded() ? String(Int(q)) : String(q)) hertz"
  }

  private static func grouped(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")  // D25: English only, deterministic output
    return f.string(from: NSNumber(value: n)) ?? String(n)
  }
}
