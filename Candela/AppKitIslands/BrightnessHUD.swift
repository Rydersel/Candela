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
  /// Generic pill (M4): volume/contrast/mute. Exposed through the protocol so
  /// the executor talks to a presenter, not the concrete panel.
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
/// Three looks (KMR-A3), chosen by the caller like the position: `.system` is
/// the native-matching default (KMR-A4), `.segments` swaps the bar for the
/// classic 16-chiclet strip, `.compact` is a smaller name-less pill. The
/// island keeps holding no judgement: style and position both arrive from the
/// caller, which reads them from prefs at announce time.
@MainActor
final class BrightnessHUD: BrightnessHUDPresenting {
  private struct HUD {
    let panel: NSPanel
    let effectView: NSVisualEffectView
    /// nil where the style draws no name (`.compact`).
    let nameLabel: NSTextField?
    let leftIcon: NSImageView
    let rightIcon: NSImageView
    /// The continuous bar's fill; nil for `.segments`.
    let fillBox: NSBox?
    /// The 16 chiclets; empty for the continuous-bar styles.
    let segmentBoxes: [NSBox]
    let style: HUDStyle
  }

  /// Per-style geometry (KMR-A3). The Menu Bar preview's miniature implements
  /// the same numbers from the spec, so a change here must travel there.
  private struct Metrics {
    let size: NSSize
    let cornerRadius: CGFloat
    let margin: CGFloat
    let barY: CGFloat
    let hasName: Bool

    static let leftIconSize: CGFloat = 14
    static let rightIconSize: CGFloat = 17
    static let barHeight: CGFloat = 4

    var barX: CGFloat { self.margin + Self.leftIconSize + 9 }
    var barWidth: CGFloat {
      self.size.width - self.barX - Self.rightIconSize - self.margin - 9
    }

    init(style: HUDStyle) {
      switch style {
      case .system, .segments:
        self.size = NSSize(width: 314, height: 62)
        self.cornerRadius = 22
        self.margin = 18
        self.barY = 19
        self.hasName = true
      case .compact:
        self.size = NSSize(width: 220, height: 36)
        self.cornerRadius = 18
        self.margin = 14
        self.barY = 16
        self.hasName = false
      }
    }
  }

  // KMR-A4 fidelity knobs, one line each so the side-by-side pass can tune
  // them without archaeology. The deltas they close, from Ryder's reference
  // screenshots against the native pill: ours read darker (material), wore a
  // near-black outline (separatorColor resolved over dark content), and
  // missed the track's interval dots and the larger name.
  /// `.popover` blends lighter and brighter than `.hudWindow` in both
  /// appearances; the sheen below pushes it the rest of the way.
  private static let material: NSVisualEffectView.Material = .popover
  /// White wash over the material, the "bright glass" half of the fix.
  private static let sheenAlpha: CGFloat = 0.07
  /// The native edge reads as a LIGHT inner hairline in both appearances (a
  /// glass highlight), so this is constant white, not a semantic color: the
  /// old `separatorColor` CGColor resolved near-black and drew the outline
  /// Ryder flagged. Static, so the per-show appearance refresh went with it.
  private static let hairlineColor = NSColor.white.withAlphaComponent(0.25)
  private static let hairlineWidth: CGFloat = 0.75
  /// The native pill keeps a soft shadow; the heaviness Ryder saw was the
  /// dark border plus the dark material. Flip this if the pass still reads
  /// heavy after those two.
  private static let panelHasShadow = true
  /// Native name label: one point larger than ours was.
  private static let nameFontSize: CGFloat = 13
  /// Interval dots on the track at the sixteenths, covered by the fill on the
  /// filled side exactly as the native track shows them.
  private static let tickCount = 15
  private static let tickDiameter: CGFloat = 2

  private static let segmentCount = 16
  private static let segmentGap: CGFloat = 2
  private static let segmentHeight: CGFloat = 8
  private static let segmentCornerRadius: CGFloat = 2

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

  /// ONE window per display, shared by every pill kind. Brightness, volume,
  /// contrast and mute cannot be on screen together on one display, and never
  /// could be: a show reuses the window the last one left, retitles it and
  /// re-places it. With per-kind positions that reuse is visible as a move,
  /// because a volume press followed by a brightness press inside the 1.5 s
  /// fade takes the same window from one anchor to the other. Keying by kind as
  /// well as by display would make simultaneous pills possible, which is a
  /// product change nobody has ruled on, not a bug fix.
  ///
  /// A window built for one STYLE is torn down and rebuilt when a show arrives
  /// with another (KMR-A3): the anatomies differ structurally, so
  /// reconfiguring in place would leave orphaned subviews.
  private var huds: [CGDirectDisplayID: HUD] = [:]
  private var fadeTimers: [CGDirectDisplayID: Timer] = [:]
  /// Monotonic per display, bumped by every `showHUD` and by `cleanupDisplay`.
  /// A fade's completion handler compares the generation it captured against
  /// the current one and stays out of the way if a newer show has happened.
  private var fadeGenerations: [CGDirectDisplayID: UInt64] = [:]

