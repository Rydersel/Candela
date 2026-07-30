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
  /// alpha 0 = no dimming, 1 = black. Synchronous — called inline on the drag path.
  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID)
  func removeShade(for displayID: CGDirectDisplayID)
  func removeAllShades()
  /// Re-pin window frames to their displays' current screen frames (reconfigure).
  func repinFrames()
}

/// Applies software dimming by scaling a display's gamma transfer table.
@MainActor public protocol GammaApplying: AnyObject {
  /// Uniform scale of the display's captured default table. False = CG call failed.
  @discardableResult func applyGammaScale(_ scale: Double, on displayID: CGDirectDisplayID) -> Bool
  /// True while the last-written table (peak ratio) is still installed within 0.02.
  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool
  /// Re-capture the default table (call after reconfiguration).
  func recaptureDefaultTable(on displayID: CGDirectDisplayID)
  func resetAllGamma() // CGDisplayRestoreColorSyncSettings()
}

/// Presents the user-facing choice the dimming engine cannot make on its own —
/// currently only "another app is fighting us over the gamma table; switch this
/// display to the shade instead?".
@MainActor public protocol EngineAlerting: AnyObject {
  func offerShadeFallback(displayName: String, onAccept: @escaping @MainActor () -> Void)
}
