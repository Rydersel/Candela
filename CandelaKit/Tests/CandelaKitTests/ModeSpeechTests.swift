import Testing

@testable import CandelaKit

@Suite("Spoken-form mode strings")
struct ModeSpeechTests {
  @Test func groupsThousandsAndDropsTrailingZeroRates() {
    #expect(
      ModeSpeech.spoken(logicalWidth: 2560, logicalHeight: 1440, refreshHz: 60.0)
        == "2,560 by 1,440 at 60 hertz")
  }

  @Test func keepsFractionalRates() {
    #expect(
      ModeSpeech.spoken(logicalWidth: 3440, logicalHeight: 1440, refreshHz: 59.9)
        == "3,440 by 1,440 at 59.9 hertz")
  }

  @Test func omitsTheRateClauseWhenNil() {
    #expect(
      ModeSpeech.spoken(logicalWidth: 1920, logicalHeight: 1080, refreshHz: nil)
        == "1,920 by 1,080")
  }

  /// Rates arrive as float noise (`59.9998`, not `60.0`); the caller must not
  /// have to quantize first or VoiceOver reads a nine-digit number.
  @Test func quantizesFloatNoiseBeforeSpeaking() {
    #expect(
      ModeSpeech.spoken(logicalWidth: 1920, logicalHeight: 1080, refreshHz: 59.9998)
        == "1,920 by 1,080 at 60 hertz")
    #expect(
      ModeSpeech.spoken(logicalWidth: 960, logicalHeight: 600, refreshHz: 59.94)
        == "960 by 600 at 59.9 hertz")
  }

  /// The rate on its own, for callers that speak a rate without a size, such as
  /// the hero's "(max 175 Hz)" annotation. ONE helper on purpose: a second private
  /// copy in a view is how "175 Hz" reaches VoiceOver as a glyph, or 119.998 as
  /// nine spoken digits.
  @Test func speaksABareRateWithTheSameRules() {
    #expect(ModeSpeech.spokenRate(60.0) == "60 hertz")
    #expect(ModeSpeech.spokenRate(175.0) == "175 hertz")
    #expect(ModeSpeech.spokenRate(59.94) == "59.9 hertz")
    #expect(ModeSpeech.spokenRate(59.9998) == "60 hertz")
  }

  /// `spoken` must not keep a second copy of the rate rules. Pinned by composition
  /// rather than inspection, so an edit to either one that breaks the agreement
  /// fails here.
  @Test func spokenClosesOverTheBareRateHelper() {
    for hz in [60.0, 59.9998, 59.94, 175.0, 24.0] {
      #expect(
        ModeSpeech.spoken(logicalWidth: 2560, logicalHeight: 1440, refreshHz: hz)
          == "2,560 by 1,440 at \(ModeSpeech.spokenRate(hz))")
    }
  }

  /// Three-digit sizes take no separator, so the group is not unconditional.
  @Test func leavesSmallNumbersUngrouped() {
    #expect(
      ModeSpeech.spoken(logicalWidth: 800, logicalHeight: 600, refreshHz: nil)
        == "800 by 600")
  }
}
