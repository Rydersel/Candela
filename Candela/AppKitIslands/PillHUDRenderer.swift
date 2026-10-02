import AppKit
import CandelaKit

/// The three pill styles: system, segments, compact. The anatomy the app
/// shipped with, now behind the renderer seam.
@MainActor
final class PillHUDRenderer: HUDRenderer {
  let style: HUDStyle
  let contentView: NSView
  /// nil where the style draws no name (`.compact`).
  private let nameLabel: NSTextField?
  private let leftIcon: NSImageView
  private let rightIcon: NSImageView
  /// The continuous bar's fill; nil for `.segments`.
  private let fillBox: NSBox?
  /// The track's interval dots (continuous-bar styles only). Held so a show
  /// can hide the ones the fill has passed: `labelColor` is translucent in
  /// dark appearance, so a covered dot would ghost through.
  private let tickBoxes: [NSBox]
  /// The chiclets; empty for the continuous-bar styles.
  private let segmentBoxes: [NSBox]
  private let metrics: Metrics

  /// Per-style geometry. The Menu Bar preview's miniature implements
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
      case .compact:
        self.size = NSSize(width: 220, height: 36)
        self.cornerRadius = 18
        self.margin = 14
        self.barY = 16
        self.hasName = false
      default:  // `.system` and `.segments`; only the three pill styles reach this renderer.
        self.size = NSSize(width: 314, height: 62)
        self.cornerRadius = 22
        self.margin = 18
        self.barY = 19
        self.hasName = true
      }
    }
  }

  // Fidelity knobs, one line each so a side-by-side pass against the
  // native pill can tune them without archaeology.
  /// `.popover` blends lighter and brighter than `.hudWindow` in both
  /// appearances; the sheen below pushes it the rest of the way.
  fileprivate static let material: NSVisualEffectView.Material = .popover
  /// White wash over the material, the "bright glass" half of the fix.
  fileprivate static let sheenAlpha: CGFloat = 0.07
  /// The native edge reads as a LIGHT inner hairline in both appearances, so
  /// this is constant white rather than a semantic color: `separatorColor`
  /// resolved near-black and drew a visible outline. Static, so no per-show
  /// appearance refresh.
  fileprivate static let hairlineColor = NSColor.white.withAlphaComponent(0.25)
  fileprivate static let hairlineWidth: CGFloat = 0.75
  /// Matches the native name label.
  private static let nameFontSize: CGFloat = 13
  /// Interval dots at the sixteenths, covered by the fill exactly as the native
  /// track shows them.
  private static let tickCount = 15
  private static let tickDiameter: CGFloat = 2

  private static let segmentCount = 16
  private static let segmentGap: CGFloat = 2
  private static let segmentHeight: CGFloat = 8
  private static let segmentCornerRadius: CGFloat = 2

  /// Shared with the vertical and ring renderers, which place by the same pickers.
  static let screenMargin: CGFloat = 20
  /// Extra clearance on top of the menu-bar allowance so the pill sits clearly
  /// below the bar rather than hugging it. Eyeballed against the native OSD.
  static let menuBarClearance: CGFloat = 10

  init(style: HUDStyle) {
    let metrics = Metrics(style: style)
    let size = metrics.size

    let (rootView, effectView) = makePillChrome(size: size, cornerRadius: metrics.cornerRadius)

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
    var tickBoxes: [NSBox] = []
    var segmentBoxes: [NSBox] = []
    if style == .segments {
      // Pinned geometry: chiclets across the system bar rect, centered
      // on the bar's line.
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
    } else {
      let barBackground = NSBox(frame: NSRect(x: metrics.barX, y: metrics.barY, width: metrics.barWidth, height: Metrics.barHeight))
      barBackground.boxType = .custom
      // DIVERGENCE from the fork's `borderType = .noBorder`, which is deprecated
      // and applies only to the old-style box. `borderWidth = 0` is the
      // custom-box equivalent; Apple's suggested `transparent` would also
      // suppress the fill, the only thing drawn here.
      barBackground.borderWidth = 0
      barBackground.fillColor = .quaternaryLabelColor
      barBackground.cornerRadius = Metrics.barHeight / 2
      effectView.addSubview(barBackground)

      // Interval dots at the sixteenths. Added BEFORE the fill so the
      // filled side covers its dots, as the native track reads.
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
        tickBoxes.append(tick)
      }

      let fill = NSBox(frame: NSRect(x: metrics.barX, y: metrics.barY, width: Metrics.barHeight, height: Metrics.barHeight))
      fill.boxType = .custom
      fill.borderWidth = 0
      fill.fillColor = .labelColor
      fill.cornerRadius = Metrics.barHeight / 2
      effectView.addSubview(fill)
      fillBox = fill
    }

    self.style = style
    self.contentView = rootView
    self.nameLabel = nameLabel
    self.leftIcon = leftIcon
    self.rightIcon = rightIcon
    self.fillBox = fillBox
    self.tickBoxes = tickBoxes
    self.segmentBoxes = segmentBoxes
    self.metrics = metrics
  }

  func frame(on screen: NSScreen, position: HUDPosition) -> CGRect {
    // The arithmetic lives in the Kit, where a rotated display's bounds can be
    // tested. `screen.frame` is already the EFFECTIVE geometry, so a
    // display mounted at 270° needs nothing special here.
    let origin = HUDPlacement.origin(
      .position(position), size: metrics.size, frame: screen.frame, visibleFrame: screen.visibleFrame,
      topInset: screen.menuBarAllowance + Self.menuBarClearance, margin: Self.screenMargin)
    return CGRect(origin: origin, size: metrics.size)
  }

  func show(_ content: HUDContent, reduceMotion: Bool) {
    nameLabel?.stringValue = content.title
    leftIcon.image = Self.symbolImage(content.kind.leftSymbolName, pointSize: Metrics.leftIconSize - 3)
    rightIcon.image = Self.symbolImage(content.kind.rightSymbolName, pointSize: Metrics.rightIconSize - 3)
    if let fillBox {
      var fillFrame = fillBox.frame
      fillFrame.size.width = max(Metrics.barHeight, metrics.barWidth * content.value)
      fillBox.frame = fillFrame
      // Being UNDER the fill is not enough: `labelColor` is translucent in dark
      // appearance, so a covered dot ghosts through. Hide what the fill passed.
      for tick in tickBoxes {
        tick.isHidden = tick.frame.midX <= fillFrame.maxX
      }
    }
    if !segmentBoxes.isEmpty {
      // Filled count rounds, so a half step lights the nearer chiclet.
      let filled = Int((content.value * CGFloat(Self.segmentCount)).rounded())
      for (index, box) in segmentBoxes.enumerated() {
        box.fillColor = index < filled ? .labelColor : .quaternaryLabelColor
      }
    }
  }

  func hide(reduceMotion: Bool) -> HUDDismissal {
    .fade(Motion.windowFadeOut(reduceMotion: reduceMotion))
  }

  private static func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  }
}

