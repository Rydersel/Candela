//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from Support/CustomHUD.swift.

import AppKit
import CandelaKit

/// The on-screen display Candela presents when it changes a display's brightness.
///
/// Implemented as an AppKit island (spec: no AppKit in CandelaKit) behind
/// `BrightnessHUDPresenting`, so the engine can announce a value change without
/// knowing anything about windows.
protocol BrightnessHUDPresenting: AnyObject {
  @MainActor func showBrightness(displayID: CGDirectDisplayID, name: String, value: Double,
                                 nameSuffix: String?, position: HUDPosition, style: HUDStyle)
  /// Volume, contrast and mute. Through the protocol so the executor talks to a
  /// presenter, not the concrete panel.
  @MainActor func showHUD(displayID: CGDirectDisplayID, type: HUDType, name: String,
                          value: Float, maxValue: Float, nameSuffix: String?,
                          position: HUDPosition, style: HUDStyle)
}

enum HUDType {
  case brightness
  case volume
  case volumeMuted
  case contrast

  var leftSymbolName: String {
    switch self {
    case .brightness: return "sun.min.fill"
    case .volume: return "speaker.fill"
    case .volumeMuted: return "speaker.slash.fill"
    case .contrast: return "circle.lefthalf.filled"
    }
  }

  var rightSymbolName: String {
    switch self {
    case .brightness: return "sun.max.fill"
    case .volume: return "speaker.wave.3.fill"
    case .volumeMuted: return "speaker.slash.fill"
    case .contrast: return "circle.lefthalf.filled"
    }
  }
}

/// Custom on-screen display styled after the native Tahoe HUD pill.
///
/// We draw our own rather than calling the system OSD because the system HUD repaints from
/// *system* brightness state, which never changes for a DDC-controlled display: on macOS 26 the
/// ControlCenter-based OSD ignores the value of repeat showImage calls while its HUD is visible,
/// so the pill would freeze mid-interaction.
///
/// Style and position both arrive from the caller, which reads them
/// from prefs at announce time; the island holds no judgement.
@MainActor
final class BrightnessHUD: BrightnessHUDPresenting {
  private struct Window {
    let panel: NSPanel
    let renderer: any HUDRenderer
  }

  /// ONE window per display, shared by every pill kind: a show reuses the
  /// window the last one left, retitles it and re-places it. With per-kind
  /// positions that reuse is visible as a move when a second press lands inside
  /// the fade. Keying by kind as well as by display would make simultaneous
  /// pills possible, which is a product change nobody has ruled on.
  ///
  /// A window built for one STYLE is torn down and rebuilt when a show arrives
  /// with another: the anatomies differ structurally, so
  /// reconfiguring in place would leave orphaned subviews.
  private var windows: [CGDirectDisplayID: Window] = [:]
  private var fadeTimers: [CGDirectDisplayID: Timer] = [:]
  /// Monotonic per display, bumped by every `showHUD` and by `cleanupDisplay`.
  /// A fade's completion handler compares the generation it captured against
  /// the current one and stays out of the way if a newer show has happened.
  private var fadeGenerations: [CGDirectDisplayID: UInt64] = [:]

  // MARK: - BrightnessHUDPresenting

  func showBrightness(displayID: CGDirectDisplayID, name: String, value: Double,
                      nameSuffix: String?, position: HUDPosition, style: HUDStyle) {
    showHUD(displayID: displayID, type: .brightness, name: name, value: Float(value),
            nameSuffix: nameSuffix, position: position, style: style)
  }

  // MARK: - Presentation

