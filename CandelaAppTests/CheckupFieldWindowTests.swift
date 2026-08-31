import AppKit
import CandelaKit
import Testing

/// The field covers the whole panel at shielding level with no chrome, and these
/// flags fail quietly: a lower level lets the screen saver paint over it, and
/// click-through sends the tap underneath. Nothing here is ordered on screen.
@MainActor
@Suite("Checkup field window")
struct CheckupFieldWindowTests {
  private func entry(only: Bool) -> CheckupDisplayEntry {
    CheckupDisplayEntry(
      id: CGMainDisplayID(), identityKey: "k", name: "Main", isBuiltIn: true, isVirtual: false,
      isMirroring: false, panelClass: .noDDC, hdrEngaged: false, pixelWidth: 200,
      pixelHeight: 100, pointHeight: 100, isOnlyDisplay: only)
  }

  /// The mirroring case: no `NSScreen`, and the flow must not book a showing on it.
  @Test func showRefusesADisplayWithNoScreen() {
    var absent = entry(only: false)
    // No display carries this id, so `OverlayWindow.screen(for:)` answers nil.
    absent.id = 0xFFFF_FFFE
    let w = CheckupFieldWindow(orderFront: false)
    #expect(w.show(kind: .black, plant: nil, on: absent) == false)
    #expect(w.isShowing == false)
    #expect(w.windowForTest == nil)
    #expect(w.show(kind: .black, plant: nil, on: entry(only: false)))
  }

