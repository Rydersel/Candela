import CandelaKit
import CoreGraphics
import Foundation
import Observation

/// The checkup state machine (CK25). It owns the report under construction and
/// every verdict in it: the pages render what this says and decide nothing.
///
/// Two rules shape the whole type. Nothing but the user aborts a run (CK27), so
/// a refusal is recorded and the flow moves on, and both exits that are not the
/// summary still save a report. And the planted control is the only thing that
/// grades a person's attestations (CK21), so its detect, retry and miss states
/// live here rather than in any page.
@MainActor
@Observable
final class CheckupFlowModel {
  private(set) var page: CheckupPage = .scenario
  /// CK3: recorded on the report and shown in the flow; no check branches on it.
  var scenario: CheckupScenario = .newMonitor
  var selectedDisplay: CheckupDisplayEntry?
  private(set) var plan: [CheckupPlan.Step] = []
  private(set) var claims: [CheckupClaim] = []
  /// True while a hardware leg is in flight, so a page can say so.
  private(set) var running = false
  private(set) var secondsRemaining = 0
  private(set) var showings: [String: Int] = [:]
  private(set) var plantRecord: CheckupPlantRecord?
  private(set) var report: CheckupReport?
  private(set) var envelope: CheckupReportEnvelope?
  let environment: CheckupEnvironment

  /// The save seam: the pane's store in the app, a recorder in the suite.
  var onSaved: (CheckupReportEnvelope) -> Void = { _ in }

  /// The one field the control is planted on, and so the one that calibrates
  /// the sweep. Optional only because `first(where:)` is; the protocol order
  /// opens with black.
  static let plantedField = CheckupFieldKind.protocolOrder.first { $0.carriesPlant }
  /// CK21's two sizes. The first pass plants 4 px; a miss re-shows once at 8.
  static let firstPlantPixels = 4
  static let retryPlantPixels = 8
  /// A tap this many plant-widths from the control still counts as finding it:
  /// a person points at a region on glass, not at a pixel.
  static let plantNeighbourhoodInPlants = 3

  static let ungradedText = "planted control not detected at 4 or 8 px; attestation cannot be graded"
  static let noControlText = "nothing seen; ungraded, no control on this field"

  private var runners: CheckupRunnerSet?
  private var identity: CheckupDisplayIdentity?
  private var startedAt: Date?
  private var generator: AnyRandomNumberGenerator?
  /// The plant of the showing on screen, nil when the field carries none.
  private var plant: CheckupPlant?
  /// Chosen once and withheld (CK20). A re-show and the larger retry both put
  /// the control back in the same place.
  private var plantOrigin: (x: Int, y: Int)?
  private var plantSize = CheckupFlowModel.firstPlantPixels
  private var finished = false

  init(environment: CheckupEnvironment) {
    self.environment = environment
  }

  /// CK26: a virtual display is never a checkup target.
  var selectableDisplays: [CheckupDisplayEntry] {
    environment.displays.filter { !$0.isVirtual }
  }

  var canShowAgain: Bool {
    guard let kind = currentFieldKind else { return false }
    return showings[CheckupCheckID.field(kind), default: 0] < CheckupPlan.maxShowingsPerField
  }

  var answered: Bool {
    guard let kind = currentFieldKind else { return false }
    return claims.contains { $0.id == CheckupCheckID.field(kind) }
  }

  var currentPlantSize: Int { plantSize }

  /// The control's origin, for the suite only: no page may read it, which is
  /// the whole point of a withheld position.
  var plantRegionForTest: (x: Int, y: Int)? {
    plant.map { (x: $0.x, y: $0.y) }
  }

  // MARK: - The page machine

