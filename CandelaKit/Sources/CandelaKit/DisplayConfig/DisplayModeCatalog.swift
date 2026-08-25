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

  // No `isRevealed` here, deliberately. A row is a SIZE, and the mode it
  // applies is chosen at press time from the rate the display is running, so
  // the representative's provenance is not the row's answer: a size can hold
  // published and added modes at once. Surfaces marking a curated row ask
  // whatever they would apply.

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
  /// LAST-RESORT floor, on the SHORTER axis, for the one state where nothing
  /// about the panel is known: no declared physical size to take a density
  /// from, and no native pixel count to take a fraction of. Every other case
  /// goes through `passesUsabilityFloor`, which prefers density and then the
  /// fraction. Not dead code: `DisplayModeCoordinator` really does pass 0 for
  /// the native pixels when the native-flagged mode could not be read.
  ///
  /// It was the ONLY floor until the density model landed, and a flat pixel
  /// count is the wrong shape for the job: it asks how many pixels tall a mode
  /// is, when the question is how big things look. On a 21:9 panel that cut
  /// three legitimate ladder rungs (1600×670, 1344×562, 1280×536) for being
  /// short rather than for being unusable.
  ///
  /// Deliberately the minor axis rather than width: the development Dell runs
  /// rotated 270°, where usable desktops are tall and narrow, and a width-only
  /// floor cut 945×1680 and 900×1600. Deliberately 720 rather than 768: the
  /// MAG ultrawide's exact-2x native mode is 1720×720, so a higher value would
  /// remove the most important mode on that panel.
  public static let usabilityFloorMinorAxis = 720

  /// Default presentation: one row per logical size, fastest refresh rate
  /// representing it, junk dropped, largest first.
  ///
  /// - Parameter geometry: the panel's physical facts, when they are known.
  ///   Supplying them upgrades the usability floor from a pixel count to a
  ///   density, which is the only form of the question that transfers between
  ///   a 21:9 ultrawide and a rotated 4K panel. On the calibrated panel set it
  ///   only ADDS rows: nothing the shipped pixel floor kept disappears, which
  ///   `noCurrentlyCuratedRowDisappearsOnAnyPanel` pins on all three fixtures.
  ///   That is a fixture result, not a structural one. A panel coarse enough
  ///   (a 55-inch 4K TV reads about 81 PPI) has sizes a pixel floor keeps and
  ///   a density floor drops, which is the density floor doing its job.
  ///
  ///   A VIRTUAL display's geometry may be passed like any other: the floor
  ///   itself treats `isVirtual` as no geometry at all, so no caller can
  ///   density-floor an invented physical size by forgetting to strip it.
  public static func curated(
    _ modes: [DisplayMode], nativePixelWidth: Int, nativePixelHeight: Int,
    geometry: PanelGeometry? = nil
  ) -> [DisplayModeRow] {
    let usable = modes.filter {
      passesUsabilityFloor($0, nativePixelWidth: nativePixelWidth,
                           nativePixelHeight: nativePixelHeight, geometry: geometry)
    }
    let groups = Dictionary(grouping: usable) { SizeKey(width: $0.logicalWidth, height: $0.logicalHeight) }

    return groups.compactMap { _, group -> DisplayModeRow? in
      guard let representative = group.sorted(by: representativeRanking).first else { return nil }
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

  /// Is this size a usable desktop on THIS panel? Three floors, most informed
  /// first, each falling through to the next when its input is missing.
  ///
  /// 1. Density, when the panel declares a physical size AND is not virtual.
  ///    "Too big to work in" is a physical claim, so this is the only floor
  ///    that means the same thing on two panels of different sizes. A virtual
  ///    display's declared size is invented, so its density is fiction and the
  ///    fraction of its native pixels is the honest answer: the exclusion lives
  ///    here rather than in every caller, since a caller that forgets to strip
  ///    the geometry gets a floor derived from a made-up 600x340 mm panel.
  /// 2. A fraction of the native minor axis, when only the pixel count is
  ///    known. Calibrated so nothing currently curated disappears, which makes
  ///    it deliberately permissive: on the MAG it lands at 475 where the flat
  ///    floor was 720.
  /// 3. The flat constant, when neither is known.
  ///
  /// Runs BEFORE grouping, so the representative-picking never sees a mode the
  /// floor rejected. `PanelDensityModel.evaluate` then trusts that its rows are
  /// post-floor, which is what this ordering guarantees.
  private static func passesUsabilityFloor(
    _ mode: DisplayMode, nativePixelWidth: Int, nativePixelHeight: Int,
    geometry: PanelGeometry?
  ) -> Bool {
    if let geometry, !geometry.isVirtual,
       let density = PanelDensityModel.looksLikePPI(
         logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight,
         in: geometry) {
      return density >= PanelDensityModel.floorLooksLikePPI
    }
    let nativeMinor = min(nativePixelWidth, nativePixelHeight)
    guard nativeMinor > 0 else {
      return min(mode.logicalWidth, mode.logicalHeight) >= usabilityFloorMinorAxis
    }
    let fractionFloor = Int(
      (Double(nativeMinor) * PanelDensityModel.fallbackFloorMinorAxisFraction)
        .rounded())
    return min(mode.logicalWidth, mode.logicalHeight) >= fractionFloor
  }

  /// Everything, ungrouped. The escape hatch that stops us being a nicer
  /// version of the thing users resent.
  ///
  /// "Everything" means every mode in the list it is handed — which is the
  /// public CoreGraphics list plus whatever survived revelation's gates, not
  /// every mode the two enumerations named. #110 settled that deliberately:
  /// the wire-timing guard filters here as well as in `curated`, rather than
  /// annotating, because a mode that scans out cropped is not an option a
  /// full list owes anybody. The `wireTimingGuard` default (D26) is what
  /// brings those back.
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

  /// Which mode stands for a logical size, in strict precedence order.
  ///
  /// 1. NATIVE WINS ITS OWN SIZE. The panel's own timing is what a person
  ///    reads as "native resolution"; promoting a 2x variant into that row
  ///    would silently make the default framebuffer 6880x2880 on a 3440x1440
  ///    panel. That mode stays reachable through `full`.
  /// 2. HiDPI BEATS 1x AT THE SAME LOGICAL SIZE. [MEASURED 2026-08-06] with
  ///    revelation on, CoreGraphics and CGS both offer 1920x804 on the MAG,
  ///    and the old ioModeID tie-break handed the row to the BLURRY one:
  ///    every revealed mode lost its group and the picker showed none of the
  ///    44 found. Sharpness is the point, so it outranks refresh.
  /// 3. Then fastest, then lowest id, so the choice is deterministic rather
  ///    than dependent on dictionary ordering.
  ///
  /// Shared with `outcome`, which has to answer for the same mode `curated`
  /// would have shown — two copies of this ranking would disagree the first
  /// time one was touched, and the disagreement would surface as a size row
  /// warning about the wrong framebuffer's rates.
  private static func representativeRanking(_ lhs: DisplayMode, _ rhs: DisplayMode) -> Bool {
    if lhs.isNative != rhs.isNative { return lhs.isNative }
    if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
    if lhs.refreshHz != rhs.refreshHz { return lhs.refreshHz > rhs.refreshHz }
    return lhs.ioModeID < rhs.ioModeID
  }

  /// What pressing a size row actually does (SO18).
  public struct SizeSelectionOutcome: Equatable, Sendable {
    /// The rate the display will end up running, quantized for display.
    public let appliedHz: Double
    /// The row must warn: the size cannot hold the rate now in use.
    public let lowersCurrentRate: Bool

    public init(appliedHz: Double, lowersCurrentRate: Bool) {
      self.appliedHz = appliedHz
      self.lowersCurrentRate = lowersCurrentRate
    }
  }

  /// Predicts the mode a size row applies, so the row can state its outcome
  /// instead of naming a catalog entry.
  ///
  /// This is a PREDICTION of `DisplayModeCoordinator.Catalog
  /// .modeKeepingCurrentRefreshRate`, and it mirrors that applier step for
  /// step rather than restating an idea of what it ought to do:
  ///
  /// - the applier resolves the ROW's descriptor, and the row for a size is
  ///   its curated representative — so the candidates are the representative's
  ///   framebuffer, not every mode sharing the logical size. A revealed HiDPI
  ///   variant offering only 60 Hz caps a 175 Hz display even while the 1x
  ///   variant at the same size still lists 175.
  /// - `ModePersistence.resolve` picks the rate NEAREST the current one, not
  ///   the size's fastest. From 75 Hz, a size holding 60 and 120 lands on 60;
  ///   predicting "the fastest applies" would promise 120 and stay silent
  ///   through a real drop.
  ///
  /// nil when the display has no mode at that size — there is no outcome to
  /// state about a row that cannot exist.
  ///
  /// - Parameter currentHz: exactly what the applier reads —
  ///   `current?.refreshHz ?? row.mode.refreshHz`. This is a contract, not a
  ///   hint: `currentHz` is the point the nearest-rate search measures from, so
  ///   a wrong value produces a confident wrong prediction, which is the exact
  ///   SO18 defect this function exists to prevent. Two ways to get it wrong:
  ///   - `0` as a stand-in for "unknown" makes every gap equal to the rate
  ///     itself, so the search returns the size's SLOWEST — and since no rate
  ///     is below zero, `lowersCurrentRate` comes back `false`. The row then
  ///     names the wrong rate AND the caps warning is silently disabled.
  ///   - any other placeholder judges the drop against a rate the display is
  ///     not running: a warning on rows that will not change, and none on rows
  ///     that will.
  ///
  ///   **When the display has no current mode, suppress the caps warning
  ///   rather than substitute a placeholder.** The applier falls back to the
  ///   row's own rate in that state, so there is nothing to compare against and
  ///   nothing honest to warn about. A caller that can reach the row's mode may
  ///   pass `row.mode.refreshHz` and get the applier's answer with
  ///   `lowersCurrentRate == false`; a caller that cannot must show no outcome.
  public static func outcome(
    selectingWidth: Int, selectingHeight: Int, currentHz: Double, in modes: [DisplayMode]
  ) -> SizeSelectionOutcome? {
    let atSize = modes.filter {
      $0.logicalWidth == selectingWidth && $0.logicalHeight == selectingHeight
    }
    guard let representative = atSize.sorted(by: representativeRanking).first else { return nil }

    let candidates = atSize.filter {
      $0.pixelWidth == representative.pixelWidth && $0.pixelHeight == representative.pixelHeight
    }
    guard let applied = candidates.min(by: { lhs, rhs in
      let lhsGap = abs(lhs.refreshHz - currentHz)
      let rhsGap = abs(rhs.refreshHz - currentHz)
      return lhsGap != rhsGap ? lhsGap < rhsGap : lhs.ioModeID < rhs.ioModeID
    }) else { return nil }

    // Quantized on both sides: 59.9998 is 60, and reporting that as a drop
    // would put a warning on a row where nothing changes.
    let appliedHz = DisplayMode.quantizedRefresh(applied.refreshHz)
    return SizeSelectionOutcome(
      appliedHz: appliedHz,
      lowersCurrentRate: appliedHz < DisplayMode.quantizedRefresh(currentHz)
    )
  }

  /// Every mode a display offers, gathered under its logical size — the
  /// structure the full list is read in. Nothing is filtered; that is the
  /// point of the full list.
  public struct SizeGroup: Equatable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    /// Rate-descending, ties on `ioModeID`.
    public let modes: [DisplayMode]

    public init(logicalWidth: Int, logicalHeight: Int, modes: [DisplayMode]) {
      self.logicalWidth = logicalWidth
      self.logicalHeight = logicalHeight
      self.modes = modes
    }
  }

  /// Largest size first, matching `curated` and `full`. Ties on width so two
  /// sizes of equal area do not order by dictionary iteration.
  public static func groupedBySize(_ modes: [DisplayMode]) -> [SizeGroup] {
    Dictionary(grouping: modes) { SizeKey(width: $0.logicalWidth, height: $0.logicalHeight) }
      .map { key, members in
        SizeGroup(
          logicalWidth: key.width, logicalHeight: key.height,
          modes: members.sorted {
            $0.refreshHz != $1.refreshHz
              ? $0.refreshHz > $1.refreshHz
              : $0.ioModeID < $1.ioModeID
          }
        )
      }
      .sorted { lhs, rhs in
        let (lhsArea, rhsArea) = (lhs.logicalWidth * lhs.logicalHeight,
                                  rhs.logicalWidth * rhs.logicalHeight)
        return lhsArea != rhsArea ? lhsArea > rhsArea : lhs.logicalWidth > rhs.logicalWidth
      }
  }

  /// The modes the full list tags "low resolution", by `ioModeID`.
  ///
  /// SO14's inversion, and macOS's: where one logical size is offered both
  /// sharp and blurry, the BLURRY one is tagged. Tagging the sharp one "HiDPI"
  /// names an implementation detail, and it leaves the 1x mode looking like the
  /// plain choice when it is the compromised one.
  ///
  /// A size with no sharp variant tags NOTHING. Most sizes on a standard-PPI
  /// panel are 1x and unremarkable; tagging all of them would say "low
  /// resolution" about every resolution such a display has.
  ///
  /// One pass over the whole list rather than a per-mode question, because the
  /// answer depends on the mode's SIBLINGS at the same logical size and the
  /// caller renders hundreds of rows.
  public static func lowResolutionDuplicates(_ modes: [DisplayMode]) -> Set<Int32> {
    let sharpSizes = Set(
      modes.filter(\.isHiDPI).map { SizeKey(width: $0.logicalWidth, height: $0.logicalHeight) }
    )
    guard !sharpSizes.isEmpty else { return [] }
    return Set(
      modes
        .filter {
          !$0.isHiDPI
            && sharpSizes.contains(SizeKey(width: $0.logicalWidth, height: $0.logicalHeight))
        }
        .map(\.ioModeID)
    )
  }

  /// Every rate in the list, once each, descending — the filter's menu.
  /// Quantized, so CoreGraphics' float noise cannot offer 60 twice while
  /// keeping NTSC's 59.9 as its own entry.
  public static func distinctRates(_ modes: [DisplayMode]) -> [Double] {
    Array(Set(modes.map { DisplayMode.quantizedRefresh($0.refreshHz) })).sorted(by: >)
  }

  private struct SizeKey: Hashable {
    let width: Int
    let height: Int
  }
}
