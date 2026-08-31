import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// Reads the accessibility tree SwiftUI publishes, not the source, so a label
/// on the wrong view or swallowed by a parent element fails here.
@MainActor
@Suite("Checkup accessibility labels")
struct CheckupAXLabelTests {

  // MARK: - Reading the published tree

  /// SwiftUI builds no accessibility nodes until an assistive client attaches,
  /// and a test process is not one. Without this flag every walk finds an empty tree.
  private func attachAnAssistiveClient() {
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(
      true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  }

  private func collect(_ element: Any, depth: Int, into found: inout [AnyObject]) {
    guard depth < 24 else { return }
    let object = element as AnyObject
    if (object.accessibilityRole?() ?? nil) == .button { found.append(object) }
    for child in (object.accessibilityChildren?() ?? nil) ?? [] {
      collect(child, depth: depth + 1, into: &found)
    }
  }

  /// Every button element the hosted view publishes, in tree order.
  private func buttonElements(_ view: some View) -> [AnyObject] {
    attachAnAssistiveClient()
    let host = NSHostingView(rootView: view.frame(width: 720, height: 620))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 620)
    host.layoutSubtreeIfNeeded()
    var found: [AnyObject] = []
    collect(host, depth: 0, into: &found)
    return found
  }

  /// nil where the element carries no label at all. Absent and empty are both
  /// failures.
  private func spokenButtons(_ view: some View) -> [String?] {
    buttonElements(view).map { $0.accessibilityLabel?() ?? nil }
  }

  /// Rows that publish as chosen. A fill VoiceOver cannot read is the bug.
  private func selectedButtons(_ view: some View) -> [String] {
    buttonElements(view)
      .filter { ($0.isAccessibilitySelected?() ?? false) }
      .map { ($0.accessibilityLabel?() ?? nil) ?? "" }
  }