  func advance() async {
    guard !finished else { return }
    switch page {
    case .scenario:
      page = .displayPick

    case .displayPick:
      guard let display = selectedDisplay, !display.isVirtual else { return }
      begin(with: display)
      page = .plan

    case .plan:
      await runIdentity()
      page = .identity

    case .identity:
      await runCapabilities()
      page = .capabilities

    case .capabilities:
      running = true
      record(await runners?.mode.runNativeMode() ?? [])
      running = false
      page = .nativeMode

    case .nativeMode:
      running = true
      record(await runners?.mode.runRefreshSweep() ?? [])
      // The sweep is the last leg that moves the mode, so the display goes back
      // here. `restore()` reports the ACHIEVED mode, not that the apply returned.
      let restored = await runners?.mode.restore() ?? true
      running = false
      guard restored else {
        finish(.incomplete(reason: "the display could not be restored to its starting mode"))
        return
      }
      page = .refresh

    case .refresh:
      page = .witness

    case .witness:
      recordUnanswered(.witness)
      page = .plantDisclosure

    case .plantDisclosure:
      plantRecord = CheckupPlantRecord(disclosed: true, detectedAtPixels: nil, missed: false)
      if let first = CheckupFieldKind.protocolOrder.first { page = .fieldInstruction(first) }

    case .fieldInstruction(let kind):
      recordUnanswered(kind)
      await moveOn(after: kind)

    case .fieldShowing, .fieldConfirmSecondDot:
      // The field is on the panel: only an answer or the cap takes it down.
      break

    case .hdr:
      finish(.complete)

    case .summary:
      break
    }
  }

  func back() {
    guard !finished else { return }
    switch page {
    case .displayPick:
      page = .scenario
    case .plan:
      page = .displayPick
    // Everything from identity on has already touched the display or the
    // user's attestations; a step back there would rewrite a recorded claim.
    default:
      break
    }
  }

  private func begin(with display: CheckupDisplayEntry) {
    startedAt = environment.now()
    runners = environment.runners(display)
    plan = CheckupPlan.make(panelClass: display.panelClass)
    generator = AnyRandomNumberGenerator(base: environment.makeRNG())
    // CK5: what this panel class cannot answer is recorded before anything
    // runs, so the plan page and the report say the same thing.
    for step in plan {
      guard let pregraded = step.pregraded else { continue }
      record([CheckupClaim(family: step.family, id: step.id, verdict: pregraded)])
    }
  }

  private func moveOn(after kind: CheckupFieldKind) async {
    guard let index = CheckupFieldKind.protocolOrder.firstIndex(of: kind) else { return }
    let next = CheckupFieldKind.protocolOrder.index(after: index)
    guard next < CheckupFieldKind.protocolOrder.endIndex else {
      running = true
      record(await runners?.hdr.run() ?? [])
      running = false
      page = .hdr
      return
    }
    page = .fieldInstruction(CheckupFieldKind.protocolOrder[next])
  }

  // MARK: - The measured legs

  private func runIdentity() async {
    guard let runners else { return }
    running = true
    let found = await runners.identity()
    running = false
    identity = found
    guard let found else {
      record([CheckupClaim(family: .identity, id: CheckupCheckID.identity,
                           verdict: .notObserved("no EDID exposed"))])
      return
    }
    record([CheckupClaim(family: .identity, id: CheckupCheckID.identity,
                         verdict: .observed(Self.identityText(found)))])
  }

  static func identityText(_ identity: CheckupDisplayIdentity) -> String {
    let name = identity.productName.isEmpty ? "no product name reported" : identity.productName
    var text = "as reported by the display's EDID: \(name), serial \(identity.serial)"
    if let week = identity.manufactureWeek, let year = identity.manufactureYear {
      text += ", week \(week) of \(year)"
    }
    return text
  }

  private func runCapabilities() async {
    guard let runners else { return }
    let steps = plan.filter { $0.family == .capabilities }
    // A class that cannot answer is already recorded from the plan; running the
    // leg anyway would write an observation over a pre-graded row.
    guard steps.contains(where: { $0.pregraded == nil }) else { return }
    running = true
    record(await runners.capabilities.run())
    running = false
  }

