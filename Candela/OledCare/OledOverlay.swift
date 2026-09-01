import AppKit
import CandelaKit
import os

/// OLED care's own overlay windows: one black, full-screen window per enrolled
/// display, whose content-view alpha carries the care dim.
///
/// Window configuration is shared with `ShadeOverlay` through `OverlayWindow`;
/// the windows are not. The brightness engine clears its shades wholesale on
/// topology changes, so sharing instances would let either owner erase the
/// other's work.
///
/// The ID arriving here is the display care is enrolled on. OC13 suspends care
/// on a mirror participant before any of this is reached.
@MainActor
final class OledOverlay {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  private var windows: [CGDirectDisplayID: NSPanel] = [:]

  /// An overlay we closed, kept until the window server confirms it is gone.
  ///
  /// It holds the panel, not just the number: without it the removal half of
  /// `verifyPresence` is a tautology ("no window cached" answers "not present"
  /// for the exact strand OC12 exists to catch), and a detected strand needs a
  /// window to close again.
  ///
  /// The number is captured at close time, never read back later.
  /// `NSWindow.windowNumber` is documented to return `<= 0` for a window with
  /// no device and `CGWindowID(_:)` traps on a negative, so a read-back turns a
  /// documented return value into a crash. (Measured on macOS 26 the number
  /// does survive `close()`; the contract is what this relies on.)
  private struct ClosedOverlay {
    let panel: NSPanel
    let number: CGWindowID
    let closedAt: ContinuousClock.Instant
  }

  private var lastRemoved: [CGDirectDisplayID: ClosedOverlay] = [:]

  /// How long after `close()` the window server may still list the window before
  /// the reading counts as a strand. It keeps reporting a closing overlay for
  /// 200 to 250 ms on the MAG and 400 to 750 ms on the Dell [MEASURED 2026-08-28],
  /// long after the pixels are back; without the grace every healthy restore
  /// logged a strand. One second clears both and still catches a real strand.
  static let closeGrace: Duration = .seconds(1)

  /// What the window server says about a display's overlay right now.
  enum Presence: Equatable {
    case absent
    /// An overlay is on screen: a live one, or a closed one past `closeGrace`
    /// (a strand, already re-closed and logged).
    case present
    /// A closed overlay still listed inside `closeGrace`: check again rather
    /// than counting an attempt or logging.
    case closing
  }

  /// The state each display's overlay is carrying, so an unchanged `apply` is a
  /// no-op. Re-ordering unconditionally would be ~10 window-server round trips a
  /// second per display, each one re-stacking the overlay above whatever else
  /// sits at shielding level (the lock shield, the screen saver).
  private struct AppliedState: Equatable {
    let alpha: Double
    let blackout: Bool
    /// The spatial axis (OC17). Nil is the scalar behaviour: one uniform alpha
    /// over the whole content view.
    ///
    /// `OverlayMask` quantizes to 1/255 on construction, which is what keeps
    /// this struct's `==` meaningful. Without it a mask derived from live
    /// luminance would differ in the twelfth decimal every tick and miss the
    /// memo every time.
    let mask: OverlayMask.Oriented?
  }

  private var lastApplied: [CGDirectDisplayID: AppliedState] = [:]

  /// Displays already warned about for a missing `NSScreen`. The overlay is
  /// re-driven on every state tick, so an unrated warning floods the log for as
  /// long as the display stays gone.
  private var warnedMissingScreen: Set<CGDirectDisplayID> = []

