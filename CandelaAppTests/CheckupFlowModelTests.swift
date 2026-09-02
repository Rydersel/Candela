import CandelaKit
import Foundation
import CoreGraphics
import Testing

/// The checkup state machine over fakes: no panel, no window, no wire.
@MainActor
@Suite("Checkup flow model")
struct CheckupFlowModelTests {
  final class FakePresenter: CheckupFieldPresenting {
    var shown: [(CheckupFieldKind, CheckupPlant?)] = []
    var hides = 0
    /// The mirroring case: the window found no screen, so nothing reached glass.
    var refuses = false
    /// The hold the real window takes for the life of a showing. `hide()` also
    /// runs with nothing on screen, so a hide count cannot answer this.
    private(set) var holds: [String] = []
    var isHolding: Bool { holds.last == "begin" }
    func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) -> Bool {
      guard !refuses else { return false }
      shown.append((kind, plant))
      if !isHolding { holds.append("begin") }
      return true
    }
    func hide() {
      hides += 1
      if isHolding { holds.append("end") }
    }
  }

  /// Balanced: opens with a begin, alternates, ends released. Anything else
  /// leaves a panel's care paused with no field on it.
  private func isBalanced(_ holds: [String]) -> Bool {
    var open = false
    for event in holds {
      switch event {
      case "begin" where !open: open = true
      case "end" where open: open = false
      default: return false
      }
    }
    return !open
  }

  struct FakeCaps: CheckupCapabilitiesRunning {
    func run() async -> [CheckupClaim] {
      [CheckupClaim(family: .capabilities, id: CheckupCheckID.capabilityBrightness, verdict: .observed("read 50, wrote 50, read 50"))]
    }
  }
  struct FakeMode: CheckupModeRunning {
    func runNativeMode() async -> [CheckupClaim] { [CheckupClaim(family: .nativeMode, id: CheckupCheckID.nativeMode, verdict: .observed("achieved"))] }
    func runRefreshSweep() async -> [CheckupClaim] { [CheckupClaim(family: .refresh, id: "refresh.60", verdict: .observed("60 Hz achieved, as macOS reports it"))] }
    func restore() async -> Bool { true }
  }
  struct FakeHDR: CheckupHDRRunning {
    func run() async -> [CheckupClaim] { [CheckupClaim(family: .hdr, id: CheckupCheckID.hdrFlags, verdict: .observed("no flags"))] }
  }

  private func entry(
    _ cls: CheckupPanelClass = .readsDDC, only: Bool = false, hdrEngaged: Bool = false
  ) -> CheckupDisplayEntry {
    CheckupDisplayEntry(id: 7, identityKey: "k1", name: "DELL", isBuiltIn: false, isVirtual: false,
                        isMirroring: false, panelClass: cls, hdrEngaged: hdrEngaged,
                        pixelWidth: 3840, pixelHeight: 2160, pointHeight: 2160, isOnlyDisplay: only)
  }

  private func identity() -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(identityKey: "k1", vendorID: 1, modelID: 2, serial: "S", manufactureWeek: nil,
                           manufactureYear: nil, nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 60,
                           supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL")
  }

  private func environment(presenter: FakePresenter, entry: CheckupDisplayEntry, booked: @escaping (CheckupFieldKind, TimeInterval) -> Void = { _, _ in }, capabilities: any CheckupCapabilitiesRunning = FakeCaps()) -> CheckupEnvironment {
    let identity = identity()
    return CheckupEnvironment(
      displays: [entry], macOSBuild: "b", appBuild: "3",
      runners: { _ in CheckupRunnerSet(identity: { identity }, capabilities: capabilities, mode: FakeMode(), hdr: FakeHDR()) },
      presenter: presenter, bookShowing: { _, kind, s in booked(kind, s) },
      now: { Date(timeIntervalSinceReferenceDate: 800_000_000) },
      makeRNG: { SeededGenerator(seed: 1) })
  }

  private func toFirstField(_ flow: CheckupFlowModel) async {
    await flow.advance()                     // scenario -> displayPick
    flow.selectedDisplay = flow.environment.displays[0]
    await flow.advance()                     // displayPick -> plan
    await flow.advance()                     // plan -> identity (runs it)
    await flow.advance()                     // identity -> capabilities (runs)
    await flow.advance()                     // capabilities -> nativeMode (runs)
    await flow.advance()                     // nativeMode -> refresh (runs)
    await flow.advance()                     // refresh -> witness
  }

  @Test func theHappyPathReachesSummaryWithAValidEnvelope() async throws {
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(presenter: presenter, entry: entry()))
    #expect(flow.page == .scenario)
    await toFirstField(flow)
    #expect(flow.page == .witness)
    flow.startShowing()
    flow.answer(.roundAndUncut, tappedRegion: nil)
    #expect(flow.page == .plantDisclosure)
    await flow.advance()
    #expect(flow.page == .fieldInstruction(.black))
    for kind in CheckupFieldKind.protocolOrder {
      #expect(flow.page == .fieldInstruction(kind))
      flow.startShowing()
      #expect(flow.page == .fieldShowing(kind))
      flow.answer(kind == .black ? .oneMark : .nothing, tappedRegion: kind == .black ? flow.plantRegionForTest : nil)
      await flow.advance()
    }
    #expect(flow.page == .hdr)
    await flow.advance()
    #expect(flow.page == .summary)
    let envelope = try #require(flow.envelope)
    #expect(envelope.validate())
    #expect(envelope.report.completion == .complete)
    #expect(envelope.report.plant?.detectedAtPixels == 4)
    #expect(envelope.report.claims.contains { $0.id == "field.black" && $0.verdict.kind == "selfReported" && $0.detectedAt == 4 })
    #expect(envelope.report.claims.contains { $0.id == "field.gray7" && $0.verdict == .selfReported("nothing seen; ungraded, no control on this field") })
    #expect(presenter.hides == presenter.shown.count)
  }

  /// A run that ends normally leaves nothing held: care resumes when the last
  /// field comes down, with no resume step for a later edit to forget.
  @Test func everyFieldReleasesItsCareHoldOnTheWayOut() async {
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(presenter: presenter, entry: entry()))
    await toFirstField(flow)
    flow.startShowing()
    flow.answer(.roundAndUncut, tappedRegion: nil)
    await flow.advance()
    for kind in CheckupFieldKind.protocolOrder {
      flow.startShowing()
      flow.answer(kind == .black ? .oneMark : .nothing,
                  tappedRegion: kind == .black ? flow.plantRegionForTest : nil)
      await flow.advance()
    }
    await flow.advance()
    #expect(flow.page == .summary)
    #expect(presenter.isHolding == false)
    #expect(isBalanced(presenter.holds))
    // The control: a presenter that never held anything cannot pass by doing
    // nothing.
    #expect(presenter.holds.count == CheckupFieldKind.protocolOrder.count * 2 + 2)
  }

  /// An abandon runs mid-field, and the field's hold has to come down with
  /// it: nothing else is left to release it.
  @Test func abandoningMidFieldReleasesTheCareHold() async {
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(presenter: presenter, entry: entry()))
    await toFirstField(flow)
    flow.startShowing()
    #expect(presenter.isHolding)
    flow.abandon(reason: "closed")
    #expect(presenter.isHolding == false)
    #expect(isBalanced(presenter.holds))
  }

  /// Closing the window abandons the run AND hides the field, so one hold takes
  /// two releases. The second must be a no-op, not a stray end nothing opened.
  @Test func closingTheWindowMidFieldReleasesTheHoldExactlyOnce() async {
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(presenter: presenter, entry: entry()))
    await toFirstField(flow)
    flow.startShowing()
    // What `CheckupWindowController` does on a close: `windowShouldClose`
    // abandons, then `windowWillClose` hides the field window itself.
    flow.abandon(reason: "closed")
    presenter.hide()
    #expect(presenter.holds == ["begin", "end"])
    #expect(presenter.isHolding == false)
  }

  /// The contract `CheckupWindowController.abandonForTermination` leans on: a
  /// run in flight at quit still saves as incomplete and still books its field.
  @Test func quittingMidFieldSavesIncompleteAndBooksTheField() async {
    var booked: [(CheckupFieldKind, TimeInterval)] = []
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(
      environment: environment(presenter: presenter, entry: entry(), booked: { booked.append(($0, $1)) }))
    var saved: [CheckupReportEnvelope] = []
    flow.onSaved = { saved.append($0) }
    await toFirstField(flow)
    flow.startShowing()
    for _ in 0..<3 { flow.timeoutTick() }
    flow.abandon(reason: CheckupCopy.closedReason)
    presenter.hide()
    #expect(saved.count == 1)
    #expect(saved.first?.report.completion == .incomplete(reason: CheckupCopy.closedReason))
    #expect(booked.map(\.0) == presenter.shown.map(\.0))
    #expect(booked.first?.1 == 3)
    #expect(presenter.isHolding == false)
    #expect(isBalanced(presenter.holds))
  }

  @Test func aWriteOnlyPlanRecordsPregradedRowsWithoutRunningThem() async {
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry(.writeOnlyDDC)))
    await flow.advance(); flow.selectedDisplay = flow.environment.displays[0]; await flow.advance()
    #expect(flow.plan.filter { $0.pregraded != nil }.count == 3)
    await flow.advance(); await flow.advance()   // identity, then capabilities
    #expect(flow.claims.filter { $0.family == .capabilities }.allSatisfy { $0.verdict.kind == "notObserved" })
  }

  @Test func aMissedPlantRetriesLargerThenMarksInconclusive() async throws {
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()
    flow.answer(.nothing, tappedRegion: nil)          // missed at 4 px
    #expect(flow.page == .fieldInstruction(.black))   // re-shown, same field
    #expect(flow.currentPlantSize == 8)
    flow.startShowing()
    flow.answer(.nothing, tappedRegion: nil)          // missed at 8 px
    await flow.advance()
    #expect(flow.plantRecord?.missed == true)
    while flow.page != .summary { if case .fieldInstruction = flow.page { flow.startShowing(); flow.answer(.nothing, tappedRegion: nil) }; await flow.advance() }
    let report = try #require(flow.report)
    #expect(report.claims.filter { $0.id.hasPrefix("field.") && $0.verdict.kind == "inconclusive" }.count == 5)
    #expect(report.summary.line.contains("control not detected"))
  }

  @Test func moreThanOneReShowsWithoutAPlantAndRecordsTheRegion() async throws {
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(presenter: presenter, entry: entry()))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()
    flow.answer(.moreThanOne, tappedRegion: flow.plantRegionForTest)
    #expect(flow.page == .fieldConfirmSecondDot(.black))
    #expect(presenter.shown.last?.1 == nil)
    flow.answer(.oneMark, tappedRegion: (x: 100, y: 200))
    await flow.advance()
    #expect(flow.claims.contains { $0.id == "field.black" && $0.verdict.text.contains("defect reported at") })
  }

  @Test func showAgainIsCappedAndEveryShowingIsBooked() async {
    var booked: [(CheckupFieldKind, TimeInterval)] = []
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry(), booked: { booked.append(($0, $1)) }))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing(); for _ in 0..<20 { flow.timeoutTick() }
    #expect(flow.page == .fieldInstruction(.black))
    #expect(flow.canShowAgain)
    flow.showAgain(); for _ in 0..<20 { flow.timeoutTick() }
    flow.showAgain(); for _ in 0..<20 { flow.timeoutTick() }
    #expect(flow.showings["field.black"] == 3)
    #expect(!flow.canShowAgain)
    #expect(booked.filter { $0.0 == .black }.map(\.1) == [20, 20, 20])
  }

  @Test func whiteIsCappedAtTenSeconds() async {
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    while flow.page != .fieldInstruction(.white) { flow.startShowing(); flow.answer(.nothing, tappedRegion: flow.plantRegionForTest); await flow.advance() }
    flow.startShowing()
    #expect(flow.secondsRemaining == 10)
  }

  @Test func abandonAndDisconnectSaveIncomplete() async throws {
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    var saved: [CheckupReportEnvelope] = []
    flow.onSaved = { saved.append($0) }
    await flow.advance(); flow.selectedDisplay = flow.environment.displays[0]; await flow.advance(); await flow.advance()
    flow.displayDisconnected(7)
    #expect(saved.first?.report.completion == .incomplete(reason: "the display disconnected during identity"))

    // Picked, then abandoned: there is a display to file it under, so it saves.
    let picked = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    picked.onSaved = { saved.append($0) }
    await picked.advance()
    picked.selectedDisplay = picked.environment.displays[0]
    await picked.advance()
    picked.abandon(reason: "closed")
    #expect(saved.count == 2)
    #expect(saved.last?.report.completion == .incomplete(reason: "closed"))
    #expect(saved.last?.report.identity.identityKey == "k1")

    // Abandoned on the scenario page: no display, so no identity key, and an
    // empty one files the run into the store's root rather than a display's folder.
    let unpicked = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    unpicked.onSaved = { saved.append($0) }
    unpicked.abandon(reason: "closed")
    #expect(saved.count == 2)
    // The report itself still stands; only the save is skipped.
    #expect(unpicked.report?.completion == .incomplete(reason: "closed"))
    #expect(unpicked.report?.identity.identityKey == "")
  }

  /// Left to the panel class, a Dell whose cached string never arrived would be
  /// pre-graded write-only: false about the panel, and it lands in a saved report.
  @Test func anHDREngagedRunPregradesTheCapabilityRowsAndNeverRunsTheLeg() async {
    let runs = CheckupRunCount()
    let flow = CheckupFlowModel(environment: environment(
      presenter: FakePresenter(), entry: entry(hdrEngaged: true),
      capabilities: CountingCapabilities(runs: runs)))
    await flow.advance(); flow.selectedDisplay = flow.environment.displays[0]; await flow.advance()
    #expect(flow.plan.filter { $0.family == .capabilities }.count == 3)
    #expect(flow.plan.filter { $0.pregraded != nil }.count == 3)
    await flow.advance(); await flow.advance()   // identity, then capabilities
    let caps = flow.claims.filter { $0.family == .capabilities }
    #expect(caps.count == 3)
    #expect(caps.allSatisfy { $0.verdict == .notObserved(CheckupPlan.hdrEngagedCapabilityText) })
    #expect(caps.allSatisfy { !$0.verdict.text.contains("write-only") })
    #expect(await runs.count == 0)

    // The control: the same panel out of HDR does run the leg.
    let lit = CheckupRunCount()
    let normal = CheckupFlowModel(environment: environment(
      presenter: FakePresenter(), entry: entry(), capabilities: CountingCapabilities(runs: lit)))
    await normal.advance(); normal.selectedDisplay = normal.environment.displays[0]
    await normal.advance(); await normal.advance(); await normal.advance()
    #expect(await lit.count == 1)
  }

  /// A field that never reached the glass is not a showing: booking it charges
  /// the panel for light it did not emit and grades an attestation nobody made.
  @Test func aPresenterThatRefusesRecordsNothingAndSaysWhy() async {
    var booked: [(CheckupFieldKind, TimeInterval)] = []
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(
      presenter: presenter, entry: entry(), booked: { booked.append(($0, $1)) }))
    await toFirstField(flow)
    presenter.refuses = true
    flow.startShowing()
    #expect(flow.page == .witness)
    #expect(flow.showings.isEmpty)
    #expect(booked.isEmpty)
    #expect(flow.secondsRemaining == 0)
    #expect(flow.showFailureReason == CheckupCopy.fieldNotShown)

    // The control: the same call with the presenter willing does record one.
    presenter.refuses = false
    flow.startShowing()
    #expect(flow.page == .fieldShowing(.witness))
    #expect(flow.showings[CheckupCheckID.field(.witness)] == 1)
    #expect(flow.showFailureReason == nil)
  }

  @Test func theDisplayPickNeverOffersAMirroringDisplay() {
    var mirroring = entry()
    mirroring.isMirroring = true
    let flow = CheckupFlowModel(
      environment: environment(presenter: FakePresenter(), entry: mirroring))
    #expect(flow.selectableDisplays.isEmpty)
  }

  /// The strip is 104 pt of the field's own lower edge on a one-display run, so
  /// the plant has to clear it: 3024x1964 in a 982 pt view is the built-in.
  @Test func aOneDisplayRunKeepsThePlantOutOfTheInstructionStrip() async throws {
    var builtIn = entry(.noDDC, only: true)
    builtIn.pixelWidth = 3024
    builtIn.pixelHeight = 1964
    builtIn.pointHeight = 982
    #expect(CheckupFlowModel.stripBandPixels(on: builtIn) == 208)
    var elsewhere = builtIn
    elsewhere.isOnlyDisplay = false
    #expect(CheckupFlowModel.stripBandPixels(on: elsewhere) == 0)

    let flow = CheckupFlowModel(
      environment: environment(presenter: FakePresenter(), entry: builtIn))
    await toFirstField(flow)
    flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()
    let plant = try #require(flow.plantRegionForTest)
    #expect(plant.y + CheckupFlowModel.firstPlantPixels <= 1964 - 208)
  }

  /// A second advance while a leg is awaited would run the next leg over it and
  /// record both against the wrong step.
  @Test func advanceDoesNothingWhileALegIsInFlight() async throws {
    let gate = CheckupLegGate()
    let flow = CheckupFlowModel(environment: environment(
      presenter: FakePresenter(), entry: entry(), capabilities: GatedCapabilities(gate: gate)))
    await flow.advance(); flow.selectedDisplay = flow.environment.displays[0]
    await flow.advance()                      // displayPick -> plan
    await flow.advance()                      // plan -> identity
    let leg = Task { await flow.advance() }   // identity -> capabilities, suspends in run()
    while await gate.entered == false { await Task.yield() }
    let second = Task { await flow.advance() }
    // Bounded: with the guard this runs out; without it the second advance
    // reaches the same gate and the count moves.
    for _ in 0..<200 where await gate.entries == 1 { await Task.yield() }
    #expect(await gate.entries == 1)
    #expect(flow.page == .identity)
    await gate.open()
    await leg.value
    await second.value
    #expect(flow.page == .capabilities)
    #expect(flow.claims.filter { $0.family == .capabilities }.count == 1)
  }

  /// The instructions strip shows once per field however many times it was
  /// shown, and never on a run with somewhere else to put the instructions.
  @Test func aOneDisplayRunRecordsWhichFieldsCarriedTheStrip() async throws {
    let flow = CheckupFlowModel(
      environment: environment(presenter: FakePresenter(), entry: entry(only: true)))
    var saved: [CheckupReportEnvelope] = []
    flow.onSaved = { saved.append($0) }
    await toFirstField(flow)
    flow.startShowing()
    flow.answer(.roundAndUncut, tappedRegion: nil)
    await flow.advance()                       // plantDisclosure -> the black field
    flow.startShowing()
    for _ in 0..<20 { flow.timeoutTick() }     // runs out, back to the instruction
    flow.startShowing()                        // the same field a second time
    flow.answer(.nothing, tappedRegion: nil)
    #expect(
      flow.partiallyOccludedFields
        == [CheckupCheckID.field(.witness), CheckupCheckID.field(.black)])
    flow.abandon(reason: "closed")
    #expect(
      saved.last?.report.partiallyOccludedFields
        == [CheckupCheckID.field(.witness), CheckupCheckID.field(.black)])

    let elsewhere = CheckupFlowModel(
      environment: environment(presenter: FakePresenter(), entry: entry()))
    await toFirstField(elsewhere)
    elsewhere.startShowing()
    #expect(elsewhere.partiallyOccludedFields.isEmpty)
  }

  @Test func theSelectedDisplayNeverIncludesVirtualOnes() {
    var v = entry(); v.isVirtual = true
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: v))
    #expect(flow.selectableDisplays.isEmpty)
  }

  /// A leg in flight when the cable goes is the one way a saved report could be
  /// written to after the fact.
  @Test func aRunEndedDuringALegKeepsTheSavedReport() async throws {
    let gate = CheckupLegGate()
    let flow = CheckupFlowModel(environment: environment(
      presenter: FakePresenter(), entry: entry(), capabilities: GatedCapabilities(gate: gate)))
    var saved: [CheckupReportEnvelope] = []
    flow.onSaved = { saved.append($0) }
    await flow.advance(); flow.selectedDisplay = flow.environment.displays[0]
    await flow.advance()                      // displayPick -> plan
    await flow.advance()                      // plan -> identity
    let leg = Task { await flow.advance() }   // identity -> capabilities, suspends in run()
    while await gate.entered == false { await Task.yield() }
    flow.displayDisconnected(7)
    #expect(flow.page == .summary)
    let savedReport = try #require(saved.first).report
    // The reason names the leg that was in flight, not the page it left.
    #expect(savedReport.completion == .incomplete(reason: "the display disconnected during capabilities"))
    await gate.open()
    await leg.value
    #expect(flow.page == .summary)
    #expect(flow.claims == savedReport.claims)
    #expect(flow.running == false)
    #expect(saved.count == 1)
  }

  @Test func abandoningWhileAFieldIsShowingBooksThatShowing() async {
    var booked: [(CheckupFieldKind, TimeInterval)] = []
    let presenter = FakePresenter()
    let flow = CheckupFlowModel(environment: environment(
      presenter: presenter, entry: entry(), booked: { booked.append(($0, $1)) }))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()
    for _ in 0..<5 { flow.timeoutTick() }
    flow.abandon(reason: "closed")
    #expect(booked.filter { $0.0 == .black }.map(\.1) == [5])
    #expect(presenter.hides == presenter.shown.count)
  }

  @Test func aSecondMarkAwayFromTheControlStillRetriesTheControl() async throws {
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()
    flow.answer(.moreThanOne, tappedRegion: (x: 10, y: 10))   // nowhere near the control
    #expect(flow.page == .fieldConfirmSecondDot(.black))
    #expect(flow.currentPlantSize == 8)
    flow.answer(.oneMark, tappedRegion: (x: 100, y: 200))
    flow.startShowing()
    flow.answer(.oneMark, tappedRegion: flow.plantRegionForTest)
    let record = try #require(flow.plantRecord)
    #expect(record.detectedAtPixels == 8)
    #expect(!record.missed)
  }

  @Test func leavingTheControlFieldUnresolvedRecordsAMiss() async throws {
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()
    for _ in 0..<20 { flow.timeoutTick() }    // timed out, never answered
    await flow.advance()
    let record = try #require(flow.plantRecord)
    #expect(record.missed)
    #expect(record.detectedAtPixels == nil)
    #expect(flow.claims.contains { $0.id == "field.black" && $0.verdict.kind == "inconclusive" })
    #expect(flow.page == .fieldInstruction(.red))
  }

  @Test func noSequenceOfShowingsPassesTheCap() async {
    var booked: [(CheckupFieldKind, TimeInterval)] = []
    let flow = CheckupFlowModel(environment: environment(
      presenter: FakePresenter(), entry: entry(), booked: { booked.append(($0, $1)) }))
    await toFirstField(flow); flow.startShowing(); flow.answer(.roundAndUncut, tappedRegion: nil); await flow.advance()
    flow.startShowing()                                             // showing 1
    flow.answer(.moreThanOne, tappedRegion: nil)                    // the confirmation, exempt
    flow.answer(.nothing, tappedRegion: nil)
    flow.startShowing(); for _ in 0..<20 { flow.timeoutTick() }     // showing 2
    flow.showAgain(); for _ in 0..<20 { flow.timeoutTick() }        // showing 3
    flow.startShowing()                                             // past the cap: nothing happens
    flow.showAgain()
    #expect(flow.page == .fieldInstruction(.black))
    #expect(!flow.canShowAgain)
    #expect(booked.filter { $0.0 == .black }.count == 4)

    // Bounded: a cap defect that leaves the page on a showing would otherwise
    // spin here forever, since `advance` is a no-op while a field is up.
    for _ in 0..<10 where flow.page != .fieldInstruction(.gray7) { await flow.advance() }
    #expect(flow.page == .fieldInstruction(.gray7))
    flow.startShowing()                                             // showing 1
    flow.answer(.moreThanOne, tappedRegion: nil)                    // no control, so no confirmation
    #expect(flow.page == .fieldInstruction(.gray7))
    flow.startShowing(); for _ in 0..<20 { flow.timeoutTick() }     // showing 2
    flow.showAgain(); for _ in 0..<20 { flow.timeoutTick() }        // showing 3
    flow.startShowing()
    #expect(booked.filter { $0.0 == .gray7 }.count == 3)
  }
}

