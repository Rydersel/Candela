import CoreGraphics
import Foundation
import os

/// Applies and reports; the decisions live in the pure types. Same shape as
/// `CoreGraphicsDisplayConfigurator`: one transaction, every stage checked, cancel
/// on the first failure, and a post-commit read-back, because a return code is not
/// evidence.
public struct CoreGraphicsArrangementConfigurator: DisplayArrangementConfiguring {
  /// Reused rather than re-enumerated: `CoreGraphicsDisplayConfigurator.displays()`
  /// samples online displays and their mirror state in one loop, so both describe
  /// the same instant.
  private let displays: any DisplayConfiguring

  public init(displays: any DisplayConfiguring = CoreGraphicsDisplayConfigurator()) {
    self.displays = displays
  }

  public func currentArrangement() -> DisplayArrangement {
    currentTopology().arrangement
  }

  /// ONE `displays()` call, so the pair describes the same instant: the property
  /// the restore path's completeness check depends on.
  public func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement) {
    let online = displays.displays()
    return (online, ArrangementSnapshot.arrangement(of: online, bounds: CGDisplayBounds))
  }

  public func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement {
    let config = try beginDisplayConfiguration()
    // EVERY change, including displays already where the plan puts them (AR4).
    // displayplacer skips those to dodge a hang we have never measured, and the
    // cost of skipping is handing every unnamed display to CoreGraphics'
    // "as close as possible to its current location" heuristic.
    for change in plan.changes {
      guard let x = Int32(exactly: change.origin.x), let y = Int32(exactly: change.origin.y) else {
        CGCancelDisplayConfiguration(config)
        throw DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
      }
      // Staging is CHECKED: when it fails, `CGCompleteDisplayConfiguration` still
      // commits the empty configuration and returns `.success`, so this would return
      // normally having moved nothing. Every early exit cancels, so the config ref is
      // never leaked; the fork's `Mirroring.swift` returned without cancelling.
      let staged = CGConfigureDisplayOrigin(config, change.id, x, y)
      guard staged == .success else {
        CGCancelDisplayConfiguration(config)
        throw DisplayConfigError(cgErrorCode: staged.rawValue)
      }
    }
    // A complete can fail for reasons unrelated to the layout: an unsupported mode,
    // or another app running full-screen. Surface it, do not retry.
    let result = CGCompleteDisplayConfiguration(config, scope.configureOption)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }

    // The achieved layout is the evidence, never the return code, and here the
    // divergence is designed in: the API treats origins as a request and snaps the
    // result to a gapless, non-overlapping layout. Whether a difference is a
    // divergence or that documented adjustment is `ArrangementVerification`'s call.
    let achieved = currentArrangement()
    if let unhonoured = ArrangementVerification.unhonoured(plan: plan, achieved: achieved) {
      // The thrown code below is generic, so without this a real occurrence is a
      // bare "CoreGraphics error 1000" naming no display.
      Logger(subsystem: "com.rydersel.Candela", category: "topology").error(
        """
        CoreGraphics reported success for a layout it did not apply: display \
        \(unhonoured.id, privacy: .public) was asked for \
        (\(unhonoured.origin.x, privacy: .public), \
        \(unhonoured.origin.y, privacy: .public)) and did not land in that \
        position relative to the rest of the layout
        """
      )
      // Not a platform error code: the platform did not report one, which is the
      // point of this check. Same code as
      // `CoreGraphicsDisplayConfigurator.applyMirroring`.
      throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    }
    return achieved
  }
}

/// Turns a display list plus `CGDisplayBounds` into a `DisplayArrangement`. Split
/// from the configurator so the reading rules are testable without reconfiguring
/// the machine.
enum ArrangementSnapshot {
  /// **AR6.** A mirror slave gets no tile: it has no independent position, and
  /// setting its origin would remove it from the mirror set. It rides on its
  /// master's `mirroredIDs` instead, so the UI can name it and no plan can carry it.
  ///
  /// A display whose bounds cannot be read is skipped: `CGDisplayBounds` returns
  /// `CGRectNull` (origin infinity) for an ID it does not know, and `Int(infinity)`
  /// traps. The reapply path defers on the same signal rather than acting on a
  /// partial layout.
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
        // Sorted so the value follows the topology, not the enumeration order:
        // two reads of an unchanged machine must compare equal.
        mirroredIDs: displays.filter { $0.mirrorsDisplay == display.id }.map(\.id).sorted()
      )
    })
  }

  /// Display space is integral (AR1) and `CGDisplayBounds` is measured integral in
  /// POINTS, not pixels, so the rounding converts rather than quantises. `nil` for
  /// anything that is not a finite rect, which is what an unknown display ID reports.
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