  /// `alpha` nil removes the overlay; otherwise it is clamped to 0...1 and
  /// applied to the content view. The window itself stays opaque with a clear
  /// background: an alpha-faded *window* composites differently and reads
  /// washed out, per `OverlayWindow`.
  ///
  /// Returns false when no `NSScreen` matches the display, so no overlay exists
  /// to carry the dim. Not a `Void` call, per DT17: a caller that cannot tell
  /// will memoise a dimming that never happened. **Removal always returns
  /// true**; `verifyPresence` reports a removal the window server ignored.
  ///
  /// The overlay is ordered front on creation and on a state change, never on
  /// an unchanged re-apply. Re-asserting a state the window already carries is
  /// `reassert(on:)`, the OC12 reconcile's lever, and keeping the two apart is
  /// what keeps the steady-state cadence off the window server.
  ///
  /// `mask` is already in DISPLAY orientation; nil keeps the scalar behaviour.
  @discardableResult
  func apply(
    alpha: Double?, mask: OverlayMask.Oriented? = nil, blackout: Bool,
    on displayID: CGDirectDisplayID
  ) -> Bool {
    guard let alpha else {
      self.remove(for: displayID)
      return true
    }
    let existed = self.windows[displayID] != nil
    guard let window = self.window(for: displayID) else {
      if self.warnedMissingScreen.insert(displayID).inserted {
        Self.log.warning("No screen matches display \(displayID, privacy: .public); OLED care overlay not applied")
      }
      return false
    }
    // A uniform mask is NOT normalized away here. It looks like no mask, but the
    // caller sets `alpha = 1.0` BECAUSE a mask is present and carries the
    // absolute per-cell opacity; dropping it leaves alpha 1.0 over an empty
    // layer and paints the panel opaque black. `alpha`'s meaning DEPENDS on
    // whether a mask came with it, so collapsing a uniform mask back to a scalar
    // is the caller's job (`OledCareCoordinator.render`).
    //
    // `clampedAlpha` and not a bare clamp: a NaN alpha makes `AppliedState`
    // compare unequal to ITSELF, so the change-only-write guard below would miss
    // every time and `apply` would write to the window server on every tick.
    // Unreachable from the current callers; guarded anyway because a per-tick
    // write looks exactly like a working overlay.
    let state = AppliedState(
      alpha: OverlayWindow.clampedAlpha(alpha), blackout: blackout, mask: mask)
    guard !existed || self.lastApplied[displayID] != state else {
      return true
    }
    self.lastApplied[displayID] = state
    self.write(state, to: window)
    return true
  }

  /// Re-asserts the overlay's last applied state: the recovery lever for an
  /// OC12 mismatch, where the window server dropped a window we still hold (a
  /// space transition, another shielding window, a reconfiguration). `apply`
  /// will not do it, since the state it is asked for is the state it has.
  ///
  /// A no-op when the display has no overlay: creating one here would invent a
  /// dim level this class does not own.
  func reassert(on displayID: CGDirectDisplayID) {
    guard let window = self.windows[displayID], let state = self.lastApplied[displayID] else {
      return
    }
    self.write(state, to: window)
  }

  private func write(_ state: AppliedState, to window: NSPanel) {
    // OC15: blackout swallows mouse input (at full black a click-through click
    // is a blind click on live UI); every other level stays click-through.
    window.ignoresMouseEvents = !state.blackout
    // Mask first, then the alpha it decides: the two are ONE decision, and
    // writing the alpha ahead of the mask is what leaves a failed mask at 1.0
    // over a flat black layer.
    let masked = Self.writeMask(state.mask, to: window)
    let alpha = masked ? state.alpha : Self.fallbackAlpha(forUnrendered: state.mask)
    window.contentView?.alphaValue = CGFloat(alpha)
    window.orderFrontRegardless()
  }

  /// The alpha for a mask that was asked for and did not reach the layer.
  ///
  /// The caller's alpha is unusable here: it is 1.0 by the render funnel's
  /// convention BECAUSE the mask carries the absolute per-cell opacity, so
  /// writing it over the flat black fallback paints the whole panel opaque.
  /// The mask's peak is the darkest cell it asked for, so this errs dark
  /// without ever going darker than the mask itself would have. A mask with no
  /// cells asked for nothing and gets nothing: an invisible overlay beats a
  /// black screen.
  static func fallbackAlpha(forUnrendered mask: OverlayMask.Oriented?) -> Double {
    mask?.cells.max() ?? 0
  }