  /// `displayID` must ALREADY be a drawable display, resolved through the mirror
  /// topology by the caller. A mirror slave is absent from
  /// `NSScreen.screens`, so an unresolved ID lands in the guard below and shows
  /// nothing at all, silently, while the write still reaches the panel.
  ///
  /// The renderer's menu-bar allowance therefore measures the MASTER's menu bar
  /// for a mirror set, which is correct: the set's menu bar is the master's. Not
  /// a thing to "fix" back.
  ///
  /// The name is not resolved here either, and that costs the CALLER: the
  /// windows are keyed by `displayID`, so every member of a mirror set addresses
  /// ONE window and calling this once per member leaves the last call's name and
  /// value on screen. `HUDGrouping` makes that choice once rather than by
  /// iteration order.
  func showHUD(displayID: CGDirectDisplayID, type: HUDType, name: String, value: Float,
               maxValue: Float = 1, nameSuffix: String? = nil,
               position: HUDPosition, style: HUDStyle) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
    let window: Window
    if let existing = windows[displayID], existing.renderer.style == style {
      window = existing
    } else {
      // A window built for one style closes rather than reconfigures: the
      // renderers' view trees have nothing in common.
      windows[displayID]?.panel.close()
      window = Self.makeWindow(style: style)
      windows[displayID] = window
    }
    let title = (name.isEmpty ? screen.localizedName : name) + (nameSuffix ?? "")
    let normalized = CGFloat(min(max(maxValue > 0 ? value / maxValue : 0, 0), 1))
    let reduceMotion = Motion.systemReduceMotion
    // Frame before show: the island's trace is laid out against its panel.
    window.panel.setFrame(window.renderer.frame(on: screen, position: position), display: false)
    window.renderer.show(HUDContent(kind: type, value: normalized, title: title), reduceMotion: reduceMotion)
    fadeTimers[displayID]?.invalidate()
    fadeGenerations[displayID, default: 0] &+= 1
    // A bare `alphaValue = 1` loses to an in-flight fade: NSWindow's animator
    // keeps driving alpha toward 0 and would then order the panel out mid-show.
    // A zero-duration group replaces that animation and lands on 1 immediately.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.panel.animator().alphaValue = 1
    }
    window.panel.orderFrontRegardless()
    // `@Sendable`-typed but provably on the main run loop (added to `RunLoop.main`
    // below), so hopping actors would only add latency to the fade.
    let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss(displayID: displayID) }
    }
    fadeTimers[displayID] = timer
    // `.common` matters: the fade has to fire while a menu tracking session is running, otherwise
    // the pill stays on screen for as long as the menu-bar panel is open.
    RunLoop.main.add(timer, forMode: .common)
  }

  private static func makeWindow(style: HUDStyle) -> Window {
    let renderer: any HUDRenderer = switch style {
    case .system, .segments, .compact: PillHUDRenderer(style: style)
    case .classic, .classicCentered, .sequoia: BoxHUDRenderer(style: style)
    case .vertical: VerticalHUDRenderer()
    case .ring: RingHUDRenderer()
    default: PillHUDRenderer(style: .system)  // replaced by the renderer tasks that follow
    }
    let size = renderer.contentView.frame.size
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The native pill keeps a soft shadow; the heaviness came from the dark
    // border plus the dark material, not from this. The system's classic box
    // drew no shadow, and the Island is the notch itself, so neither gets one.
    panel.hasShadow = !style.isIsland && style != .classic && style != .classicCentered
    panel.isMovable = false
    panel.ignoresMouseEvents = true
    // Do not drop this line: without it the panel has no content view and the
    // HUD is invisible.
    panel.contentView = renderer.contentView
    return Window(panel: panel, renderer: renderer)
  }

  private func dismiss(displayID: CGDirectDisplayID) {
    guard let window = windows[displayID] else { return }
    let generation = fadeGenerations[displayID] ?? 0
    let panel = window.panel
    let orderOut: @MainActor () -> Void = { [weak self] in
      // A show that arrived mid-exit already bumped the generation; ordering
      // out here would hide a visible indicator.
      guard let self, self.fadeGenerations[displayID] == generation else { return }
      panel.orderOut(nil)
    }
    switch window.renderer.hide(reduceMotion: Motion.systemReduceMotion) {
    case .fade(let duration):
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        panel.animator().alphaValue = 0
      } completionHandler: {
        // `@Sendable`-typed but fires on the main thread, where the panel it
        // orders out already lives.
        MainActor.assumeIsolated { orderOut() }
      }
    case .selfAnimated(let duration):
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) { orderOut() }
    }
  }

  func cleanupDisplay(_ displayID: CGDirectDisplayID) {
    fadeTimers[displayID]?.invalidate()
    fadeTimers.removeValue(forKey: displayID)
    // Kept (not removed) so generations never repeat for a display that comes
    // back, which would let a stale completion match a fresh show.
    fadeGenerations[displayID, default: 0] &+= 1
    if let window = windows[displayID] {
      window.panel.close()
      windows.removeValue(forKey: displayID)
    }
  }
}

/// Internal, not fileprivate: every AppKit island that places a window on a
/// particular display uses it, and a second copy is a second thing to get wrong.
extension NSScreen {
  var displayID: CGDirectDisplayID? {
    self.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }

  /// The menu bar's height, or the status bar thickness standing in for it
  /// while the bar is auto-hidden.
  var menuBarAllowance: CGFloat {
    Self.menuBarAllowance(
      frameMaxY: frame.maxY, visibleMaxY: visibleFrame.maxY,
      barThickness: NSStatusBar.system.thickness)
  }

  /// Auto-hiding collapses the frame/visibleFrame difference (often to 0), so the
  /// thickness stands in for the bar once it reveals.
  static func menuBarAllowance(
    frameMaxY: CGFloat, visibleMaxY: CGFloat, barThickness: CGFloat
  ) -> CGFloat {
    max(frameMaxY - visibleMaxY, barThickness)
  }
}
