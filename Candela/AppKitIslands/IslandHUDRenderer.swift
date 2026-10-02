import AppKit
import CandelaKit
import QuartzCore

/// The three Island styles. The notch is the island where the display has one;
/// where it does not, nothing pretends to be one: the drop grows straight down
/// from the top edge and the edge trace runs straight. The value is a luminous
/// trace and the information sits where there is screen; nothing is drawn on
/// the glass.
///
/// Core Animation rather than boxes: the shape springs, the trace draws itself
/// and breathes, and a shimmer slides along it. Every number was agreed by eye
/// on the rig; retune them on the rig, never by guesswork.
@MainActor
final class IslandHUDRenderer: HUDRenderer {
  let style: HUDStyle
  let contentView: NSView

  private let shape = CAShapeLayer()
  private let under = CAShapeLayer()
  private let track = CAShapeLayer()
  private let trace = CAShapeLayer()
  private let sheen = CAGradientLayer()
  private let sheenMask = CAShapeLayer()
  private let icon = CALayer()
  private let readout = CATextLayer()
  private let name = CATextLayer()
  private var capsules: [NSVisualEffectView] = []
  private var notch = IslandNotch(rect: .zero, isReal: false)
  private var panelFrame = CGRect.zero
  private var closed = CGRect.zero
  private var open = CGRect.zero
  private var laidOut: (frame: CGRect, notch: IslandNotch)?
  /// Zero until the first screen is known, so the first layout always applies it.
  private var backingScale: CGFloat = 0

  private static let widenDamping: CGFloat = 17
  private static let widenStiffness: CGFloat = 170
  private static let foldDamping: CGFloat = 24
  private static let foldStiffness: CGFloat = 190
  private static let brightnessTint = NSColor.white
  private static let volumeTint = NSColor(calibratedRed: 0.86, green: 0.93, blue: 1, alpha: 1)
  private static let volumeShimmer = NSColor(calibratedRed: 0.45, green: 0.72, blue: 1, alpha: 1)
  private static let underlayColor = NSColor.black.withAlphaComponent(0.55)
  private static let bareInset: CGFloat = 16
  private static let capsuleGap: CGFloat = 14
  private static let capsuleHeight: CGFloat = 26
  private static let capsulePad: CGFloat = 11
  private static let iconBox: CGFloat = 18
  /// Past this a long title truncates rather than growing over the menu bar.
  private static let maxNameWidth: CGFloat = 160

  private var isDrop: Bool { style == .islandDrop }
  private var hasCapsules: Bool { style == .islandEdgeCapsules }
  private var traceWidth: CGFloat { isDrop ? IslandGeometry.dropTraceWidth : IslandGeometry.edgeTraceWidth }
  private var iconPointSize: CGFloat { isDrop ? 15 : 13 }

