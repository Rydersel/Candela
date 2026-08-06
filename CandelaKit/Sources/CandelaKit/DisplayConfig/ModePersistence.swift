import Foundation

/// How well a stored mode could be honoured on the modes actually available.
/// Anything other than `.exact` is surfaced to the user rather than applied
/// silently (spec §8).
public enum ModeMatch: Sendable, Equatable {
  case exact(DisplayMode)
  case refreshRateDiffers(DisplayMode)
  case scaleDiffers(DisplayMode)
  case sizeDiffers(DisplayMode)
  case none
}

/// Per-display stored mode, opt-in.
///
/// Stores a DESCRIPTOR, never an `ioModeID` — IDs are reassigned across replug
/// and a stored one would silently resolve to a different mode or none (DM6).
///
/// UserDefaults is documented thread-safe and it is the only stored property,
/// hence the unchecked conformance — same shape as `DisplayPrefs` and
/// `UserDefaultsBrightnessStore`.
public final class ModePersistence: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func isEnabled(for identity: DisplayConfigIdentity) -> Bool {
    defaults.bool(forKey: key(PrefName.rememberDisplayMode, identity))
  }

  public func setEnabled(_ enabled: Bool, for identity: DisplayConfigIdentity) {
    defaults.set(enabled, forKey: key(PrefName.rememberDisplayMode, identity))
  }

  public func storedMode(for identity: DisplayConfigIdentity) -> DisplayModeDescriptor? {
    guard let data = defaults.data(forKey: key(PrefName.storedDisplayMode, identity)) else {
      return nil
    }
    return try? JSONDecoder().decode(DisplayModeDescriptor.self, from: data)
  }

  public func store(_ descriptor: DisplayModeDescriptor, for identity: DisplayConfigIdentity) {
    guard let data = try? JSONEncoder().encode(descriptor) else { return }
    defaults.set(data, forKey: key(PrefName.storedDisplayMode, identity))
  }

  /// Clears the stored MODE only. The opt-in flag is left alone deliberately:
  /// "forget the mode I picked" and "stop remembering modes on this display"
  /// are separate answers, and clearing both here would silently opt the user
  /// back out the first time a mode became unavailable.
  ///
  /// No production caller yet — this is the engine seam issue #49 (forget a
  /// remembered mode) wires up.
  public func clear(for identity: DisplayConfigIdentity) {
    defaults.removeObject(forKey: key(PrefName.storedDisplayMode, identity))
  }

  /// Resolution order, specified because it runs unattended on every reconnect.
  ///
  /// 1. exact geometry + refresh
  /// 2. same geometry, nearest refresh
  /// 3. same logical size, any framebuffer — HiDPI preferred over 1x
  /// 4. nearest logical area OF THE SAME ASPECT RATIO
  /// 5. nothing
  ///
  /// EVERY step picks deterministically, ties broken on `ioModeID` — including
  /// the first, which is the same nearest-rate selection as the second and
  /// merely reports `.exact` when the winner lands inside the tolerance. A
  /// selection decided by CoreGraphics' enumeration order is not an answer we
  /// can explain to the user or reproduce in a bug report: the nearest logical
  /// size typically exists at two framebuffers and six refresh rates, and even
  /// at exact geometry two rates can sit inside the match window at once.
  public static func resolve(
    _ descriptor: DisplayModeDescriptor, in modes: [DisplayMode]
  ) -> ModeMatch {
    guard !modes.isEmpty else { return .none }

    let sameGeometry = modes.filter {
      $0.logicalWidth == descriptor.logicalWidth
        && $0.logicalHeight == descriptor.logicalHeight
        && $0.pixelWidth == descriptor.pixelWidth
        && $0.pixelHeight == descriptor.pixelHeight
    }
    // Steps 1 and 2 are ONE selection, not two: pick the nearest rate, then ask
    // whether it is near enough to call exact.
    //
    // Refresh rates are compared with a tolerance, NOT with ==. CoreGraphics
    // reports rates like 59.997 rather than 60, so an exact Double comparison
    // means a stored mode never matches on real hardware and every reconnect
    // silently degrades to a fallback branch. But the tolerance is wider than
    // the gap between an NTSC rate and its integer twin — 59.9 and 60 are 0.1
    // apart and BOTH match — so "first in the window" answers a question the
    // window cannot answer, and answers it with CoreGraphics' enumeration order.
    //
    // That was a visible defect, not a theoretical one: `quantizedRefresh`
    // keeps 59.9 and 60 apart and `DisplayModeCopy` renders them as separate
    // picker rows, so selecting 59.9 could resolve to the 60 mode — whose
    // `ioModeID` is the one already current, which `DisplayModeSection.apply`
    // then early-returns on. The picker snapped back and nothing happened.
    // Taking the nearest also makes this the only step that does not depend on
    // enumeration order, matching steps 2–4.
    if let nearestRefresh = sameGeometry.min(by: { closerRefresh($0, $1, to: descriptor) }) {
      return Self.refreshMatches(nearestRefresh.refreshHz, descriptor.refreshHz)
        ? .exact(nearestRefresh)
        : .refreshRateDiffers(nearestRefresh)
    }

    // Same logical size, different framebuffer. Prefer the HiDPI candidate —
    // silently dropping a stored HiDPI choice to 1x reads as the feature
    // breaking.
    let sameLogicalSize = modes.filter {
      $0.logicalWidth == descriptor.logicalWidth && $0.logicalHeight == descriptor.logicalHeight
    }
    let hiDPI = sameLogicalSize.filter(\.isHiDPI)
    let pool = hiDPI.isEmpty ? sameLogicalSize : hiDPI
    // Always `.scaleDiffers`, never `.refreshRateDiffers`: reaching here means
    // step 2 found NO candidate at the stored framebuffer, so every mode in the
    // pool differs in scale. Reporting a HiDPI substitute as a refresh change
    // would tell the user their rate moved while their scaling was what
    // actually changed.
    if let best = pool.min(by: { closerRefresh($0, $1, to: descriptor) }) {
      return .scaleDiffers(best)
    }

    // Never cross aspect ratios: a 16:9 substitute on a 21:9 panel letterboxes
    // or stretches, and nobody asked for that.
    let sameShape = modes.filter { abs($0.aspectRatio - descriptor.aspectRatio) < 0.01 }
    guard let nearest = sameShape.min(by: { lhs, rhs in
      let lhsGap = abs(lhs.logicalArea - descriptor.logicalArea)
      let rhsGap = abs(rhs.logicalArea - descriptor.logicalArea)
      if lhsGap != rhsGap { return lhsGap < rhsGap }
      // Same size from here on: the HiDPI-over-1x rule and the stored refresh
      // rate still apply, exactly as in step 3.
      if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
      return closerRefresh(lhs, rhs, to: descriptor)
    }) else {
      return .none
    }
    return .sizeDiffers(nearest)
  }

  /// CoreGraphics reports refresh rates as 59.997-style Doubles, so stored and
  /// live rates are compared with a tolerance. Half a hertz separates every
  /// real rate pair (24/25/30/50/60/120/175) by a wide margin.
  ///
  /// It does NOT separate 59.94 from 60. Those collapse into one match, which
  /// is the right trade here: the alternative is a tolerance tight enough to be
  /// beaten by CoreGraphics' own float noise, and a stored mode that never
  /// matches is a far worse failure than an NTSC rate resolving to 60.
  static func refreshMatches(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.5
  }

  /// Nearest to the STORED rate, with a stable tie-break. Used by every
  /// fallback step so a deliberate 60 Hz choice is not bumped to the panel's
  /// fastest rate on the way through.
  private static func closerRefresh(
    _ lhs: DisplayMode, _ rhs: DisplayMode, to descriptor: DisplayModeDescriptor
  ) -> Bool {
    let lhsGap = abs(lhs.refreshHz - descriptor.refreshHz)
    let rhsGap = abs(rhs.refreshHz - descriptor.refreshHz)
    if lhsGap != rhsGap { return lhsGap < rhsGap }
    return lhs.ioModeID < rhs.ioModeID
  }

  private func key(_ name: PrefName, _ identity: DisplayConfigIdentity) -> String {
    "\(name.rawValue).\(identity.key)"
  }
}
