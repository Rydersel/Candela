import AppKit
import CandelaKit

/// Classic, Classic (centered) and Sequoia: a box with a glyph over a bar.
/// Classic's glyph composites through the material's vibrancy, while its
/// chiclets are flat boxes in `secondaryLabelColor`; that pairing measured
/// within 2% of the system box, where plain whites did not.
@MainActor
final class BoxHUDRenderer: HUDRenderer {
  let style: HUDStyle
  let contentView: NSView
  private let glyph: NSImageView
  private let chiclets: [NSBox]
  private let fill: NSBox?

  private static let chicletColor = NSColor.secondaryLabelColor
  private static let classicTrackColor = NSColor.black.withAlphaComponent(0.36)

  init(style: HUDStyle) {
    self.style = style
    let isClassic = style != .sequoia
    let root: NSView
    let effect: NSVisualEffectView
    if isClassic {
      root = NSView(frame: NSRect(origin: .zero, size: ClassicBox.size))
      root.wantsLayer = true
      effect = NSVisualEffectView(frame: root.bounds)
      effect.material = .hudWindow
      effect.blendingMode = .behindWindow
      effect.state = .active
      effect.wantsLayer = true
      effect.layer?.cornerRadius = ClassicBox.cornerRadius
      effect.layer?.masksToBounds = true
      root.addSubview(effect)
    } else {
      (root, effect) = makePillChrome(size: SequoiaBox.size, cornerRadius: SequoiaBox.cornerRadius)
    }

    let glyph: NSImageView
    if isClassic {
      glyph = NSImageView(frame: ClassicBox.glyphRect)
      glyph.imageScaling = .scaleProportionallyUpOrDown
      glyph.imageAlignment = .alignCenter
      glyph.contentTintColor = Self.chicletColor
    } else {
      // Natural size, centred on the glyph rect's centre: scaling into the rect
      // would shrink the wide speaker symbols and change size between kinds.
      // The frame spans the box so no symbol at 34 pt is clipped.
      let midY = SequoiaBox.glyphRect.midY
      let halfHeight = SequoiaBox.size.height - midY
      glyph = NSImageView(frame: NSRect(x: 0, y: midY - halfHeight, width: SequoiaBox.size.width, height: halfHeight * 2))
      glyph.imageScaling = .scaleNone
      glyph.imageAlignment = .alignCenter
      glyph.contentTintColor = .labelColor
    }
    effect.addSubview(glyph)

    var chiclets: [NSBox] = []
    var fill: NSBox?
    if isClassic {
      effect.addSubview(Self.box(ClassicBox.trackRect, Self.classicTrackColor))
      for index in 0 ..< ClassicBox.chicletCount {
        let chiclet = Self.box(ClassicBox.chicletRect(index), Self.chicletColor)
        effect.addSubview(chiclet)
        chiclets.append(chiclet)
      }
    } else {
      effect.addSubview(Self.box(SequoiaBox.barRect, .quaternaryLabelColor, radius: 1.5))
      let bar = Self.box(SequoiaBox.fillRect(value: 0), .labelColor, radius: 1.5)
      effect.addSubview(bar)
      fill = bar
    }
    self.contentView = root
    self.glyph = glyph
    self.chiclets = chiclets
    self.fill = fill
  }

  /// Centred where the PDF's drawing sits and spanning the box's width, so the
  /// widest symbol at natural size is never clipped.
  private static let classicFallbackFrame: NSRect = {
    let center = ClassicBox.fallbackGlyphCenter
    let halfHeight = ClassicBox.size.height - center.y
    return NSRect(x: 0, y: center.y - halfHeight, width: ClassicBox.size.width, height: halfHeight * 2)
  }()

  private static func box(_ frame: NSRect, _ color: NSColor, radius: CGFloat = 0) -> NSBox {
    let box = NSBox(frame: frame)
    box.boxType = .custom
    box.borderWidth = 0
    box.fillColor = color
    box.cornerRadius = radius
    return box
  }

  func frame(on screen: NSScreen, position: HUDPosition) -> CGRect {
    let size = contentView.frame.size
    let origin = HUDPlacement.origin(
      style.anchor(for: position), size: size, frame: screen.frame,
      visibleFrame: screen.visibleFrame, topInset: screen.menuBarAllowance, margin: 20)
    return CGRect(origin: origin, size: size)
  }

  func show(_ content: HUDContent, reduceMotion: Bool) {
    if style == .sequoia {
      let config = NSImage.SymbolConfiguration(pointSize: SequoiaBox.glyphPointSize, weight: .medium)
      glyph.image = NSImage(systemSymbolName: Self.filledSymbol(content.kind), accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
      fill?.frame = SequoiaBox.fillRect(value: Double(content.value))
      // The fill keeps a minimum width so a low value still reads; mute is an empty bar.
      fill?.isHidden = content.kind == .volumeMuted
    } else {
      let classic = ClassicGlyphs.glyph(for: content.kind)
      glyph.image = classic.image
      switch classic.source {
      case .systemPDF:
        glyph.frame = ClassicBox.glyphRect
        glyph.imageScaling = .scaleProportionallyUpOrDown
      case .symbol:
        glyph.frame = Self.classicFallbackFrame
        glyph.imageScaling = .scaleNone
      }
      let lit = IndicatorSteps.filled(Double(content.value), of: ClassicBox.chicletCount)
      for (index, chiclet) in chiclets.enumerated() { chiclet.isHidden = index >= lit }
    }
  }

  private static func filledSymbol(_ kind: HUDType) -> String {
    switch kind {
    case .brightness: "sun.max.fill"
    case .volume: "speaker.wave.3.fill"
    case .volumeMuted: "speaker.slash.fill"
    case .contrast: "circle.lefthalf.filled"
    }
  }

  func hide(reduceMotion: Bool) -> HUDDismissal {
    .fade(Motion.windowFadeOut(reduceMotion: reduceMotion))
  }
}
