import CoreGraphics

/// Software-dimming boundaries. Both mechanisms need WindowServer objects
/// (`NSWindow`, `NSScreen`) or global CoreGraphics gamma state, so the engine
/// only sees these protocols; the implementations are AppKit islands in the app
/// target (spec: no AppKit in CandelaKit).
///
/// Two mechanisms, one job: darken a display below its hardware minimum.
/// - **Gamma** (`GammaApplying`), the default, scales the display's transfer
///   table, so the panel's own output is untouched and every pixel the OS sends
///   is darker. It is a global, single-owner resource: f.lux and Night Shift
///   write the same table, which is why `verifyTableIntact` exists.
/// - **Shade** (`ShadeRendering`), the fallback, is a black full-screen overlay
///   window whose alpha carries the dimming. Nothing can fight us over it, but
///   it cannot dim what it cannot cover.

/// Renders the software-dimming shade overlay for a display.
@MainActor public protocol ShadeRendering: AnyObject {
  /// alpha 0 = no dimming, 1 = black. Synchronous, called inline on the drag
  /// path.
  ///
  /// Returns whether the shade actually took the alpha. A display with no
  /// `NSScreen`, which is every mirror SLAVE, gets no shade, and a `Void`
  /// signature let that failure disappear while the engine recorded the dimming
  /// as applied. The engine refuses to memoise a write that did not land.
  ///
  /// `displayID` must be ALREADY RESOLVED to a drawable display; the engine does
  /// that at its boundary (`MirrorTopology.drawableDisplayID`).
  @discardableResult
  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) -> Bool
  func removeShade(for displayID: CGDirectDisplayID)
  func removeAllShades()
  /// Re-pin window frames to their displays' current screen frames (reconfigure).
  func repinFrames()
}

/// Applies software dimming by scaling a display's gamma transfer table.
@MainActor public protocol GammaApplying: AnyObject {
  /// Uniform scale of the display's captured default table. False = the write
  /// did not happen or the CG call failed.
  ///
  /// TWO display IDs, and the difference is load-bearing:
  /// - `displayID` is the WRITE target, ordinarily the raw panel ID; under an
  ///   engaged synthesis pairing the engine issues TWO legs, the panel
  ///   here and the drawable ID through `applyGammaScale(assumingLinearBaseline:
  ///   on:enforcerOn:)` below. MEASURED: a mirror slave's table STORES and reads
  ///   back changed, and whether it reaches the GLASS is undecidable from
  ///   software, because scanout comes from the master's framebuffer. That is
  ///   why both legs are issued and why nothing here claims an outcome beyond
  ///   "the call was accepted".
  /// - `drawableDisplayID` is where the 1x1 activity-enforcer window goes. Only
  ///   a drawable display has a compositor, and the enforcer's whole job is to
  ///   force a composite pass.
  @discardableResult
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID, enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool
  /// The second synthesis-pairing leg: the same write, for a display whose own
  /// default table may not be readable at all.
  ///
  /// The process that created a virtual display cannot read it back, and
  /// delivering the table to both IDs of an engaged synthesis set needs this
  /// second leg, so a refused capture must not swallow the write. An
  /// implementation that holds baselines uses the straight 0…1 ramp when it
  /// has none; that the ramp is a
  /// virtual display's true untouched table is an UNVERIFIED assumption.
  ///
  /// The default forwards to `applyGammaScale`, which is also the trap. A future
  /// conformance that DOES hold baselines and skips this gets the forwarding
  /// default, the leg that refuses a display it never captured, so the companion
  /// write is issued and never made. A protocol default is a satisfied
  /// requirement, so nothing warns. Implement it, or say in the conformance why
  /// forwarding is right for it.
  @discardableResult
  func applyGammaScale(
    assumingLinearBaseline scale: Double, on displayID: CGDirectDisplayID,
    enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool
  /// True while the last-written table (peak ratio) is still installed within 0.02.
  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool
  /// Re-capture the default table (call after reconfiguration).
  func recaptureDefaultTable(on displayID: CGDirectDisplayID)
  func resetAllGamma() // CGDisplayRestoreColorSyncSettings()
}

public extension GammaApplying {
  @discardableResult
  func applyGammaScale(
    assumingLinearBaseline scale: Double, on displayID: CGDirectDisplayID,
    enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    applyGammaScale(scale, on: displayID, enforcerOn: drawableDisplayID)
  }
}

/// Presents the user-facing choice the dimming engine cannot make on its own.
/// Currently only "another app is fighting us over the gamma table; switch this
/// display to the shade instead?".
@MainActor public protocol EngineAlerting: AnyObject {
  func offerShadeFallback(displayName: String, onAccept: @escaping @MainActor () -> Void)
}
