import CoreGraphics
import Foundation

/// Short-lived evidence for regional dimming, separate from cumulative exposure.
///
/// Six matching minute samples establish five minutes of observed stability.
/// Only coarse means and per-cell fingerprints survive a capture; neither the
/// source image nor its pixel array is retained. Sampling can miss motion
/// between captures and cannot tell a paused photo from an unattended toolbar.
public struct AdaptiveRegionProtection: Sendable {
  public struct Activity: Equatable, Sendable {
    /// Nil means focus could not be resolved, so regional dimming is withheld.
    public let isFocusedDisplay: Bool?
    public let frontmostPID: Int32?
    /// Pointer in display-local, top-left coordinates, including beyond its bounds.
    public let pointerPosition: CGPoint?

    public init(isFocusedDisplay: Bool?, frontmostPID: Int32?, pointerPosition: CGPoint?,
                captureExcludedPID: Int32? = nil) {
      // The capture omits this app, so observed ownership describes what is
      // behind its windows. Withhold masks rather than dim through its UI.
      self.isFocusedDisplay = captureExcludedPID != nil && frontmostPID == captureExcludedPID
        ? nil : isFocusedDisplay
      self.frontmostPID = frontmostPID
      self.pointerPosition = pointerPosition
    }
  }

  private struct Evidence: Sendable {
    var fingerprint: UInt64
    var windowID: UInt32?
    var ownerPID: Int32?
    var since: Date
    var samples: Int
  }

  private static let maximumGap: TimeInterval = 90
  private static let minimumDuration: TimeInterval = 300
  private var evidence: [Evidence] = []
  private var brightness: [Double] = []
  private var lastSample: Date?
  private var geometry: PanelSpaceTransform?
  private var captureSize: (cols: Int, rows: Int)?

  private var windowRestoration = AdaptiveWindowRestoration()
  /// Keep the driver fast only while a recently hovered window is returning.
  public var isRestoringWindows: Bool { windowRestoration.isReturning }
  /// A fully restored window still needs pointer-exit events to start its grace.
  public var needsInputTracking: Bool { windowRestoration.needsInputTracking }

  public init() {}

  public mutating func record(displayGrid: [Double], cols: Int, rows: Int,
                              through transform: PanelSpaceTransform,
                              observation: WindowObservation, at now: Date) {
    guard now.timeIntervalSinceReferenceDate.isFinite,
      Self.valid(observation),
      let fingerprints = Self.fingerprints(displayGrid, cols: cols, rows: rows,
                                           through: transform)
    else {
      self = Self()
      return
    }
    let gap = lastSample.map { now.timeIntervalSince($0) }
    let continuous = gap.map { $0 > 0 && $0 <= Self.maximumGap } == true
      && geometry == transform && captureSize?.cols == cols && captureSize?.rows == rows
      && evidence.count == PanelGrid.cellCount
    evidence = fingerprints.indices.map { cell in
      let window = observation.windowIDByCell[cell]
      let owner = observation.ownerPIDByCell[cell]
      if continuous, let window, let owner,
        evidence[cell].fingerprint == fingerprints[cell],
        evidence[cell].windowID == window, evidence[cell].ownerPID == owner {
        var held = evidence[cell]
        held.samples = min(6, held.samples + 1)
        return held
      }
      return Evidence(fingerprint: fingerprints[cell], windowID: window,
                      ownerPID: owner, since: now, samples: 1)
    }
    brightness = transform.panelNativeGrid(fromDisplayGrid: displayGrid, cols: cols, rows: rows)
    lastSample = now
    geometry = transform
    captureSize = (cols, rows)
  }