  // MARK: - Showings

  func startShowing() {
    guard let display = selectedDisplay, let kind = instructionFieldKind else { return }
    show(kind: kind, plant: plantForShowing(kind), on: display)
    page = .fieldShowing(kind)
  }

  /// CK17: the user asks for a repeat, never the flow.
  func showAgain() {
    guard canShowAgain else { return }
    startShowing()
  }

  func timeoutTick() {
    guard let kind = showingFieldKind, secondsRemaining > 0 else { return }
    secondsRemaining -= 1
    guard secondsRemaining == 0 else { return }
    // A cap that ran out is a full showing of light, so it books the full cap;
    // the field itself stays unanswered until the user says something.
    endShowing(kind: kind, elapsed: kind.capSeconds)
    page = instructionPage(for: kind)
  }

  private func show(kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry) {
    showings[CheckupCheckID.field(kind), default: 0] += 1
    self.plant = plant
    environment.presenter.show(kind: kind, plant: plant, on: display)
    secondsRemaining = kind.capSeconds
  }

  private func endShowing(kind: CheckupFieldKind, elapsed: Int) {
    environment.presenter.hide()
    secondsRemaining = 0
    guard let display = selectedDisplay else { return }
    environment.bookShowing(display.identityKey, kind, TimeInterval(elapsed))
  }

  /// The control rides the FIRST pixel field alone: CK20 discloses a single
  /// mark, and one calibration is what the later pixel fields are read at. Once
  /// it has been found or missed it stops appearing, so a re-show of that field
  /// never asks a person to report the same control twice.
  private func plantForShowing(_ kind: CheckupFieldKind) -> CheckupPlant? {
    guard kind == Self.plantedField, let display = selectedDisplay,
      plantRecord?.detectedAtPixels == nil, plantRecord?.missed != true
    else { return nil }
    if plantOrigin == nil, var generator {
      let position = CheckupField.plantPosition(
        width: display.pixelWidth, height: display.pixelHeight, size: plantSize, using: &generator)
      self.generator = generator
      plantOrigin = (x: position.x, y: position.y)
    }
    guard let plantOrigin else { return nil }
    return CheckupPlant(x: plantOrigin.x, y: plantOrigin.y, size: plantSize)
  }

  // MARK: - Answers

  func answer(_ answer: CheckupFieldAnswer, tappedRegion: (x: Int, y: Int)?) {
    switch page {
    case .fieldShowing(let kind):
      let shown = plant
      endShowing(kind: kind, elapsed: max(1, kind.capSeconds - secondsRemaining))
      if kind == .witness {
        answerWitness(answer)
        return
      }
      answerField(kind: kind, plant: shown, answer: answer, tappedRegion: tappedRegion)

    case .fieldConfirmSecondDot(let kind):
      endShowing(kind: kind, elapsed: max(1, kind.capSeconds - secondsRemaining))
      answerSecondDot(kind: kind, answer: answer, tappedRegion: tappedRegion)
      page = instructionPage(for: kind)

    default:
      break
    }
  }

  /// CK19. "Round and uncut" is the only thing in the whole checkup that
  /// upgrades a claim past "macOS reports", and it upgrades only what was
  /// observed: there is nothing on glass to witness about a refusal.
  private func answerWitness(_ answer: CheckupFieldAnswer) {
    switch answer {
    case .roundAndUncut:
      recordField(.witness, verdict: .selfReported("round and uncut, as seen on glass"))
      for (index, claim) in claims.enumerated()
      where claim.family == .nativeMode || claim.family == .refresh {
        guard case .observed(let text) = claim.verdict else { continue }
        claims[index] = CheckupClaim(
          family: claim.family, id: claim.id,
          verdict: .observed(text + "; human-witnessed geometry on glass"),
          detectedAt: claim.detectedAt)
      }
      page = .plantDisclosure
    case .notRound:
      recordField(.witness, verdict: .selfReported("witness card not round or cut"))
      page = .plantDisclosure
    case .nothing, .oneMark, .moreThanOne:
      // Not this card's answers; the card is simply down again, unanswered.
      page = .witness
    }
  }