  /// Renders the spatial axis as the layer's contents.
  ///
  /// The mask becomes a tiny grayscale image and the layer magnifies it with a
  /// LINEAR filter, which is what satisfies OC17's "smoothly interpolated
  /// gradient, never per-cell blocks". At 3440x1440 a cell is ~143 px, so drawn
  /// rectangles would give the visible tile pattern the feature exists to
  /// remove; letting the GPU interpolate produces the falloff for free.
  ///
  /// Nil CLEARS the contents: a display that had a mask and no longer does must
  /// go back to a uniform dim, not keep a stale gradient nothing updates.
  ///
  /// Returns false ONLY when a mask was asked for and did not reach the layer,
  /// which is the one case where the caller's alpha is not the alpha to write.
  private static func writeMask(_ mask: OverlayMask.Oriented?, to window: NSPanel) -> Bool {
    guard let layer = window.contentView?.layer else { return mask == nil }
    guard let mask else {
      layer.contents = nil
      layer.backgroundColor = .black
      return true
    }
    guard let image = maskImage(mask) else {
      // Flat black here, and `write` pairs it with the mask's darkest cell:
      // a failed image costs the spatial detail, not the dim the user asked
      // for, and never the whole panel.
      layer.contents = nil
      layer.backgroundColor = .black
      return false
    }
    // The image carries the black AND its per-cell alpha, so the flat
    // background must go: it would floor every cell at full black.
    layer.backgroundColor = NSColor.clear.cgColor
    layer.magnificationFilter = .linear
    layer.minificationFilter = .linear
    layer.contentsGravity = .resize
    layer.contents = image
    return true
  }