/// Suspends a runner leg until the test lets it finish, so an exit can land
/// while the leg is still in flight.
actor CheckupLegGate {
  private(set) var entered = false
  /// A second advance into the same leg shows up here as a count above one.
  private(set) var entries = 0
  /// Every waiter, not one: a defect that lets a second advance in would
  /// otherwise strand the first and hang the suite instead of failing it.
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var opened = false

  func wait() async {
    entered = true
    entries += 1
    if opened { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiting.append(continuation)
    }
  }

  func open() {
    opened = true
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }
}

/// So "the leg never ran" is an assertion, not an absence.
actor CheckupRunCount {
  private(set) var count = 0
  func note() { count += 1 }
}

struct CountingCapabilities: CheckupCapabilitiesRunning {
  let runs: CheckupRunCount

  func run() async -> [CheckupClaim] {
    await runs.note()
    return [CheckupClaim(family: .capabilities, id: CheckupCheckID.capabilityBrightness,
                         verdict: .observed("read 50, wrote 50, read 50"))]
  }
}

struct GatedCapabilities: CheckupCapabilitiesRunning {
  let gate: CheckupLegGate

  func run() async -> [CheckupClaim] {
    await gate.wait()
    return [CheckupClaim(family: .capabilities, id: CheckupCheckID.capabilityBrightness,
                         verdict: .observed("read 50, wrote 50, read 50"))]
  }
}
