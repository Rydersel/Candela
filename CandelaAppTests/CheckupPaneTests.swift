import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// The document is what a person forwards to a seller and the pane is where a
/// verdict would creep in, so both are read here rather than by eye.
@Suite("Checkup pane copy and summary text")
struct CheckupPaneTests {
  @Test func theSummaryTextOpensWithTheHeaderSentenceAndGroupsByFamily() throws {
    let report = CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(identityKey: "k", vendorID: 1, modelID: 2, serial: nil, manufactureWeek: 51,
        manufactureYear: 2025, nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 120,
        supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE"),
      panelClass: .readsDDC, macOSBuild: "b", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), endedAt: nil, completion: .complete,
      claims: [
        CheckupClaim(family: .identity, id: CheckupCheckID.identity, verdict: .observed("EDID parsed")),
        CheckupClaim(family: .visualField, id: "field.black", verdict: .selfReported("nothing seen"), detectedAt: 4),
      ],
      plant: CheckupPlantRecord(disclosed: true, detectedAtPixels: 4, missed: false), showings: ["field.black": 1], exposureBookingID: nil,
      partiallyOccludedFields: [CheckupCheckID.field(.black)])
    let text = CheckupSummaryText.render(report)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.first == CheckupReport.headerSentence)
    #expect(text.contains("DELL U2725QE"))
    #expect(text.contains("no serial reported"))
    #expect(text.contains("Identity"))
    #expect(text.contains("Visual fields"))
    #expect(text.contains("self-reported: nothing seen (control detected at 4 px)"))
    // What a reader of the file needs that a reader of the screen gets from the room.
    #expect(text.contains(CheckupCopy.attestationNote))
    #expect(text.contains("instruction strip over their lower edge: black."))
    #expect(lines.last == CheckupCopy.completionLine(.complete))
    #expect(text.contains("Completion: complete."))
    #expect(!text.contains("—"))
  }

  /// A run abandoned before the identity leg carries a placeholder
  /// identity, and printing it would report a serial and flags nothing read.
  @Test func aRunThatDidNotReadTheEDIDClaimsNothingFromIt() {
    let text = CheckupSummaryText.render(
      report(
        identityVerdict: .notObserved("no EDID exposed"), serial: nil, nativeWidth: 0,
        nativeHeight: 0, maxRefreshHz: nil))
    #expect(!text.contains("Serial:"))
    #expect(!text.contains("HDR flags"))
    #expect(!text.contains("0 by 0"))
    #expect(!text.contains("Manufactured:"))
    #expect(!text.contains("Maximum refresh:"))
    #expect(text.contains(CheckupCopy.identityNotRead))
    // The claim itself still stands, with its own reason.
    #expect(text.contains("not observed: no EDID exposed"))
    // Facts about the run rather than about the display, so they survive.
    #expect(text.contains("macOS: 26.0"))
  }

  /// A zero size is a placeholder that survived the read, not a panel that
  /// measures zero.
  @Test func aZeroNativeSizeReadsAsNotReported() {
    let text = CheckupSummaryText.render(
      report(identityVerdict: .observed("EDID parsed"), nativeWidth: 0, nativeHeight: 0))
    #expect(text.contains("Native resolution: not reported"))
    #expect(!text.contains("0 by 0"))
  }

  /// The built-in leads `allControlledStates`, so "first display" would hide a
  /// fresh external's run behind the picker.
  @Test func theHistoryOpensOnTheDisplayThatRanMostRecently() {
    let older = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let newer = Date(timeIntervalSinceReferenceDate: 800_000_000)
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: older),
        (key: "ext", isBuiltIn: false, latestRun: newer),
      ]) == "ext")
    // The newest run wins on its date, not on where its display sits.
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: newer),
        (key: "ext", isBuiltIn: false, latestRun: older),
      ]) == "builtIn")
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: nil),
        (key: "ext", isBuiltIn: false, latestRun: older),
      ]) == "ext")
    // Nothing stored anywhere: the first external, which is the display a
    // person just plugged in and came here about.
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: nil),
        (key: "a", isBuiltIn: false, latestRun: nil),
        (key: "b", isBuiltIn: false, latestRun: nil),
      ]) == "a")
    #expect(
      CheckupHistoryScope.defaultKey([(key: "builtIn", isBuiltIn: true, latestRun: nil)])
        == "builtIn")
    #expect(CheckupHistoryScope.defaultKey([]) == nil)
  }

  /// The predicate only: the branch that reads it sits in an `.onChange` in
  /// `body` with no seam a host-free test can reach, so a swap at the call site
  /// goes unnoticed here.
  @Test func theEveryDisplaySweepPredicateIsFalseOnceTheScopeWasPickedByHand() {
    #expect(CheckupHistoryScope.needsEveryDisplay(chosenByHand: false))
    #expect(!CheckupHistoryScope.needsEveryDisplay(chosenByHand: true))
  }

  private func report(
    identityVerdict: CheckupVerdict, serial: String? = nil, nativeWidth: Int = 3840,
    nativeHeight: Int = 2160, maxRefreshHz: Double? = 120
  ) -> CheckupReport {
    CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(
        identityKey: "k", vendorID: 0, modelID: 0, serial: serial, manufactureWeek: nil,
        manufactureYear: nil, nativePixelWidth: nativeWidth, nativePixelHeight: nativeHeight,
        maxRefreshHz: maxRefreshHz, supportsPQEOTF: false, supportsHDRGammaEOTF: false,
        productName: "MAG 341C OLED"),
      panelClass: .writeOnlyDDC, macOSBuild: "26.0", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), endedAt: nil,
      completion: .incomplete(reason: CheckupCopy.closedReason),
      claims: [CheckupClaim(family: .identity, id: CheckupCheckID.identity, verdict: identityVerdict)],
      plant: nil, showings: [:], exposureBookingID: nil)
  }

  @Test func aWriteOnlyGradeFromAnOlderVersionIsExplainedInTheDocument() {
    var stale = report(identityVerdict: .observed("EDID parsed"))
    stale.appBuild = "1.0.0 (4)"
    let text = CheckupSummaryText.render(stale)
    #expect(text.contains(CheckupCopy.panelClassLine(.writeOnlyDDC, hdrEngaged: false)))
    #expect(text.contains(CheckupCopy.panelClassMayBeMisreadNote))
    #expect(!text.contains("—"))

    var current = stale
    current.appBuild = CheckupReport.correctedReadPathVersion
    #expect(!CheckupSummaryText.render(current).contains(CheckupCopy.panelClassMayBeMisreadNote))
  }

  @Test func thePaneNamesTheRunButtonAndNeverAVerdict() {
    #expect(CheckupPaneCopy.run == "Run a checkup")
    #expect(CheckupPaneCopy.verify == "Verify a report")
    #expect(!CheckupPaneCopy.emptyHistory.lowercased().contains("pass"))
  }

  /// Two verifiers share one section, so their titles have to be tellable apart.
  @Test func theVerifySectionNamesItsTwoFilesApart() {
    #expect(CheckupPaneCopy.verify != ProvenanceCopy.check)
    #expect(ProvenanceCopy.check.lowercased().contains("provenance"))
    #expect(!CheckupPaneCopy.verify.lowercased().contains("provenance"))
    // Each answer names the kind of file it is about, so a reader who ran the
    // wrong button can see which one answered.
    #expect(CheckupPaneCopy.valid.contains("report"))
    #expect(ProvenanceCopy.intact.contains("record"))
  }

  /// The sentence is the whole reason the delete dialog runs to two paragraphs,
  /// so it is asserted rather than trusted to survive the next copy edit.
  @Test func theDeleteMessageNamesTheProvenanceHashAndSuggestsExportingFirst() {
    let message = CheckupPaneCopy.deleteMessage(
      for: report(identityVerdict: .observed("EDID parsed")))
    // "hash" and not "checksum": every other string on this pane about this one
    // value says hash, and ProvenanceCopy.checkNote says it on the same screen.
    #expect(message.contains("hash"))
    #expect(message.contains("export it first"))
  }

  /// Every row's button reads "Delete…" and the title cannot name the run, so
  /// the message's first line and the spoken label are the only places that can.
  @Test func theDeleteDialogAndItsButtonNameTheRun() {
    let subject = report(identityVerdict: .observed("EDID parsed"))
    let line = CheckupCopy.subjectLine(for: subject)
    let message = CheckupPaneCopy.deleteMessage(for: subject)
    #expect(message.split(separator: "\n").first.map(String.init) == line)
    // The control: the consequences still follow it, so leading with the run
    // did not displace what the dialog is for.
    #expect(message.contains(CheckupPaneCopy.deleteConsequences))
    #expect(CheckupPaneCopy.deleteRunLabel(for: subject).contains(line))
    #expect(CheckupPaneCopy.deleteRunLabel(for: subject) != CheckupPaneCopy.deleteRun)
  }

  @Test @MainActor func aRefusedDeleteReportsItsErrorAndCanBeRetried() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("checkup-delete-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CheckupStore(directory: directory)
    let envelope = try CheckupReportEnvelope(report: report(identityVerdict: .observed("EDID parsed")))
    let url = try store.save(envelope)
    let run = try #require(store.list(identityKey: "k").first)
    let folder = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    let message = CheckupPane.delete(run, from: store)
    #expect(message?.isEmpty == false)
    #expect(try store.load(url: url) == envelope)
    #expect(try store.list(identityKey: "k").map(\.url) == [url])

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    #expect(CheckupPane.delete(run, from: store) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try store.list(identityKey: "k").isEmpty)
  }

  /// No "this app" in user copy: the product has a name, and each display has a
  /// page under it.
  @Test func theRestoreNoticeNamesTheProductAndTheDisplaysOwnPage() {
    #expect(!CheckupPaneCopy.restoreNotAchieved.contains("this app"))
    #expect(CheckupPaneCopy.restoreNotAchieved.contains(AppInfo.productName))
    // Both ways back, which is what keeps a stranger off a changed screen.
    #expect(CheckupPaneCopy.restoreNotAchieved.contains("System Settings"))
  }

  /// The notice is app-global and names no display, while the pane is scoped to
  /// one, so it belongs to exactly one scope.
  @Test @MainActor func aRestoreNoticeBelongsToTheDisplayTheRunMoved() {
    let notice = CheckupRestoreNotice(
      text: CheckupPaneCopy.restoreNotAchieved, identityKey: "ran-here")
    #expect(CheckupPane.showsRestoreNotice(notice, scopedKey: "ran-here"))
    #expect(!CheckupPane.showsRestoreNotice(notice, scopedKey: "another-display"))
    #expect(!CheckupPane.showsRestoreNotice(notice, scopedKey: nil))
    #expect(!CheckupPane.showsRestoreNotice(nil, scopedKey: "ran-here"))
  }

  /// The no-verdict rule over the whole pane: nothing hands the display a result.
  @Test func noPaneCopyCarriesAnEmDashOrAVerdictOnTheDisplay() {
    for sentence in CheckupPaneCopy.allStringsForTest {
      let lowered = sentence.lowercased()
      #expect(!sentence.contains("—"), "\(sentence)")
      #expect(!lowered.contains("passed"), "\(sentence)")
      #expect(!lowered.contains("failed"), "\(sentence)")
      #expect(!lowered.contains("grade"), "\(sentence)")
      #expect(!lowered.contains("score"), "\(sentence)")
    }
  }

  /// Layer 2: build the pane over a directory that does not exist and
  /// assert only that pixels came out. Never `CheckupStore.defaultDirectory()`,
  /// or the test reads this machine's own history.
  @Test @MainActor func thePaneRendersWithNoStoredRuns() {
    let model = TestFixtures.appModel()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("checkup-pane-\(UUID().uuidString)", isDirectory: true)
    let pane = CheckupPane(directory: directory)
      .environment(model)
      .environment(SettingsActions(model: model))
      .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .checkup).accent)
      .frame(width: SettingsTheme.pageWidth + 64, height: 560)
    let image = ImageRenderer(content: pane).cgImage
    #expect(image != nil)
    #expect((image?.width ?? 0) > 20)
    #expect((image?.height ?? 0) > 20)
  }

  /// Reachability, which no model-level test can assert: a failed restore is
  /// published after the run's own window has gone, so what proves it reaches a
  /// person is the tree this pane publishes with that state set.
  ///
  /// A walk and not a render: `ImageRenderer` draws a `ScrollView` as an empty
  /// rectangle [measured 2026-09-10, a plain `Text` rendering 75 distinct byte
  /// values against this pane's 1], and every settings page is one, so a pixel
  /// comparison could not fail.
  @Test @MainActor func theRestoreNoticeReachesThePaneOnlyWhenThereIsOneToShow() async throws {
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery([
      (id: 424_244, key: "checkup-notice-fixture", name: "Checkup Notice Fixture"),
    ]))
    await model.refresh()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("checkup-notice-\(UUID().uuidString)", isDirectory: true)
    func pane(_ actions: SettingsActions) -> some View {
      CheckupPane(directory: directory)
        .environment(model)
        .environment(actions)
        .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .checkup).accent)
    }
    func notice(for key: String) -> SettingsActions {
      let actions = SettingsActions(model: model)
      actions.checkupRestoreFailure = CheckupRestoreNotice(
        text: CheckupPaneCopy.restoreNotAchieved, identityKey: key)
      return actions
    }

    // Every window stays bound: a released host tears its SwiftUI graph down and
    // the elements collected from it answer nothing.
    let quiet = Self.hosted(pane(SettingsActions(model: model)))
    // The control: the walk reaches this pane's content either way, so an absent
    // notice below means the pane drew none, not that the walk read nothing.
    #expect(Self.labels(quiet.elements).contains(CheckupPaneCopy.run))
    #expect(!Self.labels(quiet.elements).contains(CheckupPaneCopy.acknowledge))
    #expect(!Self.labels(quiet.elements).contains("Warning"))

    // A notice about a display that is not here belongs to no scope this pane
    // can resolve, so it draws nowhere.
    let foreign = Self.hosted(pane(notice(for: "a-display-that-is-not-attached")))
    #expect(Self.labels(foreign.elements).contains(CheckupPaneCopy.run))
    #expect(!Self.labels(foreign.elements).contains("Warning"))

    // And under exactly one scope: the run's own. Which display the pane opens
    // on is not asserted, since whether this Mac contributes a built-in is a
    // property of the machine running the suite.
    var rendering: [(window: NSWindow, elements: [AnyObject])] = []
    for state in model.allControlledStates {
      let hosted = Self.hosted(pane(notice(for: state.display.persistenceKey)))
      if Self.labels(hosted.elements).contains("Warning") { rendering.append(hosted) }
    }
    #expect(rendering.count == 1)
    let noticed = try #require(rendering.first)
    #expect(Self.labels(noticed.elements).contains(CheckupPaneCopy.run))
    // The notice's symbol, its way out, and one more line of text than the quiet
    // pane. The sentence cannot be read here: SwiftUI publishes body text as an
    // `AXStaticText` with neither label nor value under a hosting view
    // [measured 2026-09-10], so the copy rules are asserted over
    // `allStringsForTest` instead.
    #expect(Self.labels(noticed.elements).filter { $0 == CheckupPaneCopy.acknowledge }.count == 1)
    #expect(Self.staticTexts(noticed.elements) == Self.staticTexts(quiet.elements) + 1)

    // What that OK does. Called rather than pressed: `accessibilityPerformPress`
    // on a SwiftUI button runs no action in this bundle [measured 2026-09-10,
    // against this same element], so the action is named and driven directly.
    let dismissing = notice(for: "checkup-notice-fixture")
    CheckupPane.dismissRestoreNotice(dismissing)
    #expect(dismissing.checkupRestoreFailure == nil)
  }

  /// Every element the hosted view publishes, in tree order, with the window
  /// that keeps it alive. SwiftUI builds no accessibility nodes until an
  /// assistive client attaches, so without the flag the walk finds an empty tree.
  @MainActor private static func hosted(
    _ view: some View
  ) -> (window: NSWindow, elements: [AnyObject]) {
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(
      true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = NSHostingView(rootView: view.transaction { $0.disablesAnimations = true })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 1400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    var found: [AnyObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 30 else { return }
      let object = element as AnyObject
      found.append(object)
      for child in (object.accessibilityChildren?() ?? nil) ?? [] { walk(child, depth: depth + 1) }
    }
    walk(host, depth: 0)
    return (window, found)
  }

  private static func labels(_ elements: [AnyObject]) -> [String] {
    elements.compactMap { $0.accessibilityLabel?() ?? nil }
  }

  private static func staticTexts(_ elements: [AnyObject]) -> Int {
    elements.filter { ($0.accessibilityRole?() ?? nil) == .staticText }.count
  }
}
