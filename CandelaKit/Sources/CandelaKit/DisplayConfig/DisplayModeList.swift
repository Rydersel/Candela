import Foundation

/// Collapses mode rows that no surface can render differently.
///
/// CoreGraphics publishes pairs with identical logical geometry, identical
/// framebuffer geometry and identical refresh, differing only in `ioModeID`.
/// Measured 2026-08-17 across the three attached panels, after the
/// desktop-usability filter: 42 such buckets on the Dell, 0 on the MAG, 0 on the
/// built-in.
///
/// 41 of the Dell's 42 are byte-identical in the CGS descriptor apart from the
/// two fields carrying the mode number, with `ioFlags`, desktop usability and
/// pixel encoding all agreeing. The 42nd (ids 134 and 135, the 1080x1920 HiDPI
/// rung) differs in exactly one bit, `kDisplayModeDefaultFlag`, which says which
/// one macOS considers the display's default and changes nothing a person sees.
/// It is collapsed too, deliberately.
///
/// Two pairs were then applied and read back, one 1x (230/231) and one HiDPI
/// (178/181), each against a positive control that moved the display first: both
/// achieved the same logical size, framebuffer, refresh, bounds and scale,
/// differing only in the id CoreGraphics reported afterwards (S6's method,
/// `.forAppOnly`, self-reverted).
///
/// The residual, stated because nothing can close it: two modes could in
/// principle be bound to different WIRE TIMINGS, and no IORegistry property
/// records the driven timing (the finding behind the wire-timing guard). So
/// this collapses rows that are identical in everything observable, which is
/// not the same as proving the panel scans them out alike. The keep/revert
/// countdown stays the detector of last resort, as it is for revealed modes.
public enum DisplayModeList {
  /// What a person can actually see in a row. Refresh arrives quantized from
  /// `DisplayMode.quantizedRefresh`, which is load-bearing in BOTH directions:
  /// coarser and the built-in's 59.9 collapses into its 60.0, erasing a real
  /// choice; finer and float noise splits one rate into several rows.
  private struct RenderedIdentity: Hashable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshHz: Double
  }

  /// Keeps the first occurrence of each rendered identity, so the caller's
  /// ordering survives, and picks the survivor by what downstream code needs
  /// rather than by position.
  public static func deduplicated(_ modes: [DisplayMode]) -> [DisplayMode] {
    var order: [RenderedIdentity] = []
    var groups: [RenderedIdentity: [DisplayMode]] = [:]
    for mode in modes {
      let identity = RenderedIdentity(
        logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight,
        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
        refreshHz: mode.refreshHz)
      if groups[identity] == nil { order.append(identity) }
      groups[identity, default: []].append(mode)
    }
    return order.compactMap { identity in
      groups[identity]?.min(by: survivorRanksBefore)
    }
  }

  /// Which row represents `probe`, whose id may have been collapsed away.
  ///
  /// The display can be RUNNING a twin this list dropped: `CGDisplayCopyDisplayMode`
  /// answers with the live id whether or not the enumeration kept it, and a
  /// lookup by id alone would then return nothing and leave the picker with no
  /// current row and the hub with no size line. Falling back to the rendered
  /// identity is not a fudge: it is the same claim the collapse makes, that the
  /// survivor is the same mode in everything observable.
  public static func resolve(_ probe: DisplayMode, in modes: [DisplayMode]) -> DisplayMode? {
    if let exact = modes.first(where: { $0.ioModeID == probe.ioModeID }) { return exact }
    return modes.first {
      $0.logicalWidth == probe.logicalWidth && $0.logicalHeight == probe.logicalHeight
        && $0.pixelWidth == probe.pixelWidth && $0.pixelHeight == probe.pixelHeight
        && $0.refreshHz == probe.refreshHz
    }
  }

  /// Native first: `isNative` is how the revelation pass finds the panel's own
  /// timing and how the scaled-size model finds its native pixel count, and a
  /// collapse that dropped the flagged member would strand both. (Both members
  /// of every measured pair carry it, so this decides nothing today; it is here
  /// so a pair where only one does cannot go wrong quietly.)
  ///
  /// Then CoreGraphics-published over revealed, because a published mode
  /// applies through public API. Then the lowest id, purely so the choice is
  /// stable across runs rather than dependent on enumeration order.
  private static func survivorRanksBefore(_ lhs: DisplayMode, _ rhs: DisplayMode) -> Bool {
    if lhs.isNative != rhs.isNative { return lhs.isNative }
    if lhs.provenance != rhs.provenance { return lhs.provenance == .coreGraphics }
    return lhs.ioModeID < rhs.ioModeID
  }
}
