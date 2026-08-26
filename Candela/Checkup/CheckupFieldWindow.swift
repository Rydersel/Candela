import AppKit
import CandelaKit

/// The field on the target display: borderless, shielding level, pointer out of
/// the way. When the target is the only display, a strip at the bottom carries
/// the instruction, countdown and answers, since the flow window is unreachable
/// behind a shielding-level field; the report records those fields as partially
/// occluded (CK16). The AppKit island behind `CheckupFieldPresenting`.
@MainActor
final class CheckupFieldWindow: CheckupFieldPresenting {
  /// Tall enough for the instruction over a row of answers: on a one-display
  /// run this strip is the whole of the flow's controls.
  static let stripHeight: CGFloat = 104

  private var window: NSWindow?
  /// False in tests: ordering front is the one step with a visible consequence,
  /// and it is the step that puts the pointer away.
  private let orderFront: Bool
  private(set) var isShowing = false
  private(set) var instructionStrip: NSView?
  private var timerLabel: NSTextField?
  private var instructionLabel: NSTextField?
  private var answerTarget: AnswerTarget?

  /// Written through to a strip already on screen: the confirmation re-show
  /// changes the question without taking the field down.
  var instructionText = CheckupCopy.onlyDisplayStrip {
    didSet { instructionLabel?.stringValue = instructionText }
  }

  /// Where the user says they saw a mark, in the field image's pixels with a
  /// top-left origin: the space the planted control's own coordinates live in.
  var onTap: ((_ x: Int, _ y: Int) -> Void)?

  /// The strip's answer buttons. Set by the window controller, which pairs the
  /// answer with `lastTap` before handing both to the flow.
  var onAnswer: ((CheckupFieldAnswer) -> Void)?

  /// Cleared whenever a field goes up: a tap from the previous showing would be
  /// graded against a control that is no longer there.
  private(set) var lastTap: (x: Int, y: Int)?

  /// The flow owns the clock; this is the last value it published.
  private(set) var secondsRemaining = 0

  init(orderFront: Bool = true) { self.orderFront = orderFront }

  var windowForTest: NSWindow? { window }

