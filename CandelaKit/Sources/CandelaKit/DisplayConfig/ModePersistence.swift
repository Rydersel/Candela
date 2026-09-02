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
/// Stores a DESCRIPTOR, never an `ioModeID`: IDs are reassigned across replug
/// and a stored one would silently resolve to a different mode or none.
///
/// UserDefaults is documented thread-safe and it is the only stored property,
/// hence the unchecked conformance, the same shape as `DisplayPrefs` and
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
  public func clear(for identity: DisplayConfigIdentity) {
    defaults.removeObject(forKey: key(PrefName.storedDisplayMode, identity))
  }

  /// Resolves a stored choice against the live list, first in the orientation
  /// it was recorded in and then transposed.
  ///
  /// A quarter turn swaps the axes of the WHOLE mode list, so a descriptor
  /// recorded un-rotated cannot match anything a rotated display publishes, even
  /// though the identical panel-native mode is present with its sides swapped.
  /// The transposed arm exists for that case, and runs ONLY when the literal arm
  /// found nothing at the stored logical size.
  ///
  /// That condition is the whole rule. If the literal arm DID find the stored
  /// logical size, the record was saved in the frame the display is in now, so a
  /// transposed twin sitting in the same list is a genuinely different desktop
  /// shape rather than a rotation artifact: taking it would change the shape of
  /// the screen to fix a refresh delta. A literal `.refreshRateDiffers` or
  /// `.scaleDiffers` therefore beats a transposed `.exact`. Below that line the
  /// better-ranked outcome wins and the literal arm takes ties.
  ///
  /// It is the stored size being present that decides this, not the display's
  /// orientation: an un-rotated display whose stored size has since vanished from
  /// the list does run the second pass, and finds nothing there to prefer.
  ///
  /// A transposed exact match reports `.exact` and so applies silently, on
  /// purpose: it is the same panel-native picture the user chose, and a
  /// substitution notice for a pure orientation swap reads as a bug rather than
  /// as honesty.
  public static func resolve(
    _ descriptor: DisplayModeDescriptor, in modes: [DisplayMode]
  ) -> ModeMatch {
    let literal = resolveLiteral(descriptor, in: modes)
    switch literal {
    case .exact, .refreshRateDiffers, .scaleDiffers:
      return literal
    case .sizeDiffers, .none:
      let transposed = resolveLiteral(descriptor.transposed, in: modes)
      return rank(transposed) > rank(literal) ? transposed : literal
    }
  }

  /// Outcome quality, best first. Mirrors `resolveLiteral`'s own step order
  /// rather than inventing a second opinion about which compromise is worse:
  /// exact, then the same geometry at another rate, then the same logical size
  /// at another framebuffer, then another size, then nothing.
  ///
  /// Only ever asked about the two arms below the same-logical-size line, where
  /// neither has the stored size to offer and they are genuinely comparable.
  private static func rank(_ match: ModeMatch) -> Int {
    switch match {
    case .exact: 4
    case .refreshRateDiffers: 3
    case .scaleDiffers: 2
    case .sizeDiffers: 1
    case .none: 0
    }
  }

  /// Resolution order, specified because it runs unattended on every reconnect.
  ///
  /// Orientation-literal by design: `resolve` is what tries the other
  /// orientation, and it does so by handing this method a transposed
  /// descriptor rather than by loosening any comparison here.
  ///
  /// 1. exact geometry + refresh
  /// 2. same geometry, nearest refresh
  /// 3. same logical size, any framebuffer, HiDPI preferred over 1x
  /// 4. nearest logical area OF THE SAME ASPECT RATIO
  /// 5. nothing
  ///
  /// EVERY step picks deterministically, ties broken on `ioModeID`, including
  /// the first, which is the same nearest-rate selection as the second and merely
  /// reports `.exact` when the winner lands inside the tolerance. A selection
  /// decided by CoreGraphics' enumeration order cannot be explained to the user
  /// or reproduced in a bug report: the nearest logical size typically exists at
  /// two framebuffers and six refresh rates, and even at exact geometry two rates
  /// can sit inside the match window at once.
  private static func resolveLiteral(
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
    // silently degrades to a fallback branch. But the tolerance is wider than the
    // gap between an NTSC rate and its integer twin (59.9 and 60 are 0.1 apart
    // and BOTH match), so "first in the window" would answer with CoreGraphics'
    // enumeration order.
    //
    // That was a visible defect, not a theoretical one: `quantizedRefresh` keeps
    // 59.9 and 60 apart and `DisplayModeCopy` renders them as separate picker
    // rows, so selecting 59.9 could resolve to the 60 mode, whose `ioModeID` is
    // the one already current, which `DisplayHubView.apply` then early-returns
    // on. The picker snapped back and nothing happened.
    if let nearestRefresh = sameGeometry.min(by: { closerRefresh($0, $1, to: descriptor) }) {
      return Self.refreshMatches(nearestRefresh.refreshHz, descriptor.refreshHz)
        ? .exact(nearestRefresh)
        : .refreshRateDiffers(nearestRefresh)
    }

    // Same logical size, different framebuffer. Prefer the HiDPI candidate:
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

extension DisplayModeDescriptor {
  /// The same stored choice seen through a quarter turn: both size pairs
  /// swapped, the refresh rate untouched, since rotation does not retime the
  /// panel.
  ///
  /// Computed rather than stored, so the descriptor's CodingKeys stay exactly
  /// the shipped on-disk format. Only what `resolve` looks for changes.
  var transposed: DisplayModeDescriptor {
    DisplayModeDescriptor(
      logicalWidth: logicalHeight, logicalHeight: logicalWidth,
      pixelWidth: pixelHeight, pixelHeight: pixelWidth,
      refreshHz: refreshHz
    )
  }
}