  @Test func theWindowIsShieldingLevelBorderlessAndCoversTheScreen() throws {
    let w = CheckupFieldWindow(orderFront: false)
    _ = w.show(kind: .black, plant: CheckupPlant(x: 10, y: 10, size: 4), on: entry(only: false))
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

  /// The plant was chosen in the entry's pixel space and taps are graded there,
  /// so the field must be painted at that size.
  @Test func theFieldIsPaintedInThePixelSpaceThePlantWasChosenIn() throws {
    let w = CheckupFieldWindow(orderFront: false)
    _ = w.show(kind: .white, plant: nil, on: entry(only: false))
    let view = try #require(w.windowForTest?.contentView as? CheckupFieldView)
    let image = try #require(view.image)
    #expect(image.width == 200)
    #expect(image.height == 100)
    w.hide()
  }

  @Test func theOnlyDisplayGetsTheInstructionStrip() {
    let w = CheckupFieldWindow(orderFront: false)
    _ = w.show(kind: .white, plant: nil, on: entry(only: true))
    #expect(w.instructionStrip != nil)
    w.hide()
  }

  /// On a one-display run the strip is the only place to answer. Each field's
  /// own answers: the witness card asks about geometry.
  @Test func theOnlyDisplayStripCarriesTheAnswersTheFieldOffers() throws {
    let w = CheckupFieldWindow(orderFront: false)
    _ = w.show(kind: .black, plant: nil, on: entry(only: true))
    let plantStrip = try #require(w.instructionStrip)
    #expect(
      Self.buttonTitles(in: plantStrip)
        == [CheckupCopy.answerNothing, CheckupCopy.answerOne, CheckupCopy.answerMore])
    w.hide()

    _ = w.show(kind: .witness, plant: nil, on: entry(only: true))
    let witnessStrip = try #require(w.instructionStrip)
    #expect(
      Self.buttonTitles(in: witnessStrip)
        == [CheckupCopy.answerRound, CheckupCopy.answerNotRound])
    w.hide()
  }

  /// Both change while the field stays up: the cap runs down, and the
  /// confirmation re-show asks a different question.
  @Test func theStripsTimerAndInstructionRenderTheValuesTheFlowPublishes() throws {
    let w = CheckupFieldWindow(orderFront: false)
    w.instructionText = CheckupCopy.instruction(for: .red)
    _ = w.show(kind: .red, plant: nil, on: entry(only: true))
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
    _ = w.show(kind: .black, plant: nil, on: entry(only: false))
    let view = w.windowForTest?.contentView as? CheckupFieldView
    view?.onTap?(11, 12)
    #expect(w.lastTap?.x == 11)
    _ = w.show(kind: .red, plant: nil, on: entry(only: false))
    #expect(w.lastTap == nil)
    w.hide()
  }

  /// A shared target with a tag is exactly the shape where every button
  /// quietly sends the same answer.
  @Test func eachStripButtonReportsItsOwnAnswer() throws {
    let w = CheckupFieldWindow(orderFront: false)
    var received: [CheckupFieldAnswer] = []
    w.onAnswer = { received.append($0) }

    _ = w.show(kind: .black, plant: nil, on: entry(only: true))
    for button in Self.buttons(in: try #require(w.instructionStrip)) { button.performClick(nil) }
    #expect(received == [.nothing, .oneMark, .moreThanOne])
    w.hide()

    received.removeAll()
    _ = w.show(kind: .witness, plant: nil, on: entry(only: true))
    for button in Self.buttons(in: try #require(w.instructionStrip)) { button.performClick(nil) }
    #expect(received == [.roundAndUncut, .notRound])
    w.hide()
  }

  /// The field is clicked while another app is frontmost, so the first click on
  /// an answer has to be the answer and not an activation the person repeats.
  @Test func theStripAndItsButtonsAcceptAFirstMouse() throws {
    let w = CheckupFieldWindow(orderFront: false)
    _ = w.show(kind: .black, plant: nil, on: entry(only: true))
    let strip = try #require(w.instructionStrip)
    #expect(strip.acceptsFirstMouse(for: nil))
    #expect(Self.buttons(in: strip).allSatisfy { $0.acceptsFirstMouse(for: nil) })
    w.hide()
  }

  private static func buttons(in view: NSView) -> [NSButton] {
    view.subviews.flatMap { sub -> [NSButton] in
      if let button = sub as? NSButton { return [button] }
      return buttons(in: sub)
    }
  }

  private static func buttonTitles(in view: NSView) -> [String] {
    buttons(in: view).map(\.title)
  }

  private static func labelStrings(in view: NSView) -> [String] {
    view.subviews.flatMap { sub -> [String] in
      if let field = sub as? NSTextField { return [field.stringValue] }
      return labelStrings(in: sub)
    }
  }

  /// Records holds in order, so a begin without its end shows up as a sequence
  /// rather than as a count that happens to match.
  @MainActor
  final class FakeCare: CheckupCareHolding {
    private(set) var events: [String] = []
    var held: Set<String> = []
    func beginCheckupField(identityKey: String) {
      events.append("begin \(identityKey)")
      held.insert(identityKey)
    }
    func endCheckupField(identityKey: String) {
      events.append("end \(identityKey)")
      held.remove(identityKey)
    }
  }

  /// The field and every care overlay sit at the same shielding level, so a dim
  /// that won the ordering would be judged as part of the panel.
  @Test func aShowingHoldsCareOffTheTargetAndTheHideReleasesIt() {
    let care = FakeCare()
    let w = CheckupFieldWindow(orderFront: false, care: care)
    #expect(w.show(kind: .white, plant: nil, on: entry(only: false)))
    #expect(care.held == ["k"])
    w.hide()
    #expect(care.held.isEmpty)
    #expect(care.events == ["begin k", "end k"])
  }

  /// `windowWillClose` hides the field on top of the abandon that already did,
  /// so the second hide must not release a hold the first one gave up.
  @Test func hidingTwiceReleasesTheHoldExactlyOnce() {
    let care = FakeCare()
    let w = CheckupFieldWindow(orderFront: false, care: care)
    w.hide()
    #expect(care.events.isEmpty)
    #expect(w.show(kind: .black, plant: nil, on: entry(only: false)))
    w.hide()
    w.hide()
    #expect(care.events == ["begin k", "end k"])
    #expect(care.held.isEmpty)
  }

  /// A hold on a refused showing would pause a display's care with no field on
  /// it and no hide coming to release it.
  @Test func aRefusedShowingTakesNoHold() {
    var absent = entry(only: false)
    absent.id = 0xFFFF_FFFE
    let care = FakeCare()
    let w = CheckupFieldWindow(orderFront: false, care: care)
    #expect(w.show(kind: .black, plant: nil, on: absent) == false)
    #expect(care.events.isEmpty)
  }

  /// A re-show without an intervening hide is how the confirmation field goes
  /// up: one hold stands throughout, and one release ends it.
  @Test func aReShowOnTheSameDisplayKeepsTheOneHold() {
    let care = FakeCare()
    let w = CheckupFieldWindow(orderFront: false, care: care)
    #expect(w.show(kind: .black, plant: nil, on: entry(only: false)))
    #expect(w.show(kind: .black, plant: nil, on: entry(only: false)))
    #expect(care.events == ["begin k"])
    w.hide()
    #expect(care.events == ["begin k", "end k"])
  }

  /// The image is top-left origin and the view is not flipped; drop the flip
  /// and every tap is graded against a mark mirrored across the panel.
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
