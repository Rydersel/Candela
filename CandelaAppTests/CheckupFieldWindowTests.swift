import AppKit
import CandelaKit
import Testing

/// The field covers a user's whole panel at `CGShieldingWindowLevel()` with no
/// chrome to close it by, so the flags below are the ones whose failure is
/// silent and expensive: a level under shielding lets the screen saver paint
/// over the field being graded, and a click-through field makes the tap that
/// reports a mark land on whatever is underneath.
///
/// Host-free: every window here is created and configured but never ordered on
/// screen, and nothing hides the pointer.
@MainActor
@Suite("Checkup field window")
struct CheckupFieldWindowTests {
  private func entry(only: Bool) -> CheckupDisplayEntry {
    CheckupDisplayEntry(
      id: CGMainDisplayID(), identityKey: "k", name: "Main", isBuiltIn: true, isVirtual: false,
      panelClass: .noDDC, pixelWidth: 200, pixelHeight: 100, isOnlyDisplay: only)
  }

  @Test func theWindowIsShieldingLevelBorderlessAndCoversTheScreen() throws {
    let w = CheckupFieldWindow(orderFront: false)
    w.show(kind: .black, plant: CheckupPlant(x: 10, y: 10, size: 4), on: entry(only: false))
    let window = try #require(w.windowForTest)
    #expect(window.level.rawValue == Int(CGShieldingWindowLevel()))
    #expect(window.styleMask.contains(.borderless))
    // `.borderless` is the zero option, so `contains` above is true of any mask
    // at all. This is the assertion that can fail.
    #expect(window.styleMask == OverlayWindow.styleMask)
    #expect(window.ignoresMouseEvents == false)
    // The content view is what the dimming recipe's alpha lands on, and a field
    // at alpha 0 is an invisible field.
    #expect(window.contentView?.alphaValue == 1)
    let screen = try #require(OverlayWindow.screen(for: CGMainDisplayID()))
    #expect(window.frame == screen.frame)
    #expect(w.isShowing)
    #expect(w.instructionStrip == nil)
    w.hide()
    #expect(w.isShowing == false)
  }

  /// The plant's coordinates come from the entry's pixel size, and the model
  /// grades a tap by comparing it against them, so the field has to be painted
  /// in that same space: an image at any other size puts the drawn control
  /// somewhere the position rule never promised.
  @Test func theFieldIsPaintedInThePixelSpaceThePlantWasChosenIn() throws {
    let w = CheckupFieldWindow(orderFront: false)
    w.show(kind: .white, plant: nil, on: entry(only: false))
    let view = try #require(w.windowForTest?.contentView as? CheckupFieldView)
    let image = try #require(view.image)
    #expect(image.width == 200)
    #expect(image.height == 100)
    w.hide()
  }

  @Test func theOnlyDisplayGetsTheInstructionStrip() {
    let w = CheckupFieldWindow(orderFront: false)
    w.show(kind: .white, plant: nil, on: entry(only: true))
    #expect(w.instructionStrip != nil)
    w.hide()
  }

  /// The image is top-left origin (the plant's y is the y a user would tap) and
  /// the view is not flipped, so the two disagree about y and this conversion
  /// is the only thing reconciling them. Drop the flip and every tap is graded
  /// against a mark mirrored across the middle of the panel, which reads as a
  /// user who cannot point at a dot.
  @Test func aTapAtTheTopLeftCornerNamesThePixelAtTheTopOfTheImage() {
    let size = NSSize(width: 400, height: 200)
    #expect(CheckupFieldView(frame: NSRect(origin: .zero, size: size)).isFlipped == false)

    let topLeft = CheckupFieldView.imagePixel(
      forViewPoint: NSPoint(x: 0, y: size.height), in: size, imageWidth: 800, imageHeight: 400)
    #expect(topLeft.x == 0)
    #expect(topLeft.y == 0)

    // The opposite corner, so a conversion that simply returned zero fails.
    let bottomLeft = CheckupFieldView.imagePixel(
      forViewPoint: .zero, in: size, imageWidth: 800, imageHeight: 400)
    #expect(bottomLeft.x == 0)
    #expect(bottomLeft.y == 399)

    // A quarter of the way down the view is a quarter of the way down the
    // image; without the flip this y would be 300.
    let upper = CheckupFieldView.imagePixel(
      forViewPoint: NSPoint(x: 100, y: 150), in: size, imageWidth: 800, imageHeight: 400)
    #expect(upper.x == 200)
    #expect(upper.y == 100)
  }

  /// A degenerate view size is the one input that can divide by zero, and it
  /// arrives from a window that has not been framed yet.
  @Test func aZeroSizedViewNamesThePixelAtTheOrigin() {
    let p = CheckupFieldView.imagePixel(
      forViewPoint: NSPoint(x: 10, y: 10), in: .zero, imageWidth: 800, imageHeight: 400)
    #expect(p.x == 0)
    #expect(p.y == 0)
  }
}
