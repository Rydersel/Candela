import Foundation

/// One row in the curated list: a representative mode plus what the UI needs
/// to describe it.
///
/// Carries no refresh-rate list of its own. The picker asks about the size the
/// display is CURRENTLY running — which is not always a curated row, since the
/// current size can sit below the usability floor — so it calls
/// `refreshRates(in:logicalWidth:logicalHeight:)` directly. A per-row copy was
/// the same list computed twice, read by nothing.
public struct DisplayModeRow: Sendable, Equatable, Identifiable {
  public let mode: DisplayMode
  /// Relative to the OWNING panel — the same logical size is native on one
  /// display and scaled on another.
  public let isScaled: Bool

  public var id: Int32 { mode.ioModeID }

  public init(mode: DisplayMode, isScaled: Bool) {
    self.mode = mode
    self.isScaled = isScaled
  }
}

/// Turns an honest-but-unusable mode list into something a person can choose
/// from, without hiding anything the way macOS does.
///
/// Foundation only — no CoreGraphics — so the judgement is testable against
/// captured fixtures rather than against attached hardware.
public enum DisplayModeCatalog {
  /// Below this on its SHORTER axis, a mode is not a usable desktop. The real
  /// Dell list contains 300×400; nobody is choosing that.
  ///
  /// Deliberately the minor axis rather than width: the development Dell runs
  /// rotated 270°, where usable desktops are tall and narrow, and a width-only
  /// floor cut 945×1680 and 900×1600. Deliberately 720 rather than 768: the
  /// MAG ultrawide's exact-2x native mode is 1720×720, so a higher floor would
  /// remove the most important mode on that panel.
  public static let usabilityFloorMinorAxis = 720

  /// Default presentation: one row per logical size, fastest refresh rate
  /// representing it, junk dropped, largest first.
  public static func curated(
    _ modes: [DisplayMode], nativePixelWidth: Int, nativePixelHeight: Int
  ) -> [DisplayModeRow] {
    let usable = modes.filter { min($0.logicalWidth, $0.logicalHeight) >= usabilityFloorMinorAxis }
    let groups = Dictionary(grouping: usable) { SizeKey(width: $0.logicalWidth, height: $0.logicalHeight) }

    return groups.compactMap { _, group -> DisplayModeRow? in
      // Representative choice, in strict precedence order.
      //
      // 1. NATIVE WINS ITS OWN SIZE. The panel's own timing is what a person
      //    reads as "native resolution"; promoting a 2x variant into that row
      //    would silently make the default framebuffer 6880x2880 on a
      //    3440x1440 panel. That mode stays reachable through `full`.
      // 2. HiDPI BEATS 1x AT THE SAME LOGICAL SIZE. [MEASURED 2026-08-06] with
      //    revelation on, CoreGraphics and CGS both offer 1920x804 on the MAG,
      //    and the old ioModeID tie-break handed the row to the BLURRY one:
      //    every revealed mode lost its group and the picker showed none of
      //    the 44 found. Sharpness is the point, so it outranks refresh.
      // 3. Then fastest, then lowest id, so the choice is deterministic rather
      //    than dependent on dictionary ordering.
      let sorted = group.sorted { lhs, rhs in
        if lhs.isNative != rhs.isNative { return lhs.isNative }
        if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
        if lhs.refreshHz != rhs.refreshHz { return lhs.refreshHz > rhs.refreshHz }
        return lhs.ioModeID < rhs.ioModeID
      }
      guard let representative = sorted.first else { return nil }
      return DisplayModeRow(
        mode: representative,
        isScaled: representative.isScaled(nativePixelWidth: nativePixelWidth,
                                          nativePixelHeight: nativePixelHeight)
      )
    }
    .sorted {
      $0.mode.logicalArea != $1.mode.logicalArea
        ? $0.mode.logicalArea > $1.mode.logicalArea
        : $0.mode.ioModeID < $1.mode.ioModeID
    }
  }

  /// Everything, unfiltered and ungrouped. The escape hatch that stops us
  /// being a nicer version of the thing users resent.
  public static func full(_ modes: [DisplayMode]) -> [DisplayMode] {
    modes.sorted {
      if $0.logicalArea != $1.logicalArea { return $0.logicalArea > $1.logicalArea }
      if $0.refreshHz != $1.refreshHz { return $0.refreshHz > $1.refreshHz }
      return $0.ioModeID < $1.ioModeID
    }
  }

  /// Refresh rates available at one logical size, descending and deduplicated.
  public static func refreshRates(
    in modes: [DisplayMode], logicalWidth: Int, logicalHeight: Int
  ) -> [Double] {
    let rates = modes
      .filter { $0.logicalWidth == logicalWidth && $0.logicalHeight == logicalHeight }
      .map(\.refreshHz)
    return Array(Set(rates)).sorted(by: >)
  }

  private struct SizeKey: Hashable {
    let width: Int
    let height: Int
  }
}