/// The pills' shared glass: popover material, light hairline, white sheen.
/// Reads the fidelity knobs on `PillHUDRenderer`, so they stay in one place.
@MainActor
func makePillChrome(size: NSSize, cornerRadius: CGFloat) -> (root: NSView, effect: NSVisualEffectView) {
  let root = NSView(frame: NSRect(origin: .zero, size: size))
  root.wantsLayer = true
  root.layer?.backgroundColor = NSColor.clear.cgColor
  let effect = NSVisualEffectView(frame: root.bounds)
  effect.material = PillHUDRenderer.material
  effect.blendingMode = .behindWindow
  effect.state = .active
  // DIVERGENCE from the fork, which forces `.vibrantDark`: the native pill
  // adapts to the system appearance and so does this one, with dynamic
  // semantic colors. The hairline is a constant white glass highlight, so
  // nothing here needs an appearance refresh at show time.
  effect.wantsLayer = true
  effect.layer?.cornerRadius = cornerRadius
  effect.layer?.masksToBounds = true
  effect.layer?.borderWidth = PillHUDRenderer.hairlineWidth
  effect.layer?.borderColor = PillHUDRenderer.hairlineColor.cgColor
  root.addSubview(effect)
  // First subview, so every control draws above it.
  let sheen = NSView(frame: root.bounds)
  sheen.wantsLayer = true
  sheen.layer?.backgroundColor = NSColor.white.withAlphaComponent(PillHUDRenderer.sheenAlpha).cgColor
  effect.addSubview(sheen)
  return (root, effect)
}
