//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from Support/CustomHUD.swift.

import AppKit

/// The on-screen display Candela presents when it changes a display's brightness.
///
/// Implemented as an AppKit island (spec: no AppKit in CandelaKit) behind
/// `BrightnessHUDPresenting`, so the engine can announce a value change without
/// knowing anything about windows.
protocol BrightnessHUDPresenting: AnyObject {
  // Protocol requirements cannot carry default arguments, so the requirement
  // spells out the full list and the extension below supplies the short form.
  @MainActor func showBrightness(displayID: CGDirectDisplayID, name: String, value: Double, nameSuffix: String?)
  /// Generic pill (M4): volume/contrast/mute. Exposed through the protocol so
  /// the executor talks to a presenter, not the concrete panel.
  @MainActor func showHUD(displayID: CGDirectDisplayID, type: HUDType, name: String,
                          value: Float, maxValue: Float, nameSuffix: String?)
}

extension BrightnessHUDPresenting {
  @MainActor func showHUD(displayID: CGDirectDisplayID, type: HUDType, name: String, value: Float) {
    self.showHUD(displayID: displayID, type: type, name: name, value: value, maxValue: 1, nameSuffix: nil)
  }
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
@MainActor
final class BrightnessHUD: BrightnessHUDPresenting {
  private struct HUD {
    let panel: NSPanel
    let effectView: NSVisualEffectView
    let nameLabel: NSTextField
    let leftIcon: NSImageView
    let rightIcon: NSImageView
    let fillBox: NSBox
  }

  private static let hudSize = NSSize(width: 314, height: 62)
  private static let cornerRadius: CGFloat = 22
  private static let margin: CGFloat = 18
  private static let leftIconSize: CGFloat = 14
  private static let rightIconSize: CGFloat = 17
  private static let barHeight: CGFloat = 4
  private static let barY: CGFloat = 19
  private static let barX: CGFloat = BrightnessHUD.margin + BrightnessHUD.leftIconSize + 9
  private static let barWidth: CGFloat = BrightnessHUD.hudSize.width - BrightnessHUD.barX - BrightnessHUD.rightIconSize - BrightnessHUD.margin - 9
  private static let screenMargin: CGFloat = 20
  /// Extra clearance added on top of the menu-bar allowance so the pill sits
  /// clearly below the bar rather than hugging it. Ryder eyeballed this against
  /// the native macOS OSD pill.
  private static let menuBarClearance: CGFloat = 10

  /// Vertical space to keep free at the top of `screen`: the menu bar, plus
  /// clearance. While the bar is showing, the frame/visibleFrame difference
  /// measures it exactly and wins the `max`; while it is auto-hidden that
  /// difference collapses (often to 0), so we reserve the bar's own thickness
  /// instead — the space it will occupy the moment it reveals. The clearance
  /// applies either way, so it sits outside the `max`.
  private static func menuBarAllowance(for screen: NSScreen) -> CGFloat {
    max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness) + self.menuBarClearance
  }

  private var huds: [CGDirectDisplayID: HUD] = [:]
  private var fadeTimers: [CGDirectDisplayID: Timer] = [:]
  /// Monotonic per display, bumped by every `showHUD` and by `cleanupDisplay`.
  /// A fade's completion handler compares the generation it captured against
  /// the current one and stays out of the way if a newer show has happened.
  private var fadeGenerations: [CGDirectDisplayID: UInt64] = [:]

  // MARK: - BrightnessHUDPresenting

  func showBrightness(displayID: CGDirectDisplayID, name: String, value: Double, nameSuffix: String?) {
    self.showHUD(displayID: displayID, type: .brightness, name: name, value: Float(value), nameSuffix: nameSuffix)
  }

  // MARK: - Presentation

