import AppKit
import CandelaKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Every user-visible string on the pane, in one place so the copy rules (no
/// verdict on the display, no key names, no em dashes) can be checked at once.
enum CheckupPaneCopy {
  static let title = "Checkup"
  static let subtitle =
    "Checkup looks for defects and wear, checks what a display claims against what it does, "
    + "and writes down what it saw."

  static let runTitle = "A new checkup"
  static let run = "Run a checkup"
  static let runNote =
    "One run covers one display: what it reports about itself, what it answers over DDC, "
    + "its native mode, its refresh rates and its HDR support, then a set of color fields you "
    + "look at yourself. The run opens in its own window, and you can stop it at any point."

  /// Shown when a run ended before the display was put back. No verdict on the
  /// panel, since nothing here was measured about it, and both ways back are
  /// named rather than leaving a stranger on a changed screen.
  static let restoreNotAchieved =
    "The run ended before the display was put back, and it is not on the resolution and refresh rate it started in. Set it back in System Settings, or on this display's own page in \(AppInfo.productName)."

  static let historyTitle = "Past checkups"
  static let emptyHistory = "No checkups recorded for this display yet."
  static let historyNote =
    "Every run is kept on this machine, filed under the display's own identity. "
    + "Nothing is sent anywhere."
  static let export = "Export"
  static let copySummary = "Copy summary"
  static let copied = "Copied"
  static let showDetails = "Show details"
  static let hideDetails = "Hide details"
  static let exportFailed = "The report could not be saved."
  static let acknowledge = "OK"
  static let deleteRun = "Delete…"
  static let deleteTitle = "Delete this checkup?"
  static let deleteConfirm = "Delete"
  static let deleteCancel = "Cancel"
  static let deleteFailed = "The checkup could not be deleted."
  static let deleteConsequences =
    "This run's file is removed from this Mac. Other runs on this display are kept, and a report "
    + "you already exported somewhere else is untouched.\n\nA provenance record bundles every checkup "
    + "stored for the display, so a record exported after this delete leaves this run out and carries "
    + "a different hash from one exported before it. If you want to keep a record that includes "
    + "this run, export it first."

  /// The title cannot name the run and a display can have several, so the
  /// message opens with the row's own subject line.
  static func deleteMessage(for report: CheckupReport) -> String {
    "\(CheckupCopy.subjectLine(for: report))\n\n\(deleteConsequences)"
  }

  /// Every row's button reads "Delete…", so the spoken label is the only thing
  /// that can say which run is about to go.
  static func deleteRunLabel(for report: CheckupReport) -> String {
    "Delete the run from \(CheckupCopy.subjectLine(for: report))"
  }

  static let verifyTitle = "A report from somebody else"
  static let verify = "Verify a report"
  static let verifyNote =
    "An exported report carries a hash of its own contents. Open one here to check that the two still agree."
  static let valid = "This report validates: its contents match its hash."
  static let invalid =
    "This report does not validate: its contents have changed since it was written."
  static let unreadable = "That file could not be read as a checkup report."

  /// A run for the sweep to render the strings that name one. Fixed, so the
  /// sweep reads the same sentence every time.
  private static let sampleReport = CheckupReport(
    scenario: .newMonitor,
    identity: CheckupDisplayIdentity(
      identityKey: "sample", vendorID: 0, modelID: 0, serial: nil, manufactureWeek: nil,
      manufactureYear: nil, nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: nil,
      supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "Display"),
    panelClass: .readsDDC, macOSBuild: "26.0", appBuild: "1",
    startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), endedAt: nil,
    completion: .complete, claims: [], plant: nil, showings: [:], exposureBookingID: nil)

  /// The fixed strings plus one sample of each parameterised one, so the copy
  /// rules can be asserted over the surface rather than over a reviewer's memory.
  static var allStringsForTest: [String] {
    [title, subtitle, runTitle, run, runNote, restoreNotAchieved, historyTitle, emptyHistory,
     historyNote, export, copySummary, copied, showDetails, hideDetails, exportFailed,
     acknowledge, deleteRun, deleteTitle, deleteConfirm, deleteCancel, deleteFailed, deleteConsequences,
     verifyTitle, verify, verifyNote, valid, invalid, unreadable,
     deleteRunLabel(for: sampleReport)]
  }
}

/// Which display the history opens on: the one with the most recent run, then
/// the first external, then whatever is left. Not "the first display": the
/// built-in leads `allControlledStates` and would hide a fresh external's run.
enum CheckupHistoryScope {
  static func defaultKey(_ candidates: [(key: String, isBuiltIn: Bool, latestRun: Date?)])
    -> String? {
    let dated = candidates.compactMap { candidate in
      candidate.latestRun.map { (key: candidate.key, date: $0) }
    }
    if let newest = dated.max(by: { $0.date < $1.date }) { return newest.key }
    return (candidates.first { !$0.isBuiltIn } ?? candidates.first)?.key
  }

