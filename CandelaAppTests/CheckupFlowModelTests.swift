import CandelaKit
import Foundation
import CoreGraphics
import Testing

/// The checkup state machine over fakes (CK25): every page, the planted
/// control's detect, miss and second-dot paths, the showing cap, and the two
/// exits that save an incomplete report. No panel, no window, no wire.
@MainActor
@Suite("Checkup flow model")
struct CheckupFlowModelTests {
  final class FakePresenter: CheckupFieldPresenting {
    var shown: [(CheckupFieldKind, CheckupPlant?)] = []
    var hides = 0
    func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) { shown.append((kind, plant)) }
    func hide() { hides += 1 }
  }

  struct FakeCaps: CheckupCapabilitiesRunning {
    func run() async -> [CheckupClaim] {
      [CheckupClaim(family: .capabilities, id: CheckupCheckID.capabilityBrightness, verdict: .observed("read 50, wrote 50, read 50"))]
    }
  }
  struct FakeMode: CheckupModeRunning {
    func runNativeMode() async -> [CheckupClaim] { [CheckupClaim(family: .nativeMode, id: CheckupCheckID.nativeMode, verdict: .observed("achieved"))] }
    func runRefreshSweep() async -> [CheckupClaim] { [CheckupClaim(family: .refresh, id: "refresh.60", verdict: .observed("60 Hz achieved; macOS reports"))] }
    func restore() async -> Bool { true }
  }
  struct FakeHDR: CheckupHDRRunning {
    func run() async -> [CheckupClaim] { [CheckupClaim(family: .hdr, id: CheckupCheckID.hdrFlags, verdict: .observed("no flags"))] }
  }

  private func entry(_ cls: CheckupPanelClass = .readsDDC, only: Bool = false) -> CheckupDisplayEntry {
    CheckupDisplayEntry(id: 7, identityKey: "k1", name: "DELL", isBuiltIn: false, isVirtual: false,
                        panelClass: cls, pixelWidth: 3840, pixelHeight: 2160, isOnlyDisplay: only)
  }

  private func identity() -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(identityKey: "k1", vendorID: 1, modelID: 2, serial: "S", manufactureWeek: nil,
                           manufactureYear: nil, nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 60,
                           supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL")
  }

  private func environment(presenter: FakePresenter, entry: CheckupDisplayEntry, booked: @escaping (CheckupFieldKind, TimeInterval) -> Void = { _, _ in }) -> CheckupEnvironment {
    let identity = identity()
    return CheckupEnvironment(
      displays: [entry], macOSBuild: "b", appBuild: "3",
      runners: { _ in CheckupRunnerSet(identity: { identity }, capabilities: FakeCaps(), mode: FakeMode(), hdr: FakeHDR()) },
      presenter: presenter, bookShowing: { _, kind, s in booked(kind, s) },
      now: { Date(timeIntervalSinceReferenceDate: 800_000_000) },
      makeRNG: { SeededGenerator(seed: 1) })
  }

  /// Drives the flow from scenario to the first field instruction.
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
    let second = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: entry()))
    second.onSaved = { saved.append($0) }
    await second.advance()
    second.abandon(reason: "closed")
    #expect(saved.count == 2)
    #expect(saved.last?.report.completion == .incomplete(reason: "closed"))
  }

  @Test func theSelectedDisplayNeverIncludesVirtualOnes() {
    var v = entry(); v.isVirtual = true
    let flow = CheckupFlowModel(environment: environment(presenter: FakePresenter(), entry: v))
    #expect(flow.selectableDisplays.isEmpty)
  }
}
