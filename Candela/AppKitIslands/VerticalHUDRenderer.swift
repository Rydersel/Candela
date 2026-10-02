import AppKit
import CandelaKit

/// A tall capsule that fills from the bottom; the glyph sits in the foot.
@MainActor
final class VerticalHUDRenderer: HUDRenderer {
  let style: HUDStyle = .vertical
  let contentView: NSView
  private let fill: NSBox
  private let glyph: NSImageView

  init() {
    let (root, effect) = makePillChrome(size: VerticalPill.size, cornerRadius: VerticalPill.cornerRadius)
    let fill = NSBox(frame: NSRect(x: 0, y: 0, width: VerticalPill.size.width, height: 0))
    fill.boxType = .custom
    fill.borderWidth = 0
    fill.fillColor = NSColor.labelColor.withAlphaComponent(0.9)
    effect.addSubview(fill)
    let glyph = NSImageView(frame: VerticalPill.glyphRect)
    glyph.imageScaling = .scaleProportionallyDown
    glyph.contentTintColor = .secondaryLabelColor
    effect.addSubview(glyph)
    self.contentView = root
    self.fill = fill
    self.glyph = glyph
  }

  func frame(on screen: NSScreen, position: HUDPosition) -> CGRect {
    let origin = HUDPlacement.origin(
      .position(position), size: VerticalPill.size, frame: screen.frame, visibleFrame: screen.visibleFrame,
      topInset: screen.menuBarAllowance + PillHUDRenderer.menuBarClearance, margin: PillHUDRenderer.screenMargin)
    return CGRect(origin: origin, size: VerticalPill.size)
  }

  func show(_ content: HUDContent, reduceMotion: Bool) {
    fill.frame = NSRect(x: 0, y: 0, width: VerticalPill.size.width,
                        height: VerticalPill.fillHeight(value: Double(content.value)))
    let config = NSImage.SymbolConfiguration(pointSize: VerticalPill.glyphPointSize, weight: .semibold)
    glyph.image = NSImage(systemSymbolName: content.kind.rightSymbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  func hide(reduceMotion: Bool) -> HUDDismissal {
    .fade(Motion.windowFadeOut(reduceMotion: reduceMotion))
  }
}