  private func answerField(
    kind: CheckupFieldKind, plant: CheckupPlant?, answer: CheckupFieldAnswer,
    tappedRegion: (x: Int, y: Int)?
  ) {
    // CK21: with the control missed, nothing on the pixel sweep can be graded,
    // and a report must not print an attestation as if it could be.
    if kind.carriesPlant, plantRecord?.missed == true {
      recordField(kind, verdict: .inconclusive(Self.ungradedText))
      page = instructionPage(for: kind)
      return
    }
    switch answer {
    case .moreThanOne:
      // A mark at the control still found the control, even alongside another.
      if let plant, let tappedRegion, Self.isInside(tappedRegion, plant) { detect(plant) }
      // CK22: the same field again with no control on it, so a mark the user
      // still sees is the display's own.
      if let display = selectedDisplay { show(kind: kind, plant: nil, on: display) }
      page = .fieldConfirmSecondDot(kind)
      return

    case .oneMark:
      if let plant, let tappedRegion, Self.isInside(tappedRegion, plant) {
        detect(plant)
        recordField(kind, verdict: .selfReported("one mark, at the planted control"))
      } else if plant != nil {
        // The one mark they saw was not the control, so the control went unseen.
        missed(kind: kind)
        return
      } else {
        recordField(kind, verdict: .selfReported(Self.defectText(tappedRegion)))
      }

    case .nothing:
      if plant != nil {
        missed(kind: kind)
        return
      }
      recordField(
        kind,
        verdict: .selfReported(kind.carriesPlant ? "nothing seen" : Self.noControlText))

    case .roundAndUncut, .notRound:
      // The witness card's answers; a field never offers them.
      break
    }
    page = instructionPage(for: kind)
  }

  private func answerSecondDot(
    kind: CheckupFieldKind, answer: CheckupFieldAnswer, tappedRegion: (x: Int, y: Int)?
  ) {
    switch answer {
    case .nothing:
      recordField(kind, verdict: .selfReported("a second mark was not confirmed"))
    case .oneMark, .moreThanOne:
      recordField(kind, verdict: .selfReported(Self.defectText(tappedRegion)))
    case .roundAndUncut, .notRound:
      break
    }
  }

  static func defectText(_ region: (x: Int, y: Int)?) -> String {
    guard let region else { return "a mark was reported, with no region given" }
    return "defect reported at \(region.x),\(region.y) px"
  }

  private func detect(_ plant: CheckupPlant) {
    guard plantRecord?.detectedAtPixels == nil else { return }
    plantRecord = CheckupPlantRecord(disclosed: true, detectedAtPixels: plant.size, missed: false)
  }

  /// CK21's miss: one larger retry on the same field, then the sweep is
  /// ungraded. The copy frames both as a fact about resolution, never a failure.
  private func missed(kind: CheckupFieldKind) {
    if plantSize < Self.retryPlantPixels {
      plantSize = Self.retryPlantPixels
      page = instructionPage(for: kind)
      return
    }
    plantRecord = CheckupPlantRecord(disclosed: true, detectedAtPixels: nil, missed: true)
    recordField(kind, verdict: .inconclusive(Self.ungradedText))
    page = instructionPage(for: kind)
  }

  static func isInside(_ region: (x: Int, y: Int), _ plant: CheckupPlant) -> Bool {
    let reach = plant.size * plantNeighbourhoodInPlants
    return abs(region.x - plant.x) <= reach && abs(region.y - plant.y) <= reach
  }

  // MARK: - Exits

  func abandon(reason: String) {
    endRun(reason: reason)
  }

