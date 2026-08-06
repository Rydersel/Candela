import CoreGraphics
import Foundation
import os

/// The real `DisplayArrangementConfiguring`. Thin on purpose — it applies and
/// reports; every decision lives in the pure types (`ArrangementPlan`,
/// `ArrangementVerification`, `ArrangementOutcomePolicy`). The sibling of
/// `CoreGraphicsDisplayConfigurator`, and deliberately the same shape: one
/// transaction, every stage checked, cancel on the first failure, and a
/// post-commit read-back that does not take the return code as evidence.
public struct CoreGraphicsArrangementConfigurator: DisplayArrangementConfiguring {
  /// Where the display list, its identities and its mirror state come from.
  /// Reused rather than re-enumerated: `CoreGraphicsDisplayConfigurator.displays()`
  /// samples ONLINE displays and their mirror state in one loop so both describe
  /// the same instant, and it carries an audited `CGDisplayIsBuiltin` call site
  /// (that call returns **-1** for an ID it does not know). A second enumeration
  /// here would be a second thing to keep correct.
  private let displays: any DisplayConfiguring

  public init(displays: any DisplayConfiguring = CoreGraphicsDisplayConfigurator()) {
    self.displays = displays
  }

  public func currentArrangement() -> DisplayArrangement {
    currentTopology().arrangement
  }

  /// Expressed in terms of ONE `displays()` call, which is what makes the pair
  /// describe the same instant — the property the restore path's completeness
  /// check depends on.
  public func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement) {
    let online = displays.displays()
    return (online, ArrangementSnapshot.arrangement(of: online, bounds: CGDisplayBounds))
  }

  public func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement {
    let config = try beginDisplayConfiguration()
    // EVERY change, including the displays that are already where the plan puts
    // them (AR4). displayplacer skips those because "setting a screen to its
    // current origin makes displayplacer hang for a couple seconds"
    // (arrangement research §3, [C]) — that is a third-party report we have not
    // measured, and the cost of acting on it is handing every unnamed display
    // to CoreGraphics' "as close as possible to its current location"
    // heuristic (§4.2). If the hang shows up on hardware, the skip belongs in
    // `ArrangementPlan` where it can be reasoned about, not here.
    for change in plan.changes {
      guard let x = Int32(exactly: change.origin.x), let y = Int32(exactly: change.origin.y) else {
        CGCancelDisplayConfiguration(config)
        throw DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
      }
      // Staging is CHECKED, not discarded: if it fails,
      // `CGCompleteDisplayConfiguration` happily commits the (empty)
      // configuration and returns `.success`, so this would return normally
      // having moved nothing. Every early exit cancels, so the config ref is
      // never leaked — the fork's `Mirroring.swift` returned without cancelling
      // and that is the defect this discipline exists to prevent.
      let staged = CGConfigureDisplayOrigin(config, change.id, x, y)
      guard staged == .success else {
        CGCancelDisplayConfiguration(config)
        throw DisplayConfigError(cgErrorCode: staged.rawValue)
      }
    }
    // The header notes a complete can fail for reasons that have nothing to do
    // with the layout — an unsupported mode, or another app running full-screen
    // (§4.5). That is a user-explicable failure to surface, not to retry.
    let result = CGCompleteDisplayConfiguration(config, scope.configureOption)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }

    // THE RETURN CODE IS NOT THE EVIDENCE — the achieved layout is, and for
    // arrangement the divergence is *designed in*: the API treats origins as a
    // request and snaps the result to a gapless, non-overlapping layout (§4.1).
    // So the result is read back and returned, never the request. Whether a
    // difference is a divergence or the documented adjustment is
    // `ArrangementVerification`'s call, not this file's.
    let achieved = currentArrangement()
    if let unhonoured = ArrangementVerification.unhonoured(plan: plan, achieved: achieved) {
      // The only log line in this type, and it earns its place: the thrown code
      // below is generic, so without this a real occurrence is a bare
      // "CoreGraphics error 1000" in the UI with nothing naming which display
      // the platform put somewhere else.
      Logger(subsystem: "com.rydersel.Candela", category: "topology").error(
        """
        CoreGraphics reported success for a layout it did not apply: display \
        \(unhonoured.id, privacy: .public) was asked for \
        (\(unhonoured.origin.x, privacy: .public), \
        \(unhonoured.origin.y, privacy: .public)) and did not land in that \
        position relative to the rest of the layout
        """
      )
      // Deliberately not a platform error code — the platform did not report
      // one, which is the entire point of this check. Same reasoning and the
      // same code as `CoreGraphicsDisplayConfigurator.applyMirroring`.
      throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    }
    return achieved
  }
}

/// Turns a display list plus `CGDisplayBounds` into a `DisplayArrangement`.
///
/// Separated from the configurator for the same reason `MirrorVerification` is
/// separated from `applyMirroring`: it is the one part of reading the layout
/// that has rules, and the rules are testable without reconfiguring the
/// machine.
enum ArrangementSnapshot {
  /// **AR6.** A mirror slave gets no tile: it has no independent position, and
  /// setting its origin would remove it from the mirror set
  /// (`CGDisplayConfiguration.h:49-50`). It is recorded on its master's
  /// `mirroredIDs` instead, so the UI can name it and a plan can never carry it.
  ///
  /// A display whose bounds cannot be read is **skipped**, and that is a real
  /// exclusion rather than a formality: `CGDisplayBounds` returns `CGRectNull`
  /// — an origin of infinity — for an ID it does not know, and `Int(infinity)`
  /// traps. A display in that state is not in the desktop coordinate space, so
  /// it has no place in a layout; the arrangement returned describes only the
  /// displays that do. The caller that must not act on a partial picture is the
  /// reapply path, which defers on the same signal (§4.4).
  static func arrangement(
    of displays: [ConfiguredDisplay],
    bounds: (CGDirectDisplayID) -> CGRect
  ) -> DisplayArrangement {
    DisplayArrangement(tiles: displays.compactMap { display in
      guard !display.isMirrorSlave, let rect = displayRect(bounds(display.id)) else { return nil }
      return ArrangementTile(
        id: display.id,
        identity: display.identity,
        name: display.name,
        rect: rect,
        // Sorted so the value is a function of the topology and not of the
        // enumeration order — two reads of an unchanged machine must compare
        // equal, which is what makes "the layout has not changed" decidable.
        mirroredIDs: displays.filter { $0.mirrorsDisplay == display.id }.map(\.id).sorted()
      )
    })
  }

  /// Display space is integral (AR1) and `CGDisplayBounds` is measured integral
  /// in POINTS, not pixels (arrangement research §1.2) — the rounding is a
  /// conversion, not a quantisation. `nil` for anything that is not a finite
  /// rect, which is what an unknown display ID reports.
  private static func displayRect(_ rect: CGRect) -> DisplayRect? {
    guard !rect.isNull, rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.size.width.isFinite, rect.size.height.isFinite,
          !rect.isEmpty
    else { return nil }
    return DisplayRect(
      x: Int(rect.origin.x.rounded()),
      y: Int(rect.origin.y.rounded()),
      width: Int(rect.size.width.rounded()),
      height: Int(rect.size.height.rounded())
    )
  }
}