  /// False when the display has no `NSScreen`, which is what a display mirroring
  /// another looks like from here: there is no glass of our own to draw on, and
  /// the previous field would otherwise stay up while the flow counted a showing.
  func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) -> Bool {
    guard let screen = OverlayWindow.screen(for: display.id) else { return false }
    let window =
      self.window
      ?? NSWindow(
        contentRect: OverlayWindow.seedRect, styleMask: OverlayWindow.styleMask,
        backing: .buffered, defer: false)

    // Painted at the entry's pixel size, not the backing store's: the plant was
    // chosen in that space and taps are graded against it.
    let view = CheckupFieldView(frame: NSRect(origin: .zero, size: screen.frame.size))
    view.autoresizingMask = [.width, .height]
    view.image = CheckupField.image(
      kind: kind, pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight, plant: plant)
    lastTap = nil
    view.onTap = { [weak self] x, y in
      self?.lastTap = (x: x, y: y)
      self?.onTap?(x, y)
    }
    // Before `configure`, which applies the recipe's alpha and black backing to
    // whatever content view the window holds at the time.
    window.contentView = view

    var config = OverlayWindowConfig.dimming
    // The field is the tap target, so it cannot be click-through, and it is
    // opaque from its first frame rather than fading up from nothing.
    config.ignoresMouseEvents = false
    config.initialContentAlpha = 1
    OverlayWindow.configure(
      window, as: config, title: CheckupCopy.fieldWindowTitle, covering: screen.frame)

    instructionStrip = nil
    timerLabel = nil
    instructionLabel = nil
    answerTarget = nil
    secondsRemaining = kind.capSeconds
    if display.isOnlyDisplay {
      let strip = makeInstructionStrip(width: screen.frame.width, kind: kind)
      view.addSubview(strip)
      instructionStrip = strip
    }

    self.window = window
    isShowing = true
    if orderFront {
      // Not `NSCursor.hide()`: the pointer must still reach the mark and the
      // strip. This needs no unhide, so an unexpected exit cannot strand it.
      NSCursor.setHiddenUntilMouseMoves(true)
      window.orderFrontRegardless()
    }
    return true
  }

  /// Driven by the same one-second tick as the flow page, so the two never disagree.
  func updateTimer(_ seconds: Int) {
    secondsRemaining = seconds
    timerLabel?.stringValue = CheckupCopy.secondsLeft(seconds)
  }

  func hide() {
    guard isShowing else { return }
    window?.orderOut(nil)
    isShowing = false
  }

  /// Built by hand rather than hosted from SwiftUI so it stays a plain subview
  /// of the field, inside the shielding-level window.
  private func makeInstructionStrip(width: CGFloat, kind: CheckupFieldKind) -> NSView {
    let strip = CheckupFieldStripView(
      frame: NSRect(x: 0, y: 0, width: width, height: Self.stripHeight))
    strip.autoresizingMask = [.width, .maxYMargin]
    strip.wantsLayer = true
    strip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor

    let inset: CGFloat = 24
    let buttonRowHeight: CGFloat = 32
    let label = NSTextField(wrappingLabelWithString: instructionText)
    label.textColor = .white
    label.alignment = .center
    label.font = .systemFont(ofSize: 12)
    label.isSelectable = false
    let labelHeight = Self.stripHeight - buttonRowHeight - 22
    label.frame = NSRect(
      x: inset, y: Self.stripHeight - labelHeight - 8, width: width - inset * 2,
      height: labelHeight)
    label.autoresizingMask = [.width, .minYMargin]
    strip.addSubview(label)
    instructionLabel = label

    let timer = NSTextField(labelWithString: CheckupCopy.secondsLeft(secondsRemaining))
    timer.textColor = .white
    timer.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    timer.sizeToFit()
    timer.frame = NSRect(
      x: inset, y: 10, width: timer.frame.width + 40, height: buttonRowHeight)
    timer.alignment = .left
    strip.addSubview(timer)
    timerLabel = timer

    let answers = CheckupCopy.answers(for: kind)
    let target = AnswerTarget(answers: answers) { [weak self] answer in self?.onAnswer?(answer) }
    answerTarget = target
    let row = NSStackView(views: answers.enumerated().map { index, answer in
      let button = CheckupStripButton(
        title: CheckupCopy.answerLabel(answer), target: target, action: #selector(AnswerTarget.fire))
      button.bezelStyle = .rounded
      button.tag = index
      return button
    })
    row.orientation = .horizontal
    row.spacing = 10
    row.setFrameSize(row.fittingSize)
    row.setFrameOrigin(
      NSPoint(x: (width - row.fittingSize.width) / 2, y: 10 + (buttonRowHeight - row.fittingSize.height) / 2))
    row.autoresizingMask = [.minXMargin, .maxXMargin]
    strip.addSubview(row)
    return strip
  }

  /// `NSButton` wants a target and a selector, and the window is not an
  /// `NSObject`; one small object carries the strip's closure instead.
  @MainActor
  private final class AnswerTarget: NSObject {
    private let answers: [CheckupFieldAnswer]
    private let handler: (CheckupFieldAnswer) -> Void

    init(answers: [CheckupFieldAnswer], handler: @escaping (CheckupFieldAnswer) -> Void) {
      self.answers = answers
      self.handler = handler
    }

    @objc func fire(_ sender: NSButton) {
      guard answers.indices.contains(sender.tag) else { return }
      handler(answers[sender.tag])
    }
  }
}

/// Swallows clicks that miss its controls; otherwise they fall through to the
/// field and are graded as a tap on a defect.
final class CheckupFieldStripView: NSView {
  override func mouseDown(with event: NSEvent) {}
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The first click on an answer has to BE the answer, and `NSButton` does not
/// accept a first mouse by default.
final class CheckupStripButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws one field image over the whole of a display and reports where it was
/// tapped, in that image's pixels.
final class CheckupFieldView: NSView {
  var image: CGImage?
  var onTap: ((_ x: Int, _ y: Int) -> Void)?

  /// The default, stated because `imagePixel` flips y against it.
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

  /// Inverse of `draw`; y flips because the image origin is top-left and the
  /// view's is bottom-left. Static so it is testable without a screen.
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