  /// `displayID` must ALREADY be a drawable display — resolved through the
  /// mirror topology by the caller (DT15/DT16). A mirror slave is absent from
  /// `NSScreen.screens`, so an unresolved ID lands in the guard below and shows
  /// nothing at all, silently, while the write still reaches the panel.
  ///
  /// The island keeps its one-line lookup and no judgement; the mirror
  /// awareness lives in the engine. `menuBarAllowance(for:)` therefore measures
  /// the MASTER's menu bar for a mirror set, which is correct — the set's menu
  /// bar is the master's — and is not a thing to "fix" back.
  ///
  /// The name is a separate question from the placement and is deliberately NOT
  /// resolved here either. Note what that costs the CALLER: because the windows
  /// are keyed by `displayID`, every member of a mirror set addresses ONE
  /// window, and calling this once per member leaves the last call's name and
  /// value on screen. `HUDGrouping` exists so that choice is made once and on
  /// purpose rather than by iteration order (#123).
  func showHUD(displayID: CGDirectDisplayID, type: HUDType, name: String, value: Float, maxValue: Float = 1, nameSuffix: String? = nil) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      return
    }
    let hud: HUD
    if let existing = self.huds[displayID] {
      hud = existing
    } else {
      hud = self.createHUD()
      self.huds[displayID] = hud
    }
    let title = name.isEmpty ? screen.localizedName : name
    hud.nameLabel.stringValue = title + (nameSuffix ?? "")
    hud.leftIcon.image = Self.symbolImage(type.leftSymbolName, pointSize: Self.leftIconSize - 3)
    hud.rightIcon.image = Self.symbolImage(type.rightSymbolName, pointSize: Self.rightIconSize - 3)
    let normalized = CGFloat(min(max(maxValue > 0 ? value / maxValue : 0, 0), 1))
    var fillFrame = hud.fillBox.frame
    fillFrame.size.width = max(Self.barHeight, Self.barWidth * normalized)
    hud.fillBox.frame = fillFrame
    // Layer colors don't track appearance changes; refresh the hairline border
    // against whatever the system looks like right now.
    hud.effectView.effectiveAppearance.performAsCurrentDrawingAppearance {
      hud.effectView.layer?.borderColor = NSColor.separatorColor.cgColor
    }
    // Vertical position is measured from the full frame, not `visibleFrame`:
    // with the menu bar auto-hidden `visibleFrame` reaches the top of the
    // screen, and the pill would then sit exactly where the bar reveals itself.
    // `menuBarAllowance` reserves that strip unconditionally.
    hud.panel.setFrameOrigin(NSPoint(
      x: screen.visibleFrame.maxX - Self.hudSize.width - Self.screenMargin,
      y: screen.frame.maxY - Self.menuBarAllowance(for: screen) - Self.hudSize.height - Self.screenMargin
    ))
    self.fadeTimers[displayID]?.invalidate()
    self.fadeGenerations[displayID, default: 0] &+= 1
    // A bare `alphaValue = 1` loses to an in-flight fade: NSWindow's animator
    // keeps driving alpha toward 0 and would then order the panel out mid-show.
    // A zero-duration group replaces that animation and lands on 1 immediately.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      hud.panel.animator().alphaValue = 1
    }
    hud.panel.orderFrontRegardless()
    // The timer body is `@Sendable`-typed but provably runs on the main run loop (we add it to
    // `RunLoop.main` below), so hopping actors would only add latency to the fade.
    let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.fadeOut(displayID: displayID)
      }
    }
    self.fadeTimers[displayID] = timer
    // `.common` matters: the fade has to fire while a menu tracking session is running, otherwise
    // the pill stays on screen for as long as the menu-bar panel is open.
    RunLoop.main.add(timer, forMode: .common)
  }

  private static func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  }

  private func createHUD() -> HUD {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.hudSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.ignoresMouseEvents = true

    let size = Self.hudSize
    let rootView = NSView(frame: NSRect(origin: .zero, size: size))
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor.clear.cgColor

    let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effectView.material = .hudWindow
    effectView.blendingMode = .behindWindow
    effectView.state = .active
    // The fork forces `.vibrantDark`; the native pill adapts to the system
    // appearance, and so do we (Ryder, 2026-07-30): dynamic semantic colors
    // everywhere, and `.hudWindow` supplies the light/dark material itself.
    // The one non-dynamic spot is the layer border — CGColor resolves at set
    // time, so `showHUD` refreshes it against the current appearance.
    effectView.wantsLayer = true
    effectView.layer?.cornerRadius = Self.cornerRadius
    effectView.layer?.masksToBounds = true
    effectView.layer?.borderWidth = 0.5
    rootView.addSubview(effectView)

    let nameLabel = NSTextField(labelWithString: "")
    nameLabel.frame = NSRect(x: Self.margin, y: size.height - 26, width: size.width - Self.margin * 2, height: 16)
    nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    nameLabel.textColor = .labelColor
    nameLabel.lineBreakMode = .byTruncatingTail
    effectView.addSubview(nameLabel)

    let leftIcon = NSImageView(frame: NSRect(x: Self.margin, y: Self.barY - (Self.leftIconSize - Self.barHeight) / 2, width: Self.leftIconSize, height: Self.leftIconSize))
    leftIcon.imageScaling = .scaleProportionallyDown
    leftIcon.contentTintColor = .secondaryLabelColor
    effectView.addSubview(leftIcon)

    let rightIcon = NSImageView(frame: NSRect(x: size.width - Self.margin - Self.rightIconSize, y: Self.barY - (Self.rightIconSize - Self.barHeight) / 2, width: Self.rightIconSize, height: Self.rightIconSize))
    rightIcon.imageScaling = .scaleProportionallyDown
    rightIcon.contentTintColor = .secondaryLabelColor
    effectView.addSubview(rightIcon)

    let barBackground = NSBox(frame: NSRect(x: Self.barX, y: Self.barY, width: Self.barWidth, height: Self.barHeight))
    barBackground.boxType = .custom
    // The fork says `borderType = .noBorder`; that is deprecated and applies only to the old-style
    // box. `borderWidth = 0` is the custom-box equivalent (Apple's suggested `transparent` would
    // also suppress the fill, which is the only thing we draw here).
    barBackground.borderWidth = 0
    barBackground.fillColor = .quaternaryLabelColor
    barBackground.cornerRadius = Self.barHeight / 2
    effectView.addSubview(barBackground)

    let fillBox = NSBox(frame: NSRect(x: Self.barX, y: Self.barY, width: Self.barHeight, height: Self.barHeight))
    fillBox.boxType = .custom
    fillBox.borderWidth = 0
    fillBox.fillColor = .labelColor
    fillBox.cornerRadius = Self.barHeight / 2
    effectView.addSubview(fillBox)

    // Do not drop this line: without it the panel has no content view and the HUD is invisible
    // (see docs/ENGINEERING-NOTES.md, "OSD / HUD").
    panel.contentView = rootView

    return HUD(panel: panel, effectView: effectView, nameLabel: nameLabel, leftIcon: leftIcon, rightIcon: rightIcon, fillBox: fillBox)
  }

  private func fadeOut(displayID: CGDirectDisplayID) {
    guard let panel = self.huds[displayID]?.panel else {
      return
    }
    let generation = self.fadeGenerations[displayID] ?? 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      // The completion handler is `@Sendable`-typed but fires on the main thread, where the panel
      // it orders out already lives.
      MainActor.assumeIsolated {
        // A show that arrived mid-fade already restored alpha and bumped the
        // generation; ordering out here would hide a visible HUD.
        guard let self, self.fadeGenerations[displayID] == generation else {
          return
        }
        panel.orderOut(nil)
      }
    }
  }

  func cleanupDisplay(_ displayID: CGDirectDisplayID) {
    self.fadeTimers[displayID]?.invalidate()
    self.fadeTimers.removeValue(forKey: displayID)
    // Kept (not removed) so generations never repeat for a display that comes
    // back, which would let a stale completion match a fresh show.
    self.fadeGenerations[displayID, default: 0] &+= 1
    if let hud = self.huds[displayID] {
      hud.panel.close()
      self.huds.removeValue(forKey: displayID)
    }
  }
}

/// Internal, not fileprivate: used by every AppKit island that places a window
/// on a particular display, and a second copy is a second thing to get wrong.
extension NSScreen {
  var displayID: CGDirectDisplayID? {
    self.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
