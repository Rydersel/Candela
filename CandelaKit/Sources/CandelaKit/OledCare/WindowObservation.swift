import CoreGraphics
import Foundation

/// One window as the window server describes it.
///
/// **OC18: no title, ever.** `kCGWindowName` is the only field of a window list
/// gated behind Screen Recording, and it carries what the user was reading.
/// Attribution needs the owning app, which is free; a title field here would
/// turn a permission-free feature into a permissioned one and put document names
/// into a persisted store.
public struct WindowSnapshot: Equatable, Sendable {
  public let windowID: UInt32
  public let ownerPID: Int32
  public let ownerName: String
  /// Display-local coordinates, top-left origin. `CGWindowListCopyWindowInfo`
  /// reports globals; the caller subtracts the display origin.
  public let bounds: CGRect
  public let layer: Int

  public init(
    windowID: UInt32, ownerPID: Int32, ownerName: String, bounds: CGRect, layer: Int
  ) {
    self.windowID = windowID
    self.ownerPID = ownerPID
    self.ownerName = ownerName
    self.bounds = bounds
    self.layer = layer
  }
}

/// The seam between Kit's attribution logic and CoreGraphics' window list.
///
/// The protocol lives in Kit, but its only real implementation is an app-target
/// island, so the tests here drive `WindowObserver` with literal snapshots and
/// never touch the window server.
public protocol WindowListing: Sendable {
  /// On-screen windows, in display coordinates, EXCLUDING our own process.
  func onScreenWindows() -> [WindowSnapshot]
}

/// What one window-list sample says about a panel.
public struct WindowObservation: Equatable, Sendable {
  /// Per-cell dominant owner app; nil where nothing covers.
  public let dominantOwnerByCell: [String?]
  /// Seconds each still-present window has held unchanged bounds.
  public let stationarySecondsByWindowID: [UInt32: TimeInterval]
  /// True where the covering window has been stationary past the threshold.
  public let stationaryByCell: [Bool]
  public let fullScreenOwner: String?

  public init(
    dominantOwnerByCell: [String?],
    stationarySecondsByWindowID: [UInt32: TimeInterval],
    stationaryByCell: [Bool],
    fullScreenOwner: String?
  ) {
    self.dominantOwnerByCell = dominantOwnerByCell
    self.stationarySecondsByWindowID = stationarySecondsByWindowID
    self.stationaryByCell = stationaryByCell
    self.fullScreenOwner = fullScreenOwner
  }
}

/// Attributes panel cells to the app covering them, and ages each window's
/// bounds to spot regions that have not moved.
///
/// **Stationary bounds are a prior, not a verdict.** A video player holds a
/// fixed rect while every pixel under it changes, and this type calls it
/// stationary. Geometry cannot tell static content from moving content without
/// reading pixels or titles, and OC18 rules the second out, so what comes out of
/// here is evidence to weigh and never a conclusion to act on alone.
public struct WindowObserver: Sendable {
  /// Five minutes of unmoved bounds. Long enough that dragging a window around
  /// a workspace never trips it, short enough that a left-open editor does.
  public static let stationaryThresholdSeconds: TimeInterval = 300

  /// Full screen is a match on bounds, and window bounds arrive as integers, so
  /// this absorbs float representation rather than near misses. A window inset
  /// by the menu bar is 25 pt off and must not read as full screen.
  public static let fullScreenTolerancePoints: CGFloat = 2

  /// Layer 0 is an ordinary application window. Anything above it is chrome (a
  /// shade, a screen saver, another tool's overlay), and a screen-filling one is
  /// not an app running full screen.
  private static let normalWindowLayer = 0

  private struct Held: Sendable {
    var bounds: CGRect
    var since: Date
  }

  private var held: [UInt32: Held] = [:]

  public init() {}

  public mutating func observe(
    _ windows: [WindowSnapshot],
    through transform: PanelSpaceTransform,
    at now: Date
  ) -> WindowObservation {
    // Rebuilt rather than mutated: a window absent from this snapshot is gone
    // from the table, so a long session cannot accumulate dead window IDs.
    var current: [UInt32: Held] = [:]
    current.reserveCapacity(windows.count)
    for window in windows {
      let previous = held[window.windowID]
      let unmoved = previous?.bounds == window.bounds
      current[window.windowID] = Held(
        bounds: window.bounds, since: unmoved ? previous!.since : now)
    }
    held = current

    // Clamped: `now` comes from the caller's clock, and a backwards step must
    // read as "just arrived" rather than as a negative age.
    let ages = current.mapValues { max(0, now.timeIntervalSince($0.since)) }

    var owners = [String?](repeating: nil, count: PanelGrid.cellCount)
    var stationary = [Bool](repeating: false, count: PanelGrid.cellCount)
    var best = [Double](repeating: 0, count: PanelGrid.cellCount)

    for window in windows {
      let coverage = transform.coverage(ofDisplayRect: window.bounds)
      let isStationary = (ages[window.windowID] ?? 0) >= Self.stationaryThresholdSeconds
      for cell in 0..<PanelGrid.cellCount where coverage[cell] > best[cell] {
        best[cell] = coverage[cell]
        owners[cell] = window.ownerName
        stationary[cell] = isStationary
      }
    }

    return WindowObservation(
      dominantOwnerByCell: owners,
      stationarySecondsByWindowID: ages,
      stationaryByCell: stationary,
      fullScreenOwner: fullScreenOwner(among: windows, on: transform.displaySize))
  }

  private func fullScreenOwner(among windows: [WindowSnapshot], on displaySize: CGSize)
    -> String?
  {
    guard displaySize.width > 0, displaySize.height > 0 else { return nil }
    let display = CGRect(origin: .zero, size: displaySize)
    let tolerance = Self.fullScreenTolerancePoints
    // First match wins: the window list arrives front-to-back, so the frontmost
    // screen-filling window is the one actually being looked at.
    return windows.first { window in
      window.layer <= Self.normalWindowLayer
        && abs(window.bounds.minX - display.minX) <= tolerance
        && abs(window.bounds.minY - display.minY) <= tolerance
        && abs(window.bounds.maxX - display.maxX) <= tolerance
        && abs(window.bounds.maxY - display.maxY) <= tolerance
    }?.ownerName
  }
}