  init(style: HUDStyle) {
    precondition(style.isIsland)
    self.style = style
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 98))
    root.wantsLayer = true
    root.layer = CALayer()
    self.contentView = root
    shape.fillColor = NSColor.black.cgColor
    for (layer, width, color) in [(under, traceWidth + 3, Self.underlayColor), (track, traceWidth, NSColor.white.withAlphaComponent(0.14))] {
      layer.fillColor = nil
      layer.strokeColor = color.cgColor
      layer.lineWidth = width
      layer.lineCap = .round
      layer.lineJoin = .round
      layer.opacity = 0
    }
    trace.fillColor = nil
    trace.lineWidth = traceWidth
    trace.lineCap = .round
    trace.lineJoin = .round
    trace.strokeEnd = 0
    trace.shadowOpacity = 0.85
    trace.shadowRadius = 4
    trace.shadowOffset = .zero
    trace.opacity = 0
    sheenMask.fillColor = nil
    sheenMask.strokeColor = NSColor.white.cgColor
    sheenMask.lineWidth = traceWidth + 1
    sheenMask.lineCap = .round
    sheenMask.lineJoin = .round
    sheenMask.strokeEnd = 0
    sheen.mask = sheenMask
    sheen.startPoint = CGPoint(x: 0, y: 0.5)
    sheen.endPoint = CGPoint(x: 1, y: 0.5)
    sheen.locations = [-0.3, -0.15, 0]
    sheen.opacity = 0
    icon.contentsGravity = .resizeAspect
    icon.opacity = 0
    readout.font = Self.roundedFont(14, .semibold)
    readout.fontSize = 14
    readout.opacity = 0
    name.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    name.fontSize = 11
    name.truncationMode = .end
    name.opacity = 0
    if isDrop { root.layer!.addSublayer(shape) }
    for layer in [under, track, trace, sheen] { root.layer!.addSublayer(layer) }
  }

  // MARK: - Layout

  func frame(on screen: NSScreen, position: HUDPosition) -> CGRect {
    let notch = IslandGeometry.notch(
      screen: screen.frame, visibleFrame: screen.visibleFrame, auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
      auxiliaryTopRight: screen.auxiliaryTopRightArea)
    // Hand-made layers rasterise at 1x unless told otherwise, which softens the strokes on Retina.
    if backingScale != screen.backingScaleFactor {
      backingScale = screen.backingScaleFactor
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in [shape, under, track, trace, sheen, sheenMask, icon, readout, name] as [CALayer] {
        layer.contentsScale = backingScale
      }
      CATransaction.commit()
    }
    layOut(notch: notch, screen: screen.frame)
    return panelFrame
  }

  /// Also the test seam: a notch and a screen without an `NSScreen`.
  func layOut(notch: IslandNotch, screen: CGRect) {
    let frame = IslandGeometry.panelFrame(screen: screen, notch: notch, fullWidth: !isDrop)
    if let laidOut, laidOut.frame == frame, laidOut.notch == notch { return }
    laidOut = (frame, notch)
    self.notch = notch
    panelFrame = frame
    // Frames and paths land in place; only the explicit animations move.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    contentView.frame = NSRect(origin: .zero, size: panelFrame.size)
    sheen.frame = contentView.bounds
    closed = IslandGeometry.closedTab(notch: notch, panel: panelFrame)
    open = isDrop ? IslandGeometry.openTab(notch: notch, panel: panelFrame) : closed
    // Over a real notch the closed tab is hidden by the glass; without one it
    // has no height. Either way it stays opaque and shows only as it opens.
    shape.path = Self.path(IslandGeometry.tabPath(closed))
    let outline: CGPath
    if isDrop {
      outline = Self.path(IslandGeometry.outline(around: open))
    } else {
      let top = panelFrame.height - traceWidth / 2 - 1
      outline = notch.isReal
        ? Self.path(IslandGeometry.edgeOutline(
            panelWidth: panelFrame.width, top: top,
            around: IslandGeometry.glassOutlineRect(
              closedGlass: IslandGeometry.glass(notch: notch, panel: panelFrame), lineWidth: traceWidth)))
        : Self.path(IslandGeometry.straightEdge(panelWidth: panelFrame.width, top: top))
    }
    for layer in [under, track, trace, sheenMask] { layer.path = outline }
    layOutContent()
  }

  private func layOutContent() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for layer in [icon, readout, name] { layer.removeFromSuperlayer() }
    capsules.forEach { $0.removeFromSuperview() }
    capsules = []
    let host = contentView.layer!
    if isDrop {
      let row = CGRect(x: open.minX, y: open.minY, width: open.width, height: IslandGeometry.drop)
      icon.frame = CGRect(x: row.minX + 16, y: row.midY - 11, width: 22, height: 22)
      readout.alignmentMode = .right
      readout.frame = CGRect(x: row.maxX - 16 - 52, y: row.midY - 8.7, width: 52, height: 18)
      name.alignmentMode = .center
      name.frame = CGRect(x: row.minX + 46, y: row.midY - 7, width: row.width - 46 - 74, height: 14)
      for layer in [icon, readout, name] { host.addSublayer(layer) }
      return
    }
    // Beside the flank: the name's measured width, an 8 pt gap, the icon box.
    let flank = IslandGeometry.flank(notch: notch, panel: panelFrame)
    let measured = ceil(NSAttributedString(string: name.string as? String ?? "", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).size().width) + 2
    let nameWidth = min(measured, Self.maxNameWidth)
    let readoutWidth = ceil(NSAttributedString(string: "Muted", attributes: [.font: Self.roundedFont(14, .semibold)]).size().width) + 2
    let h = Self.capsuleHeight, pad = Self.capsulePad
    let leftWidth = pad + nameWidth + 8 + Self.iconBox + pad
    let rightWidth = pad + readoutWidth + pad
    let leftRect = CGRect(x: flank.minX - Self.capsuleGap - leftWidth, y: flank.midY - h / 2, width: leftWidth, height: h)
    let rightRect = CGRect(x: flank.maxX + Self.capsuleGap, y: flank.midY - h / 2, width: rightWidth, height: h)
    let hostLeft: CALayer, hostRight: CALayer
    let lx: CGFloat, ly: CGFloat, rx: CGFloat, ry: CGFloat
    if hasCapsules {
      let left = Self.capsule(leftRect), right = Self.capsule(rightRect)
      // A retitle mid-show rebuilds them; they must not vanish under visible text.
      if trace.opacity > 0 { [left, right].forEach { $0.alphaValue = 1 } }
      contentView.addSubview(left)
      contentView.addSubview(right)
      capsules = [left, right]
      hostLeft = left.layer!; hostRight = right.layer!
      lx = 0; ly = h / 2; rx = 0; ry = h / 2
      for layer in [icon, readout, name] { layer.shadowOpacity = 0 }
    } else {
      hostLeft = host; hostRight = host
      // Bare against the desktop: 16 off the flank, a soft shadow for legibility.
      lx = flank.minX - Self.bareInset - Self.iconBox - 8 - nameWidth - pad
      ly = leftRect.midY
      rx = flank.maxX + Self.bareInset - pad
      ry = rightRect.midY
      for layer in [icon, readout, name] {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: -0.5)
      }
    }
    name.alignmentMode = .right
    name.frame = CGRect(x: lx + pad, y: ly - 7, width: nameWidth, height: 14)
    icon.frame = CGRect(x: lx + pad + nameWidth + 8, y: ly - Self.iconBox / 2, width: Self.iconBox, height: Self.iconBox)
    readout.alignmentMode = hasCapsules ? .center : .left
    readout.frame = CGRect(x: rx + pad, y: ry - 8.7, width: readoutWidth, height: 18)
    hostLeft.addSublayer(name)
    hostLeft.addSublayer(icon)
    hostRight.addSublayer(readout)
  }

  private static func capsule(_ frame: CGRect) -> NSVisualEffectView {
    let view = makePillChrome(size: frame.size, cornerRadius: frame.height / 2).effect
    view.removeFromSuperview()
    view.frame = frame
    view.alphaValue = 0
    return view
  }

  // MARK: - Show and hide

  private var currentValue: CGFloat = 0

  /// Readout, name and icon ink. The capsules' are dynamic, so they are
  /// resolved under the view's appearance at every show, never cached.
  private var textColors: (readout: NSColor, name: NSColor, icon: NSColor) {
    if isDrop { return (NSColor.white.withAlphaComponent(0.95), NSColor.white.withAlphaComponent(0.55), .white) }
    if hasCapsules { return (.labelColor, .secondaryLabelColor, .labelColor) }
    return (.white, NSColor.white.withAlphaComponent(0.7), .white)
  }

  func show(_ content: HUDContent, reduceMotion: Bool) {
    let muted = content.kind == .volumeMuted
    let wasShowing = trace.opacity > 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Content first: the side layout measures the name.
    if name.string as? String != content.title {
      name.string = content.title
      if !isDrop { layOutContent() }
    }
    let isVolume = content.kind == .volume || muted
    let tint = isVolume ? Self.volumeTint : Self.brightnessTint
    let band = isVolume ? Self.volumeShimmer : NSColor.white
    trace.strokeColor = tint.cgColor
    trace.shadowColor = tint.cgColor
    sheen.colors = [band.withAlphaComponent(0).cgColor, band.withAlphaComponent(0.95).cgColor, band.withAlphaComponent(0).cgColor]
    let colors = textColors
    contentView.effectiveAppearance.performAsCurrentDrawingAppearance {
      name.foregroundColor = colors.name.cgColor
      readout.foregroundColor = colors.readout.cgColor
      icon.contents = Self.symbolImage(content.kind.rightSymbolName, size: iconPointSize, color: colors.icon)
    }
    readout.string = muted ? "Muted" : "\(Int((content.value * 100).rounded()))%"
    // Mute empties the trace whatever value the caller passed.
    let value = muted ? 0 : content.value
    if wasShowing, !reduceMotion {
      for layer in [trace, sheenMask, under] {
        layer.add(Self.ease("strokeEnd", from: layer.presentation()?.strokeEnd ?? layer.strokeEnd, to: value, duration: 0.35), forKey: "value")
      }
    }
    for layer in [trace, sheenMask, under] { layer.strokeEnd = value }
    currentValue = value
    CATransaction.commit()
    guard !wasShowing else { return }
    reveal(reduceMotion: reduceMotion)
  }

  private func reveal(reduceMotion: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let openPath = Self.path(IslandGeometry.tabPath(open))
    if reduceMotion {
      shape.path = openPath
      for layer in [shape, icon, readout, name, under, track, trace, sheen] { layer.opacity = 1 }
      capsules.forEach { $0.alphaValue = 1 }
      CATransaction.commit()
      return
    }
    if isDrop {
      shape.add(Self.spring("path", from: shape.presentation()?.path ?? shape.path, to: openPath,
                            damping: Self.widenDamping, stiffness: Self.widenStiffness), forKey: "path")
      shape.path = openPath
      for layer in [icon, readout, name] { Self.fade(layer, to: 1, duration: 0.22, delay: 0.2) }
      // Only once the shape has landed, so the outline is never seen off the edge.
      for layer in [under, track, trace, sheen] { Self.fade(layer, to: 1, duration: 0.25, delay: 0.5) }
      for layer in [trace, sheenMask, under] {
        layer.add(Self.ease("strokeEnd", from: 0, to: currentValue, duration: 0.5, delay: 0.5), forKey: "value")
      }
    } else {
      for view in capsules { Self.fade(view, to: 1, duration: 0.3) }
      for layer in [icon, readout, name] { Self.fade(layer, to: 1, duration: 0.3, delay: 0.05) }
      for layer in [under, track, trace, sheen] { Self.fade(layer, to: 1, duration: 0.25) }
      for layer in [trace, sheenMask, under] {
        layer.add(Self.ease("strokeEnd", from: 0, to: currentValue, duration: 0.7, delay: 0.05), forKey: "value")
      }
    }
    let breathe = CABasicAnimation(keyPath: "shadowRadius")
    breathe.fromValue = 3
    breathe.toValue = 7
    breathe.duration = 1.4
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    trace.add(breathe, forKey: "breathe")
    let slide = CABasicAnimation(keyPath: "locations")
    slide.fromValue = [-0.3, -0.15, 0]
    slide.toValue = [1, 1.15, 1.3]
    slide.duration = isDrop ? 2.2 : 3.2
    slide.repeatCount = .infinity
    slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    sheen.add(slide, forKey: "slide")
    CATransaction.commit()
  }

  func hide(reduceMotion: Bool) -> HUDDismissal {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let closedPath = Self.path(IslandGeometry.tabPath(closed))
    defer { CATransaction.commit() }
    trace.removeAnimation(forKey: "breathe")
    sheen.removeAnimation(forKey: "slide")
    if reduceMotion {
      shape.path = closedPath
      for layer in [icon, readout, name, under, track, trace, sheen] { layer.opacity = 0 }
      capsules.forEach { $0.alphaValue = 0 }
      return .selfAnimated(0)
    }
    for layer in [icon, readout, name, under, track, trace, sheen] { Self.fade(layer, to: 0, duration: 0.14) }
    for view in capsules { Self.fade(view, to: 0, duration: 0.25) }
    if isDrop {
      shape.add(Self.spring("path", from: shape.presentation()?.path ?? shape.path, to: closedPath,
                            damping: Self.foldDamping, stiffness: Self.foldStiffness, delay: 0.1), forKey: "path")
      shape.path = closedPath
      return .selfAnimated(0.6)
    }
    return .selfAnimated(0.3)
  }

  // MARK: - Helpers

  private static func path(_ segments: [IslandGeometry.PathSegment]) -> CGPath {
    let path = CGMutablePath()
    for segment in segments {
      switch segment {
      case .move(let p): path.move(to: p)
      case .line(let p): path.addLine(to: p)
      case .arc(let center, let radius, let start, let end, let clockwise):
        path.addArc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: clockwise)
      }
    }
    return path
  }

  private static func spring(_ key: String, from: Any?, to: Any, damping: CGFloat, stiffness: CGFloat, delay: CFTimeInterval = 0) -> CASpringAnimation {
    let a = CASpringAnimation(keyPath: key)
    a.fromValue = from
    a.toValue = to
    a.damping = damping
    a.stiffness = stiffness
    a.mass = 1
    a.duration = a.settlingDuration
    a.beginTime = CACurrentMediaTime() + delay
    a.fillMode = .backwards
    return a
  }

  private static func ease(_ key: String, from: Any?, to: Any, duration: CFTimeInterval, delay: CFTimeInterval = 0) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: key)
    a.fromValue = from
    a.toValue = to
    a.duration = duration
    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
    a.beginTime = CACurrentMediaTime() + delay
    a.fillMode = .backwards
    return a
  }

  private static func fade(_ layer: CALayer, to: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
    layer.add(ease("opacity", from: layer.presentation()?.opacity ?? layer.opacity, to: to, duration: duration, delay: delay), forKey: "fade")
    layer.opacity = to
  }

  /// A capsule fades from wherever its layer is now, so a reversal mid-fade
  /// does not jump.
  private static func fade(_ view: NSView, to: CGFloat, duration: CFTimeInterval) {
    if let layer = view.layer {
      layer.add(ease("opacity", from: layer.presentation()?.opacity ?? layer.opacity, to: Float(to), duration: duration), forKey: "fade")
    }
    view.alphaValue = to
  }

  private static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
  }

  /// Aspect-fit into a square canvas at 2x, never stretched.
  private static func symbolImage(_ symbol: String, size: CGFloat, color: NSColor) -> CGImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
    let canvas = size * 2
    let tinted = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
      let s = image.size
      let k = min(rect.width / s.width, rect.height / s.height) * 0.9
      image.draw(in: NSRect(x: rect.midX - s.width * k / 2, y: rect.midY - s.height * k / 2, width: s.width * k, height: s.height * k))
      color.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    return tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  // MARK: - Test seams

  var animationKeysForTesting: [String] {
    [shape, under, track, trace, sheen, sheenMask, icon, readout, name].flatMap { $0.animationKeys() ?? [] }
  }
  var traceStrokeEndForTesting: CGFloat { trace.strokeEnd }
  var readoutForTesting: String? { readout.string as? String }
}