  /// Black pixels whose ALPHA is the mask. Premultiplied, because the mask is
  /// the alpha channel and the colour is a constant zero.
  private static func maskImage(_ mask: OverlayMask.Oriented) -> CGImage? {
    let (cells, cols, rows) = (mask.cells, mask.cols, mask.rows)
    guard cols > 0, rows > 0, cells.count == cols * rows else { return nil }

    var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
    for index in cells.indices {
      let alpha = UInt8(clamping: Int((cells[index] * 255).rounded()))
      // BGRA premultiplied: colour channels are alpha * 0 = 0, so only the
      // alpha byte carries anything.
      pixels[index * 4 + 3] = alpha
    }

    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
      .union(.byteOrder32Little)
    // Context AND `makeImage` inside the buffer's lifetime: `&pixels` as a call
    // argument is a pointer valid only for that call, so a context that outlives
    // the initializer is reading storage it no longer owns. Same shape as
    // `LuminanceReduction.meanLuminance`.
    return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: cols, height: rows, bitsPerComponent: 8,
          bytesPerRow: cols * 4, space: space, bitmapInfo: info.rawValue)
      else { return nil }
      return context.makeImage()
    }
  }

  func remove(for displayID: CGDirectDisplayID) {
    guard let window = self.windows.removeValue(forKey: displayID) else {
      return
    }
    self.lastApplied.removeValue(forKey: displayID)
    // Retained for the stranded-overlay check and its recovery; cleared once
    // the server confirms the window is gone, or when a new overlay supersedes
    // it. A window that never reached the screen has no number to watch (0 is
    // `kCGNullWindowID`) and nothing to strand.
    if window.windowNumber > 0 {
      self.lastRemoved[displayID] = ClosedOverlay(
        panel: window, number: CGWindowID(window.windowNumber), closedAt: .now)
    }
    // Safe for the same reason `ShadeOverlay.removeShade` is: the window is
    // borderless and `isReleasedWhenClosed` is false, so ARC owns the lifetime.
    window.close()
    Self.log.info("OLED care overlay removed for display \(displayID, privacy: .public)")
  }

  func removeAll() {
    for displayID in Array(self.windows.keys) {
      self.remove(for: displayID)
    }
  }

  /// Deliberately uncalled (W3a ruling): the reconfiguration response is
  /// removeAll + re-render, never a repin. Display IDs REASSIGN across a dock
  /// cycle with every panel still present, so a repin can pin an overlay to the
  /// WRONG panel. Kept for a future geometry-only path (mode/rotation changes).
  func repinFrames() {
    for (displayID, window) in self.windows {
      guard let screen = OverlayWindow.screen(for: displayID) else {
        // Display gone, or not back yet. Leave the window alone rather than
        // guessing a frame; the coordinator decides whether it survives at all.
        continue
      }
      window.setFrame(screen.frame, display: true)
    }
  }

  /// OC12: presence answered by the window server, never by our own `NSWindow`
  /// state, which only restates the request we issued. True means an overlay for
  /// this display is on screen *now*, whether or not we still want one. Both
  /// halves of the ruling (an add that did not land, a removal that did not
  /// take) come from this one call.
  ///
  /// No TCC grant needed: only `kCGWindowName` is gated by Screen Recording.
  func verifyPresence(on displayID: CGDirectDisplayID) -> Presence {
    if let window = self.windows[displayID] {
      // Same reason `remove(for:)` screens the number: `windowNumber` is <= 0
      // for a window with no device and `CGWindowID(_:)` TRAPS on a negative.
      guard window.windowNumber > 0 else { return .absent }
      return Self.isOnScreen(CGWindowID(window.windowNumber)) ? .present : .absent
    }
    guard let closed = self.lastRemoved[displayID] else {
      return .absent
    }
    guard Self.isOnScreen(closed.number) else {
      self.lastRemoved.removeValue(forKey: displayID)
      return .absent
    }
    // A second close on a still-closing window is what produced the false
    // strands; inside the grace, wait.
    if ContinuousClock.now - closed.closedAt < Self.closeGrace {
      return .closing
    }
    // Detecting a strand is half of it: this window is black over the user's
    // screen and nothing else can close it. Ask again; the entry stays until a
    // later check sees it gone, so a failing close keeps being retried.
    Self.log.error("OLED care overlay still on screen after close on display \(displayID, privacy: .public); closing again")
    closed.panel.orderOut(nil)
    closed.panel.close()
    // The retry is a close too, with the same report lag; without a fresh grace
    // a real strand logged three times per retry. With it, once per grace.
    self.lastRemoved[displayID] = ClosedOverlay(panel: closed.panel, number: closed.number, closedAt: .now)
    return .present
  }

  private static func isOnScreen(_ number: CGWindowID) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]],
          let info = list.first
    else {
      return false
    }
    // Window numbers are recycled. Without the owner check, a number reissued
    // to another process would read as a strand of ours no close can clear.
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() else {
      return false
    }
    // The key is present only while the window is on screen; an entry can
    // outlive that, which is why membership alone is not the answer.
    return info[kCGWindowIsOnscreen as String] as? Bool ?? false
  }

  /// Returns the display's overlay, creating it on first use. Nil only when no
  /// `NSScreen` currently matches the display (offline/unmatched).
  private func window(for displayID: CGDirectDisplayID) -> NSPanel? {
    if let existing = self.windows[displayID] {
      return existing
    }
    guard let screen = OverlayWindow.screen(for: displayID) else {
      return nil
    }
    // An `NSPanel` with `.nonactivatingPanel`, not a plain `NSWindow`: the
    // blackout overlay accepts clicks (OC15), and a click-accepting window in an
    // accessory app would otherwise activate Candela and take key away from
    // whatever the user was in.
    let panel = NSPanel(contentRect: OverlayWindow.seedRect,
                        styleMask: OverlayWindow.styleMask.union(.nonactivatingPanel),
                        backing: .buffered,
                        defer: false)
    // Nothing here takes input, so it should never become key. Mouse events
    // still reach the window under the cursor regardless of key state.
    panel.becomesKeyOnlyIfNeeded = true
    // Already the default for a non-floating panel; stated because
    // `isFloatingPanel` flips it, and an overlay that vanished on deactivation
    // would be invisible exactly when it is meant to be dimming.
    panel.hidesOnDeactivate = false
    // Ordering front is `write`'s job here, not creation's: the overlay reaches
    // the screen when it first carries a state.
    OverlayWindow.configure(
      panel, title: "Candela OLED Care Overlay for Display \(displayID)",
      covering: screen.frame)
    self.windows[displayID] = panel
    // A live overlay supersedes the closed one this display may still be watched
    // for: `verifyPresence` answers from the live window from here on. Give the
    // old one a last close (a no-op if it really did go).
    if let closed = self.lastRemoved.removeValue(forKey: displayID) {
      closed.panel.orderOut(nil)
      closed.panel.close()
    }
    self.warnedMissingScreen.remove(displayID)
    Self.log.info("OLED care overlay created for display \(displayID, privacy: .public)")
    return panel
  }
}
