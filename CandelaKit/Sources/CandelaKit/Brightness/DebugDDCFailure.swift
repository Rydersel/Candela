#if DEBUG
  import Foundation

  /// Makes one display's DDC brightness writes report failure, so the wire
  /// degradation can be provoked on a rig where every cable works (WD6).
  ///
  /// The rig's two externals both honour their writes, and the only ways to
  /// produce a genuinely refusing wire are to unplug the data cable mid-session
  /// or to engage HDR, which is the one case the feature must NOT react to. That
  /// leaves the interesting half of the behaviour, the demotion and its three
  /// recovery routes, unreachable without a seam.
  ///
  /// The WHOLE file is inside `#if DEBUG`, and so is its call site in
  /// `BrightnessController.brightnessApplier`, following `DebugPanelDump`:
  /// compiled out of Release BY CONSTRUCTION rather than by remembering to
  /// delete it, which is what lets the standing Release marker grep (every
  /// Mach-O in the bundle, with a positive control) prove it is gone.
  ///
  /// Trigger: `CANDELA_DEBUG_DDC_FAIL`, read ONCE and cached. Its value is a
  /// PREFIX of the display's persistence key, which is normally its EDID UUID
  /// and not something anyone types from memory: read the key off the panel
  /// dump's `key=` field or the display's Diagnostics page, and pass enough of
  /// its start to be unique on the rig.
  ///
  ///   CANDELA_DEBUG_DDC_FAIL=4C2D0B0F Candela.app/Contents/MacOS/Candela &
  ///
  /// A prefix rather than an exact match so the two can be read off a dump and
  /// truncated, and because the fallback key for a panel with no EDID UUID
  /// starts with its product name.
  ///
  /// An empty value matches nothing, so `CANDELA_DEBUG_DDC_FAIL=` is not a way
  /// to fail every display at once: killing brightness on the built-in Mac panel
  /// and both externals in one launch is a state nobody is trying to test.
  ///
  /// It fails the BRIGHTNESS applier only, not the writer underneath it, so the
  /// same display's volume and contrast keep working: a wire that stopped
  /// carrying one command is what the degradation reacts to, and a rig leg has
  /// to be able to see that the rest of the cable is fine.
  enum DebugDDCFailure {
    static let environmentKey = "CANDELA_DEBUG_DDC_FAIL"

    /// Read once. The applier is rebuilt per submit, and re-reading the
    /// environment per write would suggest it can change under a running
    /// process.
    static let keyPrefix: String? = {
      guard let value = ProcessInfo.processInfo.environment[environmentKey],
            !value.isEmpty
      else { return nil }
      return value
    }()

    static func isFailing(persistenceKey: String?) -> Bool {
      guard let keyPrefix, let persistenceKey else { return false }
      return persistenceKey.hasPrefix(keyPrefix)
    }
  }

  /// Reports failure for every DDC target, without touching the wire: the point
  /// is a display whose writes do not land, and an actual write that succeeded
  /// would move the panel underneath the test.
  struct FailingDDCApplier: BrightnessApplying {
    let accepts = HardwareTargetKind.ddc

    func apply(_: HardwareTarget) async -> Bool { false }
  }
#endif