  /// Only the default scope follows the newest run anywhere; a hand-picked scope
  /// stays put, so reading every display's runs for it decodes them for nothing.
  static func needsEveryDisplay(chosenByHand: Bool) -> Bool { !chosenByHand }
}

/// The Checkup pillar: the launcher, this display's past runs, and the
/// place a report somebody sends you is checked against its own hash. The pane
/// never runs a check; "Run a checkup" opens the flow window through
/// `SettingsActions`. `@MainActor` because stored and computed properties read
/// `AppModel` outside `body`.
@MainActor
struct CheckupPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  /// Reloads the history when this window comes back to the front, which is
  /// what happens the moment a run's own window closes over it.
  @Environment(\.controlActiveState) private var activeState

  private let store: CheckupStore

  /// Resolved on every render rather than pinned, so a departed display falls
  /// back to a connected one.
  @State private var scopedKey: String?
  /// Until the picker is used the scope follows the store, so a run finishing
  /// while the pane is open moves the history to its display.
  @State private var chosenByHand = false
  @State private var runs: [CheckupStoredRun] = []
  @State private var deleteError: String?
  @State private var verification: String?
  /// Held apart from the summary: the verdict is a sentence, the summary a document.
  @State private var provenanceVerdict: String?
  @State private var provenanceSummary: String?

  init(directory: URL = CheckupStore.defaultDirectory()) {
    store = CheckupStore(directory: directory)
  }

  var body: some View {
    // `DisplayPrefs` is not observable and the scope picker is named through it;
    // without this a rename leaves the old name in the menu.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(title: CheckupPaneCopy.title, subtitle: CheckupPaneCopy.subtitle)
      runSection
      restoreNotice
      historySection
      verifySection
    }
    .onAppear { refresh() }
    .alert(
      CheckupPaneCopy.deleteFailed,
      isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
    ) {
      Button(CheckupPaneCopy.acknowledge) { deleteError = nil }
    } message: {
      Text(verbatim: deleteError ?? "")
    }
    // Keyed on the RESOLVED display, so a departure and a picker change hit one
    // observer. The verification line goes too: it answered under another display.
    .onChange(of: scoped?.display.persistenceKey) {
      verification = nil
      provenanceVerdict = nil
      provenanceSummary = nil
      reload()
    }
    .onChange(of: activeState) { _, state in
      guard state != .inactive else { return }
      // `refresh()` decodes every display's runs, and only the default scope
      // needs that.
      if CheckupHistoryScope.needsEveryDisplay(chosenByHand: chosenByHand) {
        refresh()
      } else {
        reload()
      }
    }
  }

  // MARK: - Run

  private var runSection: some View {
    SettingsCardSection(title: CheckupPaneCopy.runTitle) {
      VStack(alignment: .leading, spacing: 10) {
        SettingsRowNote(verbatim: CheckupPaneCopy.runNote)
        // SwiftUI does not publish a `Button` title to accessibility; without
        // this it announces as "button".
        Button(CheckupPaneCopy.run) { actions.openCheckup() }
          .buttonStyle(SettingsPrimaryButtonStyle())
          .accessibilityLabel(Text(verbatim: CheckupPaneCopy.run))
      }
      .padding(.vertical, 2)
    }
  }

  /// The only place a failed restore can be read: the run's window is gone by
  /// the time it answers. Scoped to the display the run moved, dismissed by
  /// hand, superseded when the next run starts.
  @ViewBuilder private var restoreNotice: some View {
    if let notice = actions.checkupRestoreFailure,
      CheckupPane.showsRestoreNotice(notice, scopedKey: scoped?.display.persistenceKey) {
      SettingsNotice {
        Text(verbatim: notice.text)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        Button(CheckupPaneCopy.acknowledge) { CheckupPane.dismissRestoreNotice(actions) }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: CheckupPaneCopy.acknowledge))
      }
      // Queued, not interrupting: the pane can already be open behind the run,
      // so nothing on screen has moved the cursor.
      .onAppear { GuidedFlowAnnouncement.queued(notice.text) }
    }
  }

  /// The notice is app-global and its sentence names no display, so it belongs
  /// only under the scope of the display the run moved.
  static func showsRestoreNotice(_ notice: CheckupRestoreNotice?, scopedKey: String?) -> Bool {
    guard let notice, let scopedKey else { return false }
    return notice.identityKey == scopedKey
  }

  /// The OK's whole job. Named rather than inline because an accessibility press
  /// runs no SwiftUI action, so this is the only seam the suite can drive.
  static func dismissRestoreNotice(_ actions: SettingsActions) {
    actions.checkupRestoreFailure = nil
  }

  // MARK: - Scope

  /// The built-in included: a checkup runs on any real display, filed under the
  /// same persistence key this switcher selects by.
  private var displays: [AppModel.DisplayState] { model.allControlledStates }

  private var scoped: AppModel.DisplayState? {
    displays.first { $0.display.persistenceKey == scopedKey } ?? displays.first
  }

  private func name(_ state: AppModel.DisplayState) -> String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: state.display.persistenceKey).friendlyName,
      hardwareName: state.display.name)
  }

  /// One listing per display: it picks the default scope and fills the history
  /// from the same read, so arriving on the pane costs one pass over the store.
  private func refresh() {
    let listings = displays.map { state in
      (state: state, runs: (try? store.list(identityKey: state.display.persistenceKey)) ?? [])
    }
    var key = scopedKey
    if !chosenByHand {
      let builtInID = model.builtIn?.id
      key = CheckupHistoryScope.defaultKey(
        listings.map {
          (key: $0.state.display.persistenceKey, isBuiltIn: $0.state.id == builtInID,
           latestRun: $0.runs.first?.startedAt)
        })
      scopedKey = key
    }
    let resolved = listings.first { $0.state.display.persistenceKey == key } ?? listings.first
    runs = resolved?.runs ?? []
  }

  private func reload() {
    guard let key = scoped?.display.persistenceKey else {
      runs = []
      return
    }
    // An unreadable store is an empty history, not an error state.
    runs = (try? store.list(identityKey: key)) ?? []
  }

  /// Re-reading through `reload()` keeps one code path for what the history
  /// shows: a delete that did not happen leaves its row standing.
  private func delete(_ run: CheckupStoredRun) {
    deleteError = Self.delete(run, from: store)
    reload()
  }

  static func delete(_ run: CheckupStoredRun, from store: CheckupStore) -> String? {
    do {
      try store.delete(url: run.url)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  // MARK: - History

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        SettingsSectionTitle(text: CheckupPaneCopy.historyTitle)
        Spacer(minLength: 12)
        if displays.count > 1, let scoped {
          Picker(
            "Display",
            selection: Binding(
              get: { scoped.display.persistenceKey },
              set: {
                scopedKey = $0
                chosenByHand = true
              })
          ) {
            ForEach(displays, id: \.display.persistenceKey) { candidate in
              // A display's name, never a lookup key.
              Text(verbatim: name(candidate)).tag(candidate.display.persistenceKey)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
          .accessibilityLabel("Display")
        }
      }

      SettingsCard {
        VStack(alignment: .leading, spacing: 0) {
          if runs.isEmpty {
            SettingsRowNote(verbatim: CheckupPaneCopy.emptyHistory)
          } else {
            // Keyed by the file's own URL: one run, one file, and a second run
            // on the same day still has its own row.
            ForEach(Array(runs.enumerated()), id: \.element.url) { pair in
              if pair.offset > 0 { SettingsCardDivider() }
              CheckupHistoryRow(run: pair.element, onDelete: { delete(pair.element) })
            }
          }
        }
      }

      SettingsRowNote(verbatim: CheckupPaneCopy.historyNote)
        .padding(.leading, 4)
    }
  }

  // MARK: - Verify

  private var verifySection: some View {
    SettingsCardSection(title: CheckupPaneCopy.verifyTitle) {
      VStack(alignment: .leading, spacing: 10) {
        SettingsRowNote(verbatim: CheckupPaneCopy.verifyNote)
        Button(CheckupPaneCopy.verify) { verify() }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: CheckupPaneCopy.verify))
        if let verification {
          // The answer is about the file and never about the display: a report
          // that validates is one nobody edited, and nothing more.
          Text(verbatim: verification)
            .font(.callout)
            .foregroundStyle(SettingsTheme.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCardDivider()
        SettingsRowNote(verbatim: ProvenanceCopy.checkNote)
        Button(ProvenanceCopy.check) { checkProvenance() }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: ProvenanceCopy.check))
        if let provenanceVerdict {
          // Styled like the verify answer above it: both are a sentence about a file.
          Text(verbatim: provenanceVerdict)
            .font(.callout)
            .foregroundStyle(SettingsTheme.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let provenanceSummary {
          // Show details' treatment: the one surface showing a record somebody else
          // sent, so the serial and the hours have to be selectable out of it.
          Text(verbatim: provenanceSummary)
            .font(.caption.monospaced())
            .foregroundStyle(SettingsTheme.bodyColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func pickJSONFile() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private func verify() {
    guard let url = pickJSONFile() else { return }
    guard let envelope = try? store.load(url: url) else {
      verification = CheckupPaneCopy.unreadable
      return
    }
    verification = envelope.validate() ? CheckupPaneCopy.valid : CheckupPaneCopy.invalid
  }

  private func checkProvenance() {
    guard let url = pickJSONFile() else { return }
    guard let envelope = try? ProvenanceEnvelope.load(url: url) else {
      provenanceVerdict = ProvenanceCopy.unreadable
      // Otherwise the summary left over from the last check outlives its file.
      provenanceSummary = nil
      return
    }
    provenanceVerdict = envelope.validate() ? ProvenanceCopy.intact : ProvenanceCopy.altered
    provenanceSummary = ProvenanceSummaryText.render(envelope.record)
  }
}

/// One stored run. The subject line names it the way the report does, so the
/// row and the exported document agree.
@MainActor
private struct CheckupHistoryRow: View {
  let run: CheckupStoredRun
  let onDelete: () -> Void

  @State private var showingDetails = false
  @State private var confirmingDelete = false
  @State private var justCopied = false
  /// Cancelled and replaced on every copy, so a second click restarts the two
  /// seconds instead of letting the first click's timer clear the label early.
  @State private var confirmationTask: Task<Void, Never>?
  @State private var saveError: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var report: CheckupReport { run.envelope.report }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: CheckupCopy.subjectLine(for: report))
        .font(.callout.weight(.medium))
        .foregroundStyle(SettingsTheme.titleColor)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: run.summaryLine)
        .font(.caption)
        .foregroundStyle(SettingsTheme.bodyColor)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        // Same as the Run button above. The details label follows the visible
        // title so the spoken one says which way the row goes.
        Button(CheckupPaneCopy.export) { export() }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: CheckupPaneCopy.export))
        Button(CheckupPaneCopy.copySummary) { copySummary() }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: CheckupPaneCopy.copySummary))
        let detailsTitle = showingDetails
          ? CheckupPaneCopy.hideDetails : CheckupPaneCopy.showDetails
        Button(detailsTitle) { showingDetails.toggle() }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: detailsTitle))
        // Trailing ellipsis: the click opens the confirmation, and `.destructive`
        // belongs on the button that removes the file. Ahead of the copied label
        // so it never slides sideways under the pointer.
        Button(CheckupPaneCopy.deleteRun, role: .destructive) { confirmingDelete = true }
          .buttonStyle(SettingsDangerButtonStyle())
          // The visible label is the same on every row, so the spoken one names
          // the run this button would delete.
          .accessibilityLabel(Text(verbatim: CheckupPaneCopy.deleteRunLabel(for: report)))
        if justCopied {
          Text(verbatim: CheckupPaneCopy.copied)
            .font(.caption)
            .foregroundStyle(SettingsTheme.faintColor)
            .transition(.opacity)
        }
      }

      if showingDetails {
        // The document itself, not a second shape of it: what is on screen here
        // is what Copy summary puts on the clipboard.
        Text(verbatim: CheckupSummaryText.render(report))
          .font(.caption.monospaced())
          .foregroundStyle(SettingsTheme.bodyColor)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, SettingsTheme.rowVerticalPadding)
    .alert(
      CheckupPaneCopy.exportFailed,
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button(CheckupPaneCopy.acknowledge) { saveError = nil }
    } message: {
      Text(verbatim: saveError ?? "")
    }
    .confirmationDialog(
      CheckupPaneCopy.deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible
    ) {
      Button(CheckupPaneCopy.deleteConfirm, role: .destructive) { onDelete() }
      // The shortcut puts the default action on Cancel, so Return cannot delete
      // a run. What the dialog would do without it is a rig check nobody has
      // run; the heat map's own delete dialog leaves it alone.
      Button(CheckupPaneCopy.deleteCancel, role: .cancel) {}
        .keyboardShortcut(.defaultAction)
    } message: {
      // The run this is about, then the provenance consequence: the record is
      // assembled at export time out of whatever is stored then, so this is the
      // last moment to keep one that includes this run.
      Text(verbatim: CheckupPaneCopy.deleteMessage(for: report))
    }
  }

  /// The export file's own naming and the store's own encoder, so an export
  /// is byte-identical to the stored file and `validate()` answers the same on both.
  private func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = CheckupStore.exportFileName(for: report)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try CheckupStore.encoded(run.envelope).write(to: url, options: .atomic)
    } catch {
      // Silence would look exactly like a saved file, and this report exists to
      // be handed to somebody.
      saveError = error.localizedDescription
    }
  }

  private func copySummary() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(CheckupSummaryText.render(report), forType: .string)
    withAnimation(Motion.notice(reduceMotion: reduceMotion)) { justCopied = true }
    confirmationTask?.cancel()
    confirmationTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) { justCopied = false }
    }
  }
}
