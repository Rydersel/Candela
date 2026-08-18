import Foundation

extension SyntheticSizeCatalog {
  /// The panel's curated rows plus the synthesized stops, as ONE picker list
  /// (SS4: same picker, no separate control surface).
  ///
  /// The ordering is `DisplayModeCatalog.curated`'s and stays it: logical area
  /// descending, with a tie-break that here has to say something that one does
  /// not. A synthesized row's `ioModeID` is a NEGATIVE sentinel, so the plain
  /// id tie-break would sort it in FRONT of a published row at the same size.
  /// A synthesized size is an addition to what the panel offers, so it sorts
  /// after the row it doubles.
  ///
  /// A separate file from the catalog itself because that type answers "what
  /// may this panel synthesize"; this answers "what does the picker show", and
  /// the second question is the one that has to agree with
  /// `DisplayModeCatalog`.
  ///
  /// - Parameter nativePixels: the panel's own framebuffer, for the row's
  ///   `isScaled`. nil suppresses the answer rather than guessing it, the same
  ///   rule the badge follows: comparing against a zero-sized panel would mark
  ///   every row scaled.
  public static func merged(
    published: [DisplayModeRow],
    stops: [SyntheticSize],
    nativePixels: (width: Int, height: Int)?
  ) -> [DisplayModeRow] {
    guard !stops.isEmpty else { return published }
    let synthesized = stops.map { stop -> DisplayModeRow in
      let mode = row(for: stop)
      return DisplayModeRow(
        mode: mode,
        isScaled: nativePixels.map {
          mode.isScaled(nativePixelWidth: $0.width, nativePixelHeight: $0.height)
        } ?? false
      )
    }
    return (published + synthesized).sorted { lhs, rhs in
      if lhs.mode.logicalArea != rhs.mode.logicalArea {
        return lhs.mode.logicalArea > rhs.mode.logicalArea
      }
      if lhs.mode.isSynthesized != rhs.mode.isSynthesized { return !lhs.mode.isSynthesized }
      return lhs.mode.ioModeID < rhs.mode.ioModeID
    }
  }
}
