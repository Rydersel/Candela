#if DEBUG
  import Foundation

  /// Makes one display's DDC brightness writes report failure, so wire
  /// degradation can be provoked on a rig where every cable works. The
  /// alternatives are unplugging the data cable mid-session, or engaging HDR,
  /// which is the one case the feature must NOT react to.
  ///
  /// File and call site are both inside `#if DEBUG`, so the standing Release
  /// marker grep can prove it is gone.
  ///
  /// `CANDELA_DEBUG_DDC_FAIL` takes a PREFIX of the display's persistence key,
  /// normally its EDID UUID; read it off the panel dump's `key=` field or the
  /// Diagnostics page.
  ///
  ///   CANDELA_DEBUG_DDC_FAIL=4C2D0B0F Candela.app/Contents/MacOS/Candela &
  ///
  /// An empty value matches nothing. It fails the BRIGHTNESS applier only, not
  /// the writer underneath it, so volume and contrast keep working.
  enum DebugDDCFailure {
    static let environmentKey = "CANDELA_DEBUG_DDC_FAIL"

    /// Read once: the applier is rebuilt per submit, and re-reading per write
    /// would suggest the value can change under a running process.
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

  /// Reports failure for every DDC target without touching the wire: a write
  /// that actually succeeded would move the panel underneath the test.
  struct FailingDDCApplier: BrightnessApplying {
    let accepts = HardwareTargetKind.ddc

    func apply(_: HardwareTarget) async -> Bool { false }
  }
#endif
