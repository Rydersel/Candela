import AppKit
import CandelaKit

/// Classic, Classic (centered) and Sequoia: a box with a glyph over a bar.
/// Classic's colours are the vibrant semantic ones the system box composites
/// with; plain whites were measured and do not match.
@MainActor
final class BoxHUDRenderer: HUDRenderer {
  let style: HUDStyle
  let contentView: NSView
  private let effectView: NSVisualEffectView
  private let glyph: NSImageView
  private let chiclets: [NSBox]
  private let fill: NSBox?

  private static let chicletColor = NSColor.secondaryLabelColor
  private static let classicTrackColor = NSColor.black.withAlphaComponent(0.36)

  init(style: HUDStyle) {
    self.style = style
    let isClassic = style != .sequoia
    let size = isClassic ? ClassicBox.size : SequoiaBox.size
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    let effect = NSVisualEffectView(frame: root.bounds)
    effect.material = isClassic ? .hudWindow : .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = isClassic ? ClassicBox.cornerRadius : SequoiaBox.cornerRadius
    effect.layer?.masksToBounds = true
    if !isClassic {
      // Sequoia shares the pills' glass: hairline and sheen.
      effect.layer?.borderWidth = 0.75
      effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
      let sheen = NSView(frame: root.bounds)
      sheen.wantsLayer = true
      sheen.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
      effect.addSubview(sheen)
    }
    root.addSubview(effect)

    let glyph = NSImageView(frame: isClassic ? ClassicBox.glyphRect : SequoiaBox.glyphRect)
    glyph.imageScaling = .scaleProportionallyUpOrDown
    glyph.contentTintColor = isClassic ? Self.chicletColor : .labelColor
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
    self.effectView = effect
    self.glyph = glyph
    self.chiclets = chiclets
    self.fill = fill
  }

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
      style.fixedAnchor ?? .position(position), size: size, frame: screen.frame,
      visibleFrame: screen.visibleFrame, topInset: screen.menuBarAllowance, margin: 20)
    return CGRect(origin: origin, size: size)
  }

  func show(_ content: HUDContent, reduceMotion: Bool) {
    if style == .sequoia {
      let config = NSImage.SymbolConfiguration(pointSize: SequoiaBox.glyphPointSize, weight: .medium)
      glyph.image = NSImage(systemSymbolName: Self.filledSymbol(content.kind), accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
      fill?.frame = SequoiaBox.fillRect(value: Double(content.value))
    } else {
      glyph.image = ClassicGlyphs.image(for: content.kind)
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
