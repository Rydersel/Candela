import CandelaKit
import CoreGraphics
import Foundation
import Observation

/// The checkup state machine (CK25): owns the report under construction and
/// every verdict in it; the pages render and decide nothing. Nothing but the
/// user aborts a run (CK27), so refusals are recorded and both early exits
/// still save a report. A run that has ended stays ended, so a leg still in
/// flight cannot write into a saved report. The planted control alone grades
/// attestations (CK21), so its states live here.
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
  /// CK16: fields whose lower edge carried the instruction strip. Recorded on
  /// the report, since a reader cannot otherwise tell they were not the whole panel.
  private(set) var partiallyOccludedFields: [String] = []
  /// Why the last showing never reached the glass, nil once one does. The
  /// instruction page says so rather than leaving a dead Start button.
  private(set) var showFailureReason: String?
  private(set) var plantRecord: CheckupPlantRecord?
  private(set) var report: CheckupReport?
  private(set) var envelope: CheckupReportEnvelope?
  let environment: CheckupEnvironment

  /// The save seam: the pane's store in the app, a recorder in the suite.
  var onSaved: (CheckupReportEnvelope) -> Void = { _ in }

  /// The one field the control is planted on. Optional only because `first(where:)` is.
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
  /// Fields whose one confirmation re-show (CK22) has been spent.
  private var secondDotShown: Set<String> = []
  /// The leg being awaited, which is what a disconnect happened DURING; `page`
  /// is still the page the run left, and would name the wrong step.
  private var legInFlight: CheckupPage?
  private var finished = false

  init(environment: CheckupEnvironment) {
    self.environment = environment
  }

  /// CK26: a virtual display is never a checkup target, and neither is one
  /// mirroring another, which has no screen of its own to draw a field on.
  var selectableDisplays: [CheckupDisplayEntry] {
    environment.displays.filter { !$0.isVirtual && !$0.isMirroring }
  }

  var canShowAgain: Bool {
    guard let kind = currentFieldKind else { return false }
    return cappedShowings(of: kind) < CheckupPlan.maxShowingsPerField
  }

  var answered: Bool {
    guard let kind = currentFieldKind else { return false }
    return claims.contains { $0.id == CheckupCheckID.field(kind) }
  }

  var currentPlantSize: Int { plantSize }

  #if DEBUG
    /// Suite only: a page reading this would hand back the position CK20 withholds.
    var plantRegionForTest: (x: Int, y: Int)? {
      plant.map { (x: $0.x, y: $0.y) }
    }
  #endif

  // MARK: - The page machine

  func advance() async {
    // A leg already in flight owns the page it will move to; a second advance
    // would run the next one over it and record both against the wrong step.
    guard !finished, legInFlight == nil else { return }
    // Advancing past the page it appeared on dismisses it.
    showFailureReason = nil
    switch page {
    case .scenario:
      page = .displayPick

    case .displayPick:
      guard let display = selectedDisplay, !display.isVirtual, !display.isMirroring else { return }
      begin(with: display)
      page = .plan

    case .plan:
      legInFlight = .identity
      await runIdentity()
      guard !finished else { return }
      legInFlight = nil
      page = .identity

    case .identity:
      legInFlight = .capabilities
      await runCapabilities()
      guard !finished else { return }
      legInFlight = nil
      page = .capabilities

    case .capabilities:
      legInFlight = .nativeMode
      running = true
      let native = await runners?.mode.runNativeMode() ?? []
      guard !finished else { return }
      record(native)
      running = false
      legInFlight = nil
      page = .nativeMode

    case .nativeMode:
      legInFlight = .refresh
      running = true
      let sweep = await runners?.mode.runRefreshSweep() ?? []
      guard !finished else { return }
      record(sweep)
      // The sweep is the last leg that moves the mode, so the display goes back
      // here. `restore()` reports the ACHIEVED mode, not that the apply returned.
      let restored = await runners?.mode.restore() ?? true
      guard !finished else { return }
      running = false
      legInFlight = nil
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
      // Last chance to resolve the control; unresolved means not detected (CK21),
      // or a timed-out showing would grade the sweep as if it had been found.
      if kind == Self.plantedField, let record = plantRecord,
        record.detectedAtPixels == nil, !record.missed {
        markControlMissed()
      }
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
    plan = CheckupPlan.make(panelClass: display.panelClass, hdrEngaged: display.hdrEngaged)
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
      legInFlight = .hdr
      running = true
      let hdr = await runners?.hdr.run() ?? []
      guard !finished else { return }
      record(hdr)
      running = false
      legInFlight = nil
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
    guard !finished else { return }
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
    let capabilities = await runners.capabilities.run()
    guard !finished else { return }
    record(capabilities)
    running = false
  }

  // MARK: - Showings

  func startShowing() {
    guard let display = selectedDisplay, let kind = instructionFieldKind else { return }
    // A call past the cap leaves the page where it is, with `canShowAgain`
    // already false: the bound lives here, not in whichever button called.
    guard show(kind: kind, plant: plantForShowing(kind), on: display) else { return }
    page = .fieldShowing(kind)
  }

  /// CK17: the user asks for a repeat, never the flow.
  func showAgain() {
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

  /// CK17's cap, enforced where every showing passes. The confirmation re-show
  /// is exempt and uncounted, so a field tops out at four showings.
  @discardableResult
  private func show(
    kind: CheckupFieldKind, plant: CheckupPlant?, on display: CheckupDisplayEntry,
    confirmation: Bool = false
  ) -> Bool {
    guard confirmation || cappedShowings(of: kind) < CheckupPlan.maxShowingsPerField else {
      return false
    }
    // Nothing is recorded until the presenter confirms the field is on screen:
    // a counted showing books emission and grades an attestation.
    guard environment.presenter.show(kind: kind, plant: plant, on: display) else {
      showFailureReason = CheckupCopy.fieldNotShown
      return false
    }
    showFailureReason = nil
    let id = CheckupCheckID.field(kind)
    showings[id, default: 0] += 1
    if display.isOnlyDisplay, !partiallyOccludedFields.contains(id) {
      partiallyOccludedFields.append(id)
    }
    self.plant = plant
    secondsRemaining = kind.capSeconds
    return true
  }

  private func endShowing(kind: CheckupFieldKind, elapsed: Int) {
    environment.presenter.hide()
    secondsRemaining = 0
    guard let display = selectedDisplay else { return }
    environment.bookShowing(display.identityKey, kind, TimeInterval(elapsed))
  }

  private func cappedShowings(of kind: CheckupFieldKind) -> Int {
    let id = CheckupCheckID.field(kind)
    return showings[id, default: 0] - (secondDotShown.contains(id) ? 1 : 0)
  }

  /// The control rides the first pixel field alone (CK20 discloses one mark).
  /// Once found or missed it stops appearing, so a re-show never asks about it twice.
  private func plantForShowing(_ kind: CheckupFieldKind) -> CheckupPlant? {
    guard kind == Self.plantedField, let display = selectedDisplay,
      plantRecord?.detectedAtPixels == nil, plantRecord?.missed != true
    else { return nil }
    if plantOrigin == nil, var generator {
      let position = CheckupField.plantPosition(
        width: display.pixelWidth, height: display.pixelHeight, size: plantSize,
        bottomExclusion: Self.stripBandPixels(on: display), using: &generator)
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
      endShowing(kind: kind, elapsed: elapsedSeconds(of: kind))
      if kind == .witness {
        answerWitness(answer)
        return
      }
      answerField(kind: kind, plant: shown, answer: answer, tappedRegion: tappedRegion)

    case .fieldConfirmSecondDot(let kind):
      endShowing(kind: kind, elapsed: elapsedSeconds(of: kind))
      answerSecondDot(kind: kind, answer: answer, tappedRegion: tappedRegion)
      page = instructionPage(for: kind)

    default:
      break
    }
  }

  /// Never zero: a field that was on the panel at all emitted light.
  private func elapsedSeconds(of kind: CheckupFieldKind) -> Int {
    max(1, kind.capSeconds - secondsRemaining)
  }

  /// CK19: "round and uncut" is the only answer that upgrades a claim past
  /// "macOS reports", and only an observed one; a refusal has nothing on glass.
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
    case .roundAndUncut, .notRound:
      // The witness card's answers; a field never offers them, and neither
      // credits nor misses the control.
      page = instructionPage(for: kind)
      return
    default:
      break
    }
    // Only a mark at the control credits it; anything else is a miss at the
    // planted size, whatever the answer said (CK21).
    let credited: Bool = {
      guard answer != .nothing, let plant, let tappedRegion else { return false }
      return Self.isInside(tappedRegion, plant)
    }()
    if let plant {
      if credited { detect(plant) } else { registerMiss() }
    }

    switch answer {
    case .moreThanOne:
      // CK22: the same field again with no control on it, so a mark the user
      // still sees is the display's own. One confirmation per field.
      if kind.carriesPlant, !secondDotShown.contains(CheckupCheckID.field(kind)),
        let display = selectedDisplay {
        secondDotShown.insert(CheckupCheckID.field(kind))
        show(kind: kind, plant: nil, on: display, confirmation: true)
        page = .fieldConfirmSecondDot(kind)
        return
      }
      recordField(kind, verdict: gradedVerdict(kind, .selfReported(Self.defectText(tappedRegion))))

    case .oneMark:
      if plant != nil, credited {
        recordField(kind, verdict: .selfReported("one mark, at the planted control"))
      } else if plant != nil {
        // The one mark they saw was not the control, so the control went unseen
        // and the miss above is the whole of what this showing established.
        recordField(kind, verdict: gradedVerdict(kind, .selfReported(Self.defectText(tappedRegion))))
      } else {
        recordField(kind, verdict: .selfReported(Self.defectText(tappedRegion)))
      }

    case .nothing:
      if plant != nil {
        // A missed control is not an attestation about the panel: the retry or
        // the miss recorded above is what this showing said.
        page = instructionPage(for: kind)
        return
      }
      recordField(
        kind,
        verdict: .selfReported(kind.carriesPlant ? "nothing seen" : Self.noControlText))

    case .roundAndUncut, .notRound:
      break
    }
    page = instructionPage(for: kind)
  }

  private func answerSecondDot(
    kind: CheckupFieldKind, answer: CheckupFieldAnswer, tappedRegion: (x: Int, y: Int)?
  ) {
    switch answer {
    case .nothing:
      recordField(kind, verdict: gradedVerdict(kind, .selfReported("a second mark was not confirmed")))
    case .oneMark, .moreThanOne:
      recordField(kind, verdict: gradedVerdict(kind, .selfReported(Self.defectText(tappedRegion))))
    case .roundAndUncut, .notRound:
      break
    }
  }

  /// A pixel field's attestation only means something at a known sensitivity;
  /// with the control missed it is inconclusive whatever the user reported.
  private func gradedVerdict(_ kind: CheckupFieldKind, _ verdict: CheckupVerdict) -> CheckupVerdict {
    kind.carriesPlant && plantRecord?.missed == true ? .inconclusive(Self.ungradedText) : verdict
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
  private func registerMiss() {
    guard plantRecord?.missed != true else { return }
    if plantSize < Self.retryPlantPixels {
      plantSize = Self.retryPlantPixels
      return
    }
    markControlMissed()
  }

  private func markControlMissed() {
    plantRecord = CheckupPlantRecord(disclosed: true, detectedAtPixels: nil, missed: true)
    guard let planted = Self.plantedField else { return }
    recordField(planted, verdict: .inconclusive(Self.ungradedText))
  }

  /// The instruction strip's height in field pixels; zero when the instructions
  /// live elsewhere. A plant under the strip is a miss the person could not have avoided.
  static func stripBandPixels(on display: CheckupDisplayEntry) -> Int {
    guard display.isOnlyDisplay, display.pointHeight > 0 else { return 0 }
    return Int(
      Double(CheckupFieldWindow.stripHeight) * Double(display.pixelHeight) / display.pointHeight)
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
    endRun(reason: "the display disconnected during \((legInFlight ?? page).name)")
  }

  private func endRun(reason: String) {
    guard !finished else { return }
    // A field on the panel is light that was emitted, so it books on the way
    // out exactly once (CK17); anything else just makes sure nothing is left up.
    if let kind = showingFieldKind {
      endShowing(kind: kind, elapsed: elapsedSeconds(of: kind))
    } else {
      environment.presenter.hide()
      secondsRemaining = 0
    }
    running = false
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
      exposureBookingID: CheckupExposureBooking.id(startedAt: started),
      partiallyOccludedFields: partiallyOccludedFields)
    self.report = report
    page = .summary
    // The report stands either way; only a hashed envelope can be saved (CK7).
    guard let envelope = try? CheckupReportEnvelope(report: report) else { return }
    self.envelope = envelope
    // With no display picked there is no identity to file under, and an empty
    // key writes the run into the store's root instead of a display's folder.
    guard selectedDisplay != nil else { return }
    onSaved(envelope)
  }

  /// For a run that ended before the identity leg. Nothing here is presented as
  /// something the panel reported.
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
    recordField(kind, verdict: gradedVerdict(kind, .selfReported("no answer given")))
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