  func displayDisconnected(_ id: CGDirectDisplayID) {
    guard let display = selectedDisplay, display.id == id else { return }
    endRun(reason: "the display disconnected during \(page.name)")
  }

  private func endRun(reason: String) {
    guard !finished else { return }
    environment.presenter.hide()
    secondsRemaining = 0
    if let mode = runners?.mode {
      // CK27: the mode goes back on every exit path. Its outcome cannot change
      // a completion the user or the cable already decided, so it is not awaited.
      Task { _ = await mode.restore() }
    }
    finish(.incomplete(reason: reason))
  }

  private func finish(_ completion: CheckupCompletion) {
    guard !finished else { return }
    finished = true
    let started = startedAt ?? environment.now()
    let report = CheckupReport(
      scenario: scenario,
      identity: identity ?? Self.unreadIdentity(for: selectedDisplay),
      panelClass: selectedDisplay?.panelClass ?? .noDDC,
      macOSBuild: environment.macOSBuild, appBuild: environment.appBuild,
      startedAt: started, endedAt: environment.now(), completion: completion,
      claims: claims, plant: plantRecord, showings: showings,
      exposureBookingID: CheckupExposureBooking.id(startedAt: started))
    self.report = report
    page = .summary
    // The report stands either way; only a hashed envelope can be saved (CK7).
    guard let envelope = try? CheckupReportEnvelope(report: report) else { return }
    self.envelope = envelope
    onSaved(envelope)
  }

  /// A run that ended before the identity leg has no EDID record, and the
  /// report needs one. Everything here is what the flow already knew about the
  /// display; nothing in it is presented as something the panel reported.
  private static func unreadIdentity(for display: CheckupDisplayEntry?) -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(
      identityKey: display?.identityKey ?? "", vendorID: 0, modelID: 0, serial: nil,
      manufactureWeek: nil, manufactureYear: nil,
      nativePixelWidth: display?.pixelWidth ?? 0, nativePixelHeight: display?.pixelHeight ?? 0,
      maxRefreshHz: nil, supportsPQEOTF: false, supportsHDRGammaEOTF: false,
      productName: display?.name ?? "")
  }

  // MARK: - Claims and page helpers

  /// Replaces the claim with the same id rather than appending: a field the
  /// user answers twice has one claim, its last answer.
  private func record(_ incoming: [CheckupClaim]) {
    for claim in incoming {
      if let index = claims.firstIndex(where: { $0.id == claim.id }) {
        claims[index] = claim
      } else {
        claims.append(claim)
      }
    }
  }

  private func recordField(_ kind: CheckupFieldKind, verdict: CheckupVerdict) {
    record([
      CheckupClaim(
        family: .visualField, id: CheckupCheckID.field(kind), verdict: verdict,
        // The size the control was seen at is what a pixel field's attestation
        // is read at; a field with no control borrows none of that sensitivity.
        detectedAt: kind.carriesPlant ? plantRecord?.detectedAtPixels : nil)
    ])
  }

  private func recordUnanswered(_ kind: CheckupFieldKind) {
    guard !claims.contains(where: { $0.id == CheckupCheckID.field(kind) }) else { return }
    recordField(kind, verdict: .selfReported("no answer given"))
  }

  private func instructionPage(for kind: CheckupFieldKind) -> CheckupPage {
    kind == .witness ? .witness : .fieldInstruction(kind)
  }

  private var currentFieldKind: CheckupFieldKind? {
    switch page {
    case .witness: .witness
    case .fieldInstruction(let kind), .fieldShowing(let kind), .fieldConfirmSecondDot(let kind): kind
    default: nil
    }
  }

  private var instructionFieldKind: CheckupFieldKind? {
    switch page {
    case .witness: .witness
    case .fieldInstruction(let kind): kind
    default: nil
    }
  }

  private var showingFieldKind: CheckupFieldKind? {
    switch page {
    case .fieldShowing(let kind), .fieldConfirmSecondDot(let kind): kind
    default: nil
    }
  }
}
