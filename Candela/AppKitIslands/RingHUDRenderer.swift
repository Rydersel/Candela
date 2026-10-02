import AppKit
import CandelaKit

/// A circular gauge: track, arc from twelve o'clock, sixteen interval dots,
/// the glyph in the middle. Drawn, not composed: an arc is not a box.
@MainActor
final class RingHUDRenderer: HUDRenderer {
  let style: HUDStyle = .ring
  let contentView: NSView
  private let dial: DialView
  private let glyph: NSImageView

  init() {
    let (root, effect) = makePillChrome(size: RingDial.size, cornerRadius: RingDial.cornerRadius)
    let dial = DialView(frame: effect.bounds)
    effect.addSubview(dial)
    let glyph = NSImageView(frame: RingDial.glyphRect)
    glyph.imageScaling = .scaleProportionallyDown
    glyph.contentTintColor = .labelColor
    effect.addSubview(glyph)
    self.contentView = root
    self.dial = dial
    self.glyph = glyph
  }

  func frame(on screen: NSScreen, position: HUDPosition) -> CGRect {
    let origin = HUDPlacement.origin(
      style.anchor(for: position), size: RingDial.size, frame: screen.frame, visibleFrame: screen.visibleFrame,
      topInset: screen.menuBarAllowance + PillHUDRenderer.menuBarClearance, margin: PillHUDRenderer.screenMargin)
    return CGRect(origin: origin, size: RingDial.size)
  }

  func show(_ content: HUDContent, reduceMotion: Bool) {
    dial.value = Double(content.value)
    dial.needsDisplay = true
    let config = NSImage.SymbolConfiguration(pointSize: RingDial.glyphPointSize, weight: .semibold)
    glyph.image = NSImage(systemSymbolName: content.kind.rightSymbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  func hide(reduceMotion: Bool) -> HUDDismissal {
    .fade(Motion.windowFadeOut(reduceMotion: reduceMotion))
  }

  private final class DialView: NSView {
    var value: Double = 0

    override func draw(_ dirtyRect: NSRect) {
      let track = NSBezierPath()
      track.appendArc(withCenter: RingDial.center, radius: RingDial.radius, startAngle: 0, endAngle: 360)
      track.lineWidth = RingDial.lineWidth
      NSColor.quaternaryLabelColor.setStroke()
      track.stroke()
      if value > 0 {
        let arc = NSBezierPath()
        arc.lineCapStyle = .round
        arc.lineWidth = RingDial.lineWidth
        // Kit angles are y-up degrees, which is the frame appendArc reads here.
        arc.appendArc(withCenter: RingDial.center, radius: RingDial.radius,
                      startAngle: RingDial.startDegrees, endAngle: RingDial.sweepEndDegrees(value: value), clockwise: true)
        NSColor.labelColor.setStroke()
        arc.stroke()
      }
      NSColor.tertiaryLabelColor.setFill()
      for index in 0 ..< RingDial.dotCount {
        let c = RingDial.dotCenter(index)
        let d = RingDial.dotDiameter
        NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
      }
    }
  }
}