  private func expectAllSpeak(
    _ view: some View, _ page: Comment, sourceLocation: SourceLocation = #_sourceLocation
  ) -> [String] {
    let labels = spokenButtons(view)
    #expect(!labels.isEmpty, page, sourceLocation: sourceLocation)
    for label in labels {
      #expect(
        !(label ?? "").isEmpty, "\(page.description) has a button labelled [\(label ?? "absent")]",
        sourceLocation: sourceLocation)
    }
    return labels.map { $0 ?? "" }
  }

  // MARK: - The control

  /// Proves the walk can fail: otherwise every test here passes on nothing.
  @Test func theWalkCanReportAMissingLabel() {
    let unlabelled = Button(action: {}) { Color.clear.accessibilityHidden(true) }
    let labels = spokenButtons(unlabelled)
    #expect(labels.count == 1)
    #expect(((labels.first ?? nil) ?? "").isEmpty)

    // Same shape with a label, so the reader is not simply blind to this button.
    let labelled = Button(action: {}) { Color.clear.accessibilityHidden(true) }
      .accessibilityLabel(Text(verbatim: "control probe"))
    #expect(spokenButtons(labelled).map { $0 ?? "" } == ["control probe"])
  }

  // MARK: - The pages

  @Test func theScenarioRowsAndContinueSpeakTheirOwnCopy() {
    let flow = CheckupFixture.flow()
    let labels = expectAllSpeak(CheckupScenarioPage(model: flow), "the scenario page")
    for scenario in CheckupScenario.allCases {
      #expect(labels.contains(CheckupCopy.scenarioLabel(scenario)))
    }
    #expect(labels.contains(CheckupCopy.continueLabel))

    flow.scenario = .usedPurchase
    #expect(
      selectedButtons(CheckupScenarioPage(model: flow))
        == [CheckupCopy.scenarioLabel(.usedPurchase)])
  }

  @Test func theDisplayRowsSpeakTheirNameAndPanelClass() {
    let dell = CheckupFixture.entry(name: "DELL U2725QE", panelClass: .readsDDC)
    let mag = CheckupFixture.entry(
      id: 8, name: "MAG 341C", panelClass: .writeOnlyDDC, hdrEngaged: true)
    let flow = CheckupFixture.flow(displays: [dell, mag])
    let labels = expectAllSpeak(CheckupDisplayPickPage(model: flow), "the display pick page")

    #expect(labels.contains(CheckupCopy.displayRowLabel(dell)))
    #expect(labels.contains(CheckupCopy.displayRowLabel(mag)))
    #expect(labels.contains(CheckupCopy.continueLabel))

    let dellLabel = CheckupCopy.displayRowLabel(dell)
    #expect(dellLabel.hasPrefix("DELL U2725QE"))
    // Grouped, so VoiceOver reads a number rather than four digits in a row.
    #expect(dellLabel.contains("3,840 by 2,160 pixels"))
    #expect(dellLabel.contains(CheckupCopy.panelClassLine(.readsDDC, hdrEngaged: false)))
    // HDR is engaged, so the row speaks that rather than the panel class.
    #expect(CheckupCopy.displayRowLabel(mag).contains(CheckupCopy.hdrEngagedLine))

    flow.selectedDisplay = mag
    #expect(
      selectedButtons(CheckupDisplayPickPage(model: flow)) == [CheckupCopy.displayRowLabel(mag)])
  }

  @Test func thePlanAndDisclosurePagesSpeakContinue() {
    let flow = CheckupFixture.flow()
    #expect(
      expectAllSpeak(CheckupPlanPage(model: flow), "the plan page")
        == [CheckupCopy.continueLabel])
    #expect(
      expectAllSpeak(CheckupPlantDisclosurePage(model: flow), "the plant disclosure page")
        == [CheckupCopy.continueLabel])
  }

  @Test func aMeasuredLegSpeaksContinueWhileItRuns() {
    let flow = CheckupFixture.flow()
    let page = CheckupLegPage(model: flow, title: CheckupCopy.identityTitle, family: .identity)
    #expect(expectAllSpeak(page, "a measured leg") == [CheckupCopy.continueLabel])
  }

  @Test func theFieldInstructionPageSpeaksStartThenShowItAgain() async {
    let flow = CheckupFixture.flow()
    await CheckupFixture.driveToFirstField(flow)

    let before = expectAllSpeak(
      CheckupFieldInstructionPage(model: flow, kind: .witness), "the field instruction page")
    #expect(before == [CheckupCopy.start])

    flow.startShowing()
    let after = expectAllSpeak(
      CheckupFieldInstructionPage(model: flow, kind: .witness), "the field instruction page")
    #expect(after == [CheckupCopy.showAgain, CheckupCopy.continueLabel])
  }

  @Test func theAnswersSpeakTheAnswerTheyRecord() {
    for kind in CheckupFieldKind.allCases {
      let expected = CheckupCopy.answers(for: kind).map(CheckupCopy.answerLabel)
      let buttons = CheckupAnswerButtons(kind: kind, answer: { _ in })
      #expect(expectAllSpeak(buttons, "the answers for \(kind.rawValue)") == expected)
    }
  }

  /// On a one-display run the flow window is behind the field and these are the
  /// only answers on screen.
  @Test func theShowingAndSecondDotPagesCarryTheAnswers() async {
    let flow = CheckupFixture.flow()
    await CheckupFixture.driveToFirstField(flow)
    let expected = CheckupCopy.answers(for: .black).map(CheckupCopy.answerLabel)

    let showing = CheckupFieldShowingPage(model: flow, kind: .black, tappedRegion: { nil })
    #expect(expectAllSpeak(showing, "the field showing page") == expected)

    let secondDot = CheckupSecondDotPage(model: flow, kind: .black, tappedRegion: { nil })
    #expect(expectAllSpeak(secondDot, "the second dot page") == expected)
  }

  @Test func theSummaryPageSpeaksItsTwoWaysOutOfTheReport() {
    let flow = CheckupFixture.flow()
    let labels = expectAllSpeak(CheckupSummaryPage(model: flow), "the summary page")
    #expect(labels == [CheckupCopy.export, CheckupCopy.copySummary])
  }

  /// An `NSButton` falls back to its title when no label was set, so blanking the
  /// titles separates them: a real label survives, a title fallback does not.
  @Test func theOnlyDisplayStripsAnswersCarryLabelsOfTheirOwn() throws {
    let window = CheckupFieldWindow(orderFront: false)
    var onlyDisplay = CheckupFixture.entry(
      id: CGMainDisplayID(), pixelWidth: 200, pixelHeight: 100)
    onlyDisplay.isOnlyDisplay = true

    for kind in [CheckupFieldKind.black, .witness] {
      _ = window.show(kind: kind, plant: nil, on: onlyDisplay)
      let buttons = Self.buttons(in: try #require(window.instructionStrip))
      let expected = CheckupCopy.answers(for: kind).map(CheckupCopy.answerLabel)
      #expect(buttons.map { $0.accessibilityLabel() ?? "" } == expected)
      for button in buttons { button.title = "" }
      #expect(buttons.map { $0.accessibilityLabel() ?? "" } == expected)
      window.hide()
    }
  }

  private static func buttons(in view: NSView) -> [NSButton] {
    view.subviews.flatMap { sub -> [NSButton] in
      if let button = sub as? NSButton { return [button] }
      return buttons(in: sub)
    }
  }
}

