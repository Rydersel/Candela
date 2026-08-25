import AppKit
import CandelaKit

/// The field on the target display and nothing else: borderless, shielding
/// level, pointer hidden. The flow window lives on another display; when the
/// target is the only display, a strip at the bottom carries the instruction
/// and the report records the field as partially occluded (CK16).
///
/// The AppKit island behind `CheckupFieldPresenting`, so the flow model can be
/// driven over a fake with no window anywhere.
@MainActor
final class CheckupFieldWindow: CheckupFieldPresenting {
  /// The instruction strip's height in points, and the reason the field is only
  /// partially the panel when the target is the only display.
  static let stripHeight: CGFloat = 44

  private var window: NSWindow?
  /// False in tests: ordering front is the one step with a visible consequence,
  /// and it is the step that hides the pointer.
  private let orderFront: Bool
  private var didHideCursor = false
  private(set) var isShowing = false
  private(set) var instructionStrip: NSView?

  /// What the strip says when the target is the only display. The flow sets it
  /// per field; the default is the part that is true of every field.
  var instructionText = "This display is showing a Candela checkup field. The checkup window is behind it."

  /// Where the user says they saw a mark, in the field image's pixels with a
  /// top-left origin: the space the planted control's own coordinates live in.
  var onTap: ((_ x: Int, _ y: Int) -> Void)?

  init(orderFront: Bool = true) { self.orderFront = orderFront }

  var windowForTest: NSWindow? { window }

  func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) {
    guard let screen = OverlayWindow.screen(for: display.id) else { return }
    let window =
      self.window
      ?? NSWindow(
        contentRect: OverlayWindow.seedRect, styleMask: OverlayWindow.styleMask,
        backing: .buffered, defer: false)

    // Painted at the entry's pixel size, not the backing store's: the plant's
    // coordinates were chosen in that space and the model grades a tap by
    // comparing it against them, so any other size moves the drawn control off
    // the position the margin rule promised.
    let view = CheckupFieldView(frame: NSRect(origin: .zero, size: screen.frame.size))
    view.autoresizingMask = [.width, .height]
    view.image = CheckupField.image(
      kind: kind, pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight, plant: plant)
    view.onTap = { [weak self] x, y in self?.onTap?(x, y) }
    // Before `configure`, which applies the recipe's alpha and black backing to
    // whatever content view the window is holding. Set after, the field would
    // be an unconfigured view over a window whose recipe landed on a discarded
    // one, and a failed image would show through to the desktop.
    window.contentView = view

    var config = OverlayWindowConfig.dimming
    // The field is the tap target, so it cannot be click-through, and it is
    // opaque from its first frame rather than fading up from nothing.
    config.ignoresMouseEvents = false
    config.initialContentAlpha = 1
    OverlayWindow.configure(window, as: config, title: "Candela Checkup Field", covering: screen.frame)

    instructionStrip = nil
    if display.isOnlyDisplay {
      let strip = makeInstructionStrip(width: screen.frame.width)
      view.addSubview(strip)
      instructionStrip = strip
    }

    self.window = window
    isShowing = true
    if orderFront {
      if !didHideCursor {
        NSCursor.hide()
        didHideCursor = true
      }
      window.orderFrontRegardless()
    }
  }

  func hide() {
    guard isShowing else { return }
    if didHideCursor {
      NSCursor.unhide()
      didHideCursor = false
    }
    window?.orderOut(nil)
    isShowing = false
  }

  /// A container rather than a bare label: a label's text sits at the top of a
  /// frame taller than its line, so the strip's own view is what centres it.
  private func makeInstructionStrip(width: CGFloat) -> NSView {
    let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.stripHeight))
    strip.autoresizingMask = [.width, .maxYMargin]
    strip.wantsLayer = true
    strip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

    let label = NSTextField(labelWithString: instructionText)
    label.textColor = .white
    label.alignment = .center
    label.font = .systemFont(ofSize: 13)
    label.sizeToFit()
    label.frame = NSRect(
      x: 0, y: (Self.stripHeight - label.frame.height) / 2, width: width,
      height: label.frame.height)
    label.autoresizingMask = [.width]
    strip.addSubview(label)
    return strip
  }
}

/// Draws one field image over the whole of a display and reports where it was
/// tapped, in that image's pixels.
final class CheckupFieldView: NSView {
  var image: CGImage?
  var onTap: ((_ x: Int, _ y: Int) -> Void)?

  /// The default, stated because `imagePixel` is written against it: the image
  /// is top-left origin and this view is not, so the conversion flips y. The
  /// two only make sense as a pair.
  override var isFlipped: Bool { false }

  /// The field window can be clicked while another app is active, and the first
  /// click has to be the tap rather than an activation the user has to repeat.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
    // Nearest neighbour: a smoothed plant is a plant at a size nobody planted.
    ctx.interpolationQuality = .none
    ctx.draw(image, in: bounds)
  }

  override func mouseDown(with event: NSEvent) {
    guard let image else { return }
    let pixel = Self.imagePixel(
      forViewPoint: convert(event.locationInWindow, from: nil), in: bounds.size,
      imageWidth: image.width, imageHeight: image.height)
    onTap?(pixel.x, pixel.y)
  }

  /// The exact inverse of `draw`: the image fills `bounds`, so a point maps by
  /// the ratio, and y is measured from the other edge because the image's
  /// origin is top-left and the view's is bottom-left.
  ///
  /// Pure and static so the pairing above can be tested without a screen.
  static func imagePixel(
    forViewPoint point: NSPoint, in viewSize: NSSize, imageWidth: Int, imageHeight: Int
  ) -> (x: Int, y: Int) {
    guard viewSize.width > 0, viewSize.height > 0, imageWidth > 0, imageHeight > 0 else {
      return (0, 0)
    }
    let x = Int((point.x / viewSize.width) * CGFloat(imageWidth))
    let y = Int(((viewSize.height - point.y) / viewSize.height) * CGFloat(imageHeight))
    // A tap on the far edge names a pixel one past the last one, and a report
    // should never carry a coordinate the image does not have.
    return (min(max(x, 0), imageWidth - 1), min(max(y, 0), imageHeight - 1))
  }
}
