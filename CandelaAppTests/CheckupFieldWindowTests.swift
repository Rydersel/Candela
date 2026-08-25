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

  /// On a one-display run the flow window is behind a shielding-level field,
  /// so a strip without the answers on it is a run nobody can answer. Each
  /// field's own answers, not a fixed three: the witness card asks about
  /// geometry and offers neither "one mark" nor "more than one".
  @Test func theOnlyDisplayStripCarriesTheAnswersTheFieldOffers() throws {
    let w = CheckupFieldWindow(orderFront: false)
    w.show(kind: .black, plant: nil, on: entry(only: true))
    let plantStrip = try #require(w.instructionStrip)
    #expect(
      Self.buttonTitles(in: plantStrip)
        == [CheckupCopy.answerNothing, CheckupCopy.answerOne, CheckupCopy.answerMore])
    w.hide()

    w.show(kind: .witness, plant: nil, on: entry(only: true))
    let witnessStrip = try #require(w.instructionStrip)
    #expect(
      Self.buttonTitles(in: witnessStrip)
        == [CheckupCopy.answerRound, CheckupCopy.answerNotRound])
    w.hide()
  }

  /// The countdown and the instruction both change while the field stays up:
  /// the cap runs down every second, and the confirmation re-show asks a
  /// different question of the same field.
  @Test func theStripsTimerAndInstructionRenderTheValuesTheFlowPublishes() throws {
    let w = CheckupFieldWindow(orderFront: false)
    w.instructionText = CheckupCopy.instruction(for: .red)
    w.show(kind: .red, plant: nil, on: entry(only: true))
    let strip = try #require(w.instructionStrip)
    #expect(Self.labelStrings(in: strip).contains(CheckupCopy.secondsLeft(20)))
    #expect(Self.labelStrings(in: strip).contains(CheckupCopy.instruction(for: .red)))

    w.updateTimer(7)
    #expect(w.secondsRemaining == 7)
    #expect(Self.labelStrings(in: strip).contains(CheckupCopy.secondsLeft(7)))

    w.instructionText = CheckupCopy.secondDotPrompt
    #expect(Self.labelStrings(in: strip).contains(CheckupCopy.secondDotPrompt))
    w.hide()
  }

  /// A region reported against the previous showing would be graded against a
  /// control that is no longer on the panel.
  @Test func aNewShowingForgetsTheTapTheLastOneSaw() {
    let w = CheckupFieldWindow(orderFront: false)
    w.show(kind: .black, plant: nil, on: entry(only: false))
    let view = w.windowForTest?.contentView as? CheckupFieldView
    view?.onTap?(11, 12)
    #expect(w.lastTap?.x == 11)
    w.show(kind: .red, plant: nil, on: entry(only: false))
    #expect(w.lastTap == nil)
    w.hide()
  }

  private static func buttonTitles(in view: NSView) -> [String] {
    view.subviews.flatMap { sub -> [String] in
      if let button = sub as? NSButton { return [button.title] }
      return buttonTitles(in: sub)
    }
  }

  private static func labelStrings(in view: NSView) -> [String] {
    view.subviews.flatMap { sub -> [String] in
      if let field = sub as? NSTextField { return [field.stringValue] }
      return labelStrings(in: sub)
    }
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
