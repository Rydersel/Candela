import CoreGraphics

/// Software-dimming boundaries. Both mechanisms need WindowServer objects
/// (`NSWindow`, `NSScreen`) or global CoreGraphics gamma state, so the engine
/// only ever sees these protocols — the implementations are AppKit islands in
/// the app target (spec: no AppKit in CandelaKit).
///
/// Two mechanisms, one job: darken a display below its hardware minimum.
/// - **Gamma** (`GammaApplying`) is the default path — it scales the display's
///   transfer table, so the panel's own backlight/pixel output is untouched but
///   every pixel the OS sends is darker. It is a global, single-owner resource:
///   f.lux, Night Shift and friends write the same table, which is why
///   `verifyTableIntact` exists.
/// - **Shade** (`ShadeRendering`) is the fallback — a black full-screen overlay
///   window whose alpha carries the dimming. Nothing can fight us over it, but
///   it composites over everything and cannot dim what it cannot cover.

/// Renders the software-dimming shade overlay for a display.
@MainActor public protocol ShadeRendering: AnyObject {
  /// alpha 0 = no dimming, 1 = black. Synchronous — called inline on the drag
  /// path.
  ///
  /// **Returns whether the shade actually took the alpha.** It returns `Bool`
  /// and not `Void` because of DT17: a display with no `NSScreen` — which is
  /// every mirror SLAVE — could not have a shade created for it, and the old
  /// void signature let that failure disappear while the engine recorded the
  /// dimming as applied. The engine reads this and refuses to memoise a write
  /// that did not land.
  ///
  /// `displayID` is expected to be ALREADY RESOLVED to a drawable display; the
  /// engine does that at its boundary (`MirrorTopology.drawableDisplayID`).
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
  /// TWO display IDs, and the difference is load-bearing (DT17):
  /// - `displayID` is the WRITE target. Gamma is a per-display property, and
  ///   which display should be dimmed is the engine's decision rather than this
  ///   call's. Ordinarily it is the raw panel ID; under an engaged synthesis
  ///   pairing the engine issues TWO legs (SS15), the panel here and the
  ///   drawable ID through `applyGammaScale(assumingLinearBaseline:on:
  ///   enforcerOn:)` below. Whether either write reaches the glass on a mirror
  ///   slave is not decidable from software, which is why both are issued and
  ///   why nothing here claims an outcome beyond "the call was accepted".
  /// - `drawableDisplayID` is where the 1x1 activity-enforcer window goes. Only
  ///   a drawable display has a compositor, and the enforcer's whole job is to
  ///   force a composite pass.
  @discardableResult
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID, enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool
  /// SS15's second leg: the same write, for a display whose own default table
  /// may not be readable at all.
  ///
  /// The process that created a virtual display cannot read it back, and SS15
  /// requires both IDs of an engaged synthesis set to receive the table, so a
  /// refused capture must not swallow the write. An implementation that holds
  /// baselines uses the straight 0…1 ramp when it has none. That the ramp is a
  /// virtual display's true untouched table is an ASSUMPTION and is unverified;
  /// the hardware pass's eyes item decides the final routing.
  ///
  /// The default forwards to `applyGammaScale`, so a backend that captures no
  /// baseline of its own behaves exactly as it did.
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

/// Presents the user-facing choice the dimming engine cannot make on its own —
/// currently only "another app is fighting us over the gamma table; switch this
/// display to the shade instead?".
@MainActor public protocol EngineAlerting: AnyObject {
  func offerShadeFallback(displayName: String, onAccept: @escaping @MainActor () -> Void)
}