  // MARK: - BrightnessHUDPresenting

  func showBrightness(displayID: CGDirectDisplayID, name: String, value: Double,
                      nameSuffix: String?, position: HUDPosition, style: HUDStyle) {
    self.showHUD(displayID: displayID, type: .brightness, name: name, value: Float(value),
                 nameSuffix: nameSuffix, position: position, style: style)
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
  func showHUD(displayID: CGDirectDisplayID, type: HUDType, name: String, value: Float,
               maxValue: Float = 1, nameSuffix: String? = nil,
               position: HUDPosition, style: HUDStyle) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      return
    }
    let hud: HUD
    if let existing = self.huds[displayID], existing.style == style {
      hud = existing
    } else {
      // Style changed (or first show): the old window's subview tree belongs
      // to the old anatomy, so it closes rather than reconfigures.
      self.huds[displayID]?.panel.close()
      hud = self.createHUD(style: style)
      self.huds[displayID] = hud
    }
    let metrics = Metrics(style: style)
    let title = name.isEmpty ? screen.localizedName : name
    hud.nameLabel?.stringValue = title + (nameSuffix ?? "")
    hud.leftIcon.image = Self.symbolImage(type.leftSymbolName, pointSize: Metrics.leftIconSize - 3)
    hud.rightIcon.image = Self.symbolImage(type.rightSymbolName, pointSize: Metrics.rightIconSize - 3)
    let normalized = CGFloat(min(max(maxValue > 0 ? value / maxValue : 0, 0), 1))
    if let fillBox = hud.fillBox {
      var fillFrame = fillBox.frame
      fillFrame.size.width = max(Metrics.barHeight, metrics.barWidth * normalized)
      fillBox.frame = fillFrame
    }
    if !hud.segmentBoxes.isEmpty {
      // KMR-A3: filled count rounds, so a half step lights the nearer chiclet.
      let filled = Int((normalized * CGFloat(Self.segmentCount)).rounded())
      for (index, box) in hud.segmentBoxes.enumerated() {
        box.fillColor = index < filled ? .labelColor : .quaternaryLabelColor
      }
    }
    // The anchor arrives from the caller and the arithmetic lives in the Kit,
    // where a rotated display's bounds can be tested (DT16: the island holds no
    // judgement). `screen.frame` is already the EFFECTIVE geometry, so a
    // display mounted at 270° needs nothing special here.
    hud.panel.setFrameOrigin(HUDPlacement.origin(
      position,
      size: metrics.size,
      frame: screen.frame,
      visibleFrame: screen.visibleFrame,
      topInset: Self.menuBarAllowance(for: screen),
      margin: Self.screenMargin
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

  private func createHUD(style: HUDStyle) -> HUD {
    let metrics = Metrics(style: style)
    let size = metrics.size
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = Self.panelHasShadow
    panel.isMovable = false
    panel.ignoresMouseEvents = true

    let rootView = NSView(frame: NSRect(origin: .zero, size: size))
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor.clear.cgColor

    let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effectView.material = Self.material
    effectView.blendingMode = .behindWindow
    effectView.state = .active
    // The fork forces `.vibrantDark`; the native pill adapts to the system
    // appearance, and so do we (Ryder, 2026-07-30): dynamic semantic colors
    // everywhere. KMR-A4 moved the material off `.hudWindow` (too dark next to
    // the native pill) and the border off `separatorColor` (resolved
    // near-black, the "outline" in Ryder's screenshot); the hairline is now a
    // constant white glass highlight, so nothing here needs an appearance
    // refresh at show time any more.
    effectView.wantsLayer = true
    effectView.layer?.cornerRadius = metrics.cornerRadius
    effectView.layer?.masksToBounds = true
    effectView.layer?.borderWidth = Self.hairlineWidth
    effectView.layer?.borderColor = Self.hairlineColor.cgColor
    rootView.addSubview(effectView)

    // The bright-glass sheen (KMR-A4): first subview, so every control draws
    // above it. Constant white; the alpha is the whole design.
    let sheen = NSView(frame: NSRect(origin: .zero, size: size))
    sheen.wantsLayer = true
    sheen.layer?.backgroundColor = NSColor.white.withAlphaComponent(Self.sheenAlpha).cgColor
    effectView.addSubview(sheen)

    var nameLabel: NSTextField?
    if metrics.hasName {
      let label = NSTextField(labelWithString: "")
      label.frame = NSRect(x: metrics.margin, y: size.height - 28, width: size.width - metrics.margin * 2, height: 18)
      label.font = NSFont.systemFont(ofSize: Self.nameFontSize, weight: .semibold)
      label.textColor = .labelColor
      label.lineBreakMode = .byTruncatingTail
      effectView.addSubview(label)
      nameLabel = label
    }

    let leftIcon = NSImageView(frame: NSRect(x: metrics.margin, y: metrics.barY - (Metrics.leftIconSize - Metrics.barHeight) / 2, width: Metrics.leftIconSize, height: Metrics.leftIconSize))
    leftIcon.imageScaling = .scaleProportionallyDown
    leftIcon.contentTintColor = .secondaryLabelColor
    effectView.addSubview(leftIcon)

    let rightIcon = NSImageView(frame: NSRect(x: size.width - metrics.margin - Metrics.rightIconSize, y: metrics.barY - (Metrics.rightIconSize - Metrics.barHeight) / 2, width: Metrics.rightIconSize, height: Metrics.rightIconSize))
    rightIcon.imageScaling = .scaleProportionallyDown
    rightIcon.contentTintColor = .secondaryLabelColor
    effectView.addSubview(rightIcon)

    var fillBox: NSBox?
    var segmentBoxes: [NSBox] = []
    switch style {
    case .system, .compact:
      let barBackground = NSBox(frame: NSRect(x: metrics.barX, y: metrics.barY, width: metrics.barWidth, height: Metrics.barHeight))
      barBackground.boxType = .custom
      // The fork says `borderType = .noBorder`; that is deprecated and applies only to the old-style
      // box. `borderWidth = 0` is the custom-box equivalent (Apple's suggested `transparent` would
      // also suppress the fill, which is the only thing we draw here).
      barBackground.borderWidth = 0
      barBackground.fillColor = .quaternaryLabelColor
      barBackground.cornerRadius = Metrics.barHeight / 2
      effectView.addSubview(barBackground)

      // Interval dots at the sixteenths (KMR-A4). Added BEFORE the fill so the
      // filled side covers its dots, which is exactly how the native track
      // reads: dots visible on the unfilled remainder only.
      for index in 1 ... Self.tickCount {
        let centerX = metrics.barX + metrics.barWidth * CGFloat(index) / CGFloat(Self.tickCount + 1)
        let tick = NSBox(frame: NSRect(
          x: centerX - Self.tickDiameter / 2,
          y: metrics.barY + Metrics.barHeight / 2 - Self.tickDiameter / 2,
          width: Self.tickDiameter, height: Self.tickDiameter
        ))
        tick.boxType = .custom
        tick.borderWidth = 0
        tick.fillColor = .tertiaryLabelColor
        tick.cornerRadius = Self.tickDiameter / 2
        effectView.addSubview(tick)
      }

      let fill = NSBox(frame: NSRect(x: metrics.barX, y: metrics.barY, width: Metrics.barHeight, height: Metrics.barHeight))
      fill.boxType = .custom
      fill.borderWidth = 0
      fill.fillColor = .labelColor
      fill.cornerRadius = Metrics.barHeight / 2
      effectView.addSubview(fill)
      fillBox = fill

    case .segments:
      // KMR-A3 pinned geometry: 16 chiclets across the system bar rect,
      // 8 pt tall, radius 2, 2 pt gaps, centered on the bar's line.
      let segmentWidth = (metrics.barWidth - CGFloat(Self.segmentCount - 1) * Self.segmentGap) / CGFloat(Self.segmentCount)
      let segmentY = metrics.barY + Metrics.barHeight / 2 - Self.segmentHeight / 2
      for index in 0 ..< Self.segmentCount {
        let segment = NSBox(frame: NSRect(
          x: metrics.barX + CGFloat(index) * (segmentWidth + Self.segmentGap),
          y: segmentY, width: segmentWidth, height: Self.segmentHeight
        ))
        segment.boxType = .custom
        segment.borderWidth = 0
        segment.fillColor = .quaternaryLabelColor
        segment.cornerRadius = Self.segmentCornerRadius
        effectView.addSubview(segment)
        segmentBoxes.append(segment)
      }
    }

    // Do not drop this line: without it the panel has no content view and the HUD is invisible
    // (see docs/ENGINEERING-NOTES.md, "OSD / HUD").
    panel.contentView = rootView

    return HUD(panel: panel, effectView: effectView, nameLabel: nameLabel, leftIcon: leftIcon,
               rightIcon: rightIcon, fillBox: fillBox, segmentBoxes: segmentBoxes, style: style)
  }

  private func fadeOut(displayID: CGDirectDisplayID) {
    guard let panel = self.huds[displayID]?.panel else {
      return
    }
    let generation = self.fadeGenerations[displayID] ?? 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.windowFadeOut(reduceMotion: Motion.systemReduceMotion)
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
