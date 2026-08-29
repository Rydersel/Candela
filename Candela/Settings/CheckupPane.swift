import AppKit
import CandelaKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Every user-visible string on the pane, in one place so the copy rules (no
/// verdict on the display (CK8), no key names, no em dashes) can be checked at once.
enum CheckupPaneCopy {
  static let title = "Checkup"
  static let subtitle =
    "A new display is easiest to send back in its first days. Checkup examines one while "
    + "the return window is still open, and writes down what it saw."

  static let runTitle = "A new checkup"
  static let run = "Run a checkup"
  static let runNote =
    "One run covers one display: what it reports about itself, what it answers over DDC, "
    + "its native mode, its refresh rates and its HDR support, then a set of color fields you "
    + "look at yourself. The run opens in its own window, and you can stop it at any point."

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

  static let verifyTitle = "A report from somebody else"
  static let verify = "Verify a report"
  static let verifyNote =
    "An exported report carries a hash of its own contents. Open one here to check that the two still agree."
  static let valid = "This report validates: its contents match its hash."
  static let invalid =
    "This report does not validate: its contents have changed since it was written."
  static let unreadable = "That file could not be read as a checkup report."

  /// The fixed strings, so the copy rules can be asserted over the surface
  /// rather than over a reviewer's memory.
  static var allStringsForTest: [String] {
    [title, subtitle, runTitle, run, runNote, historyTitle, emptyHistory, historyNote, export,
     copySummary, copied, showDetails, hideDetails, exportFailed, acknowledge, verifyTitle,
     verify, verifyNote, valid, invalid, unreadable]
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
}

/// The Checkup pillar (CK28): the launcher, this display's past runs, and the
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
  @State private var verification: String?
  /// Held apart from the summary: the verdict is a sentence, the summary a document.
  @State private var provenanceVerdict: String?
  @State private var provenanceSummary: String?

  init(directory: URL = CheckupStore.defaultDirectory()) {
    store = CheckupStore(directory: directory)
  }

  var body: some View {
    SettingsPageScaffold {
      SettingsPageHeader(title: CheckupPaneCopy.title, subtitle: CheckupPaneCopy.subtitle)
      runSection
      historySection
      verifySection
    }
    .onAppear { refresh() }
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
      refresh()
    }
  }

  // MARK: - Run

  private var runSection: some View {
    SettingsCardSection(title: CheckupPaneCopy.runTitle) {
      VStack(alignment: .leading, spacing: 10) {
        SettingsRowNote(verbatim: CheckupPaneCopy.runNote)
        Button(CheckupPaneCopy.run) { actions.openCheckup() }
          .buttonStyle(SettingsPrimaryButtonStyle())
      }
      .padding(.vertical, 2)
    }
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
              CheckupHistoryRow(run: pair.element)
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

  @State private var showingDetails = false
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
        Button(CheckupPaneCopy.export) { export() }
          .buttonStyle(SettingsSecondaryButtonStyle())
        Button(CheckupPaneCopy.copySummary) { copySummary() }
          .buttonStyle(SettingsSecondaryButtonStyle())
        Button(showingDetails ? CheckupPaneCopy.hideDetails : CheckupPaneCopy.showDetails) {
          showingDetails.toggle()
        }
        .buttonStyle(SettingsSecondaryButtonStyle())
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
  }

  /// CK29's name and the store's own encoder, so an export is byte-identical to
  /// the stored file and `validate()` answers the same on both.
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