  public mutating func nominate(observation: WindowObservation, exposure: ExposureMap,
                       activity: Activity, windows: [WindowSnapshot], at now: Date) -> OverlayMask? {
    guard Self.valid(observation), observation.fullScreenOwner == nil,
      evidence.count == PanelGrid.cellCount, brightness.count == PanelGrid.cellCount,
      let lastSample, now.timeIntervalSinceReferenceDate.isFinite,
      now >= lastSample, now.timeIntervalSince(lastSample) <= Self.maximumGap,
      activity.isFocusedDisplay != nil, let frontmostPID = activity.frontmostPID
    else {
      windowRestoration = AdaptiveWindowRestoration()
      return nil
    }

    let windowScales = windowRestoration.update(
      pointer: activity.pointerPosition, windows: windows, at: now)

    // History only adjusts depth after a region qualifies on present evidence.
    // An immature or malformed record earns no extra dimming.
    let useHistory = exposure.sampleCount >= ExposureAccumulator.minimumSamplesForAnalysis
      && exposure.cells.count == PanelGrid.cellCount
      && exposure.cells.allSatisfy { $0.isFinite && $0 >= 0 }
      && exposure.mean.isFinite && exposure.mean > 0
    let mean = useHistory ? exposure.mean : 0
    var cells = Array(repeating: 0.0, count: PanelGrid.cellCount)
    for cell in cells.indices {
      let held = evidence[cell]
      guard held.samples >= 6, now.timeIntervalSince(held.since) >= Self.minimumDuration,
        brightness[cell] >= StaticRegionDetector.Thresholds.defaultMinimumLuminance,
        let window = observation.windowIDByCell[cell],
        let owner = observation.ownerPIDByCell[cell],
        held.windowID == window, held.ownerPID == owner,
        (observation.stationarySecondsByWindowID[window] ?? 0)
          >= WindowObserver.stationaryThresholdSeconds,
        owner != frontmostPID
      else { continue }
      // 15% normally, rising to 25% at twice the panel's average exposure.
      // These are conservative policy limits, not calibrated wear estimates.
      let extra = useHistory ? min(1, max(0, exposure.cells[cell] / mean - 1)) * 0.10 : 0
      cells[cell] = min(0.25, StaticRegionDetector.Thresholds.defaultDepth + extra)
    }
    cells = Self.featherBoundaries(cells)
    // Hover changes opacity, not eligibility. Feather first so restoring one
    // window cannot weaken protection at a neighboring window's boundary.
    for cell in cells.indices {
      if let window = observation.windowIDByCell[cell] {
        cells[cell] *= windowScales[window] ?? 1
      }
    }
    let mask = OverlayMask(cells: cells)
    return mask.peak > 0 ? mask : nil
  }

  /// Taper inward over two cells before the renderer interpolates the grid.
  /// Filtering eligibility (not depth) keeps exposure-weighted interiors intact.
  /// Only reduce nominated cells: a blur that spread alpha outward would dim
  /// moving content, foreground windows, and cells with ambiguous ownership.
  private static func featherBoundaries(_ cells: [Double]) -> [Double] {
    let weights = [1.0, 4, 6, 4, 1]
    var result = cells
    for row in 0..<PanelGrid.rows {
      for col in 0..<PanelGrid.cols {
        let cell = row * PanelGrid.cols + col
        guard cells[cell] > 0 else { continue }
        var support = 0.0
        for dy in -2...2 {
          // There is no adjacent content beyond the physical panel. Clamp so
          // a region reaching the display edge doesn't acquire a bright rim.
          let y = min(PanelGrid.rows - 1, max(0, row + dy))
          for dx in -2...2 {
            let x = min(PanelGrid.cols - 1, max(0, col + dx))
            if cells[y * PanelGrid.cols + x] > 0 {
              support += weights[dy + 2] * weights[dx + 2]
            }
          }
        }
        result[cell] *= support / 256
      }
    }
    return result
  }

  private static func valid(_ observation: WindowObservation) -> Bool {
    observation.windowIDByCell.count == PanelGrid.cellCount
      && observation.ownerPIDByCell.count == PanelGrid.cellCount
      && observation.stationaryByCell.count == PanelGrid.cellCount
  }

  /// Hash the spatial detail before reducing to a mean. Two moving patterns
  /// with equal average luminance must not look like an unchanged region.
  /// Quantization ignores small luminance changes within a bin; boundary noise
  /// can reset stability, which withholds dimming rather than inventing it.
  private static func fingerprints(_ grid: [Double], cols: Int, rows: Int,
                                   through transform: PanelSpaceTransform) -> [UInt64]? {
    let maximumEdge = max(PanelGrid.cols, PanelGrid.rows) * LuminanceReduction.captureOversample
    guard cols > 0, rows > 0, cols <= maximumEdge, rows <= maximumEdge,
      grid.count == cols * rows, grid.allSatisfy({ $0.isFinite && $0 >= 0 }),
      transform.displaySize.width.isFinite, transform.displaySize.height.isFinite,
      transform.displaySize.width > 0, transform.displaySize.height > 0
    else { return nil }
    var hashes = Array(repeating: UInt64(14695981039346656037), count: PanelGrid.cellCount)
    var covered = Array(repeating: false, count: PanelGrid.cellCount)
    for y in 0..<rows {
      for x in 0..<cols {
        let point = CGPoint(x: (Double(x) + 0.5) / Double(cols) * transform.displaySize.width,
                            y: (Double(y) + 0.5) / Double(rows) * transform.displaySize.height)
        guard let cell = transform.cell(forDisplayPoint: point) else { return nil }
        let value = UInt64((min(1, grid[y * cols + x]) * 31).rounded())
        hashes[cell] = (hashes[cell] ^ value) &* 1099511628211
        covered[cell] = true
      }
    }
    return covered.allSatisfy { $0 } ? hashes : nil
  }
}