/// Fakes only: nothing here reaches a panel, a clock or a store.
@MainActor
enum CheckupFixture {
  final class SilentPresenter: CheckupFieldPresenting {
    func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) -> Bool
    { true }
    func hide() {}
  }

  struct StubCapabilities: CheckupCapabilitiesRunning {
    func run() async -> [CheckupClaim] { [] }
  }

  struct StubMode: CheckupModeRunning {
    func runNativeMode() async -> [CheckupClaim] { [] }
    func runRefreshSweep() async -> [CheckupClaim] { [] }
    func restore() async -> Bool { true }
  }

  struct StubHDR: CheckupHDRRunning {
    func run() async -> [CheckupClaim] { [] }
  }

  static func entry(
    id: CGDirectDisplayID = 7, name: String = "DELL U2725QE",
    panelClass: CheckupPanelClass = .readsDDC, hdrEngaged: Bool = false,
    pixelWidth: Int = 3840, pixelHeight: Int = 2160
  ) -> CheckupDisplayEntry {
    CheckupDisplayEntry(
      id: id, identityKey: "k\(id)", name: name, isBuiltIn: false, isVirtual: false,
      isMirroring: false, panelClass: panelClass, hdrEngaged: hdrEngaged, pixelWidth: pixelWidth,
      pixelHeight: pixelHeight, pointHeight: Double(pixelHeight), isOnlyDisplay: false)
  }

  static func identity() -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(
      identityKey: "k7", vendorID: 1, modelID: 2, serial: "S", manufactureWeek: nil,
      manufactureYear: nil, nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 60,
      supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE")
  }

  static func flow(displays: [CheckupDisplayEntry] = [entry()]) -> CheckupFlowModel {
    let identity = identity()
    return CheckupFlowModel(
      environment: CheckupEnvironment(
        displays: displays, macOSBuild: "b", appBuild: "3",
        runners: { _ in
          CheckupRunnerSet(
            identity: { identity }, capabilities: StubCapabilities(), mode: StubMode(),
            hdr: StubHDR())
        },
        presenter: SilentPresenter(), bookShowing: { _, _, _ in },
        now: { Date(timeIntervalSinceReferenceDate: 800_000_000) },
        makeRNG: { SeededGenerator(seed: 1) }))
  }

  /// Advances to the witness card, the first page that asks a person to look at
  /// the panel.
  static func driveToFirstField(_ flow: CheckupFlowModel) async {
    await flow.advance()
    flow.selectedDisplay = flow.environment.displays.first
    // Driven by the page it is after rather than by a step count, which a leg
    // added or dropped would silently move. The bound only stops a runaway.
    for _ in 0..<20 where flow.page != .witness { await flow.advance() }
    #expect(flow.page == .witness)
  }
}
