import AppKit
import CandelaKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Every user-visible string on the Checkup pane, in one place so the copy
/// rules can be read over the surface at once: no verdict on the display
/// (CK8), no internal key names, no em dashes.
enum CheckupPaneCopy {
  static let title = "Checkup"
  static let subtitle =
    "A new display is easiest to send back in its first days. Checkup examines one while "
    + "the return window is still open, and writes down what it saw."

  static let runTitle = "A new checkup"
  static let run = "Run a checkup"
  static let runNote =
    "One run covers one display: what it reports about itself, what it answers over DDC, "
    + "its native mode and its refresh rates, then a set of colour fields you look at yourself. "
    + "The run opens in its own window, and you can stop it at any point."

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

/// The Checkup pillar (CK28): the launcher, this display's past runs, and the
/// one place a report somebody sends you can be checked against its own hash.
///
/// The pane never runs a check itself. "Run a checkup" opens the flow window
/// through `SettingsActions`, the same door the menu bar uses, and the history
/// below is read from the store that a finished run wrote to.
///
/// Per display, like Health's controls: a run is filed under the display's
/// identity, so the history has to name which display it is showing.
///
/// `@MainActor` for `DisplayDetailView`'s reason: a `View`'s stored and computed
/// properties are nonisolated under complete concurrency checking, and these
/// read `AppModel` from outside `body`.
@MainActor
struct CheckupPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  /// Reloads the history when this window comes back to the front, which is
  /// what happens the moment a run's own window closes over it.
  @Environment(\.controlActiveState) private var activeState

  private let store: CheckupStore

  /// The display whose runs are listed, or nil to follow the connected set.
  /// Resolved on every render rather than pinned on arrival, so a display that
  /// departs falls back to a connected one instead of listing nothing.
  @State private var scopedKey: String?
  @State private var runs: [CheckupStoredRun] = []
  @State private var verification: String?

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
    .onAppear { reload() }
    // Keyed on the RESOLVED display rather than on `scopedKey`: a departure
    // moves the scope with nothing writing that key, and a switcher change
    // moves it too, so one observer covers both.
    .onChange(of: scoped?.display.persistenceKey) { reload() }
    .onChange(of: activeState) { _, state in
      guard state != .inactive else { return }
      reload()
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

  /// The built-in included: a checkup runs on any real display, and the live
  /// environment files its report under the same persistence key this switcher
  /// selects by.
  private var displays: [AppModel.DisplayState] { model.allControlledStates }

  private var scoped: AppModel.DisplayState? {
    displays.first { $0.display.persistenceKey == scopedKey } ?? displays.first
  }

  private func name(_ state: AppModel.DisplayState) -> String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: state.display.persistenceKey).friendlyName,
      hardwareName: state.display.name)
  }

  private func reload() {
    guard let key = scoped?.display.persistenceKey else {
      runs = []
      return
    }
    // A store that cannot be read is an empty history rather than an error
    // state: this pane shows what was recorded, and a display with no runs has
    // recorded nothing.
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
            selection: Binding(get: { scoped.display.persistenceKey }, set: { scopedKey = $0 })
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
      }
      .padding(.vertical, 2)
    }
  }

  private func verify() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let envelope = try? store.load(url: url) else {
      verification = CheckupPaneCopy.unreadable
      return
    }
    verification = envelope.validate() ? CheckupPaneCopy.valid : CheckupPaneCopy.invalid
  }
}

/// One stored run: what it was, what it counted, and the three things a person
/// does with it. The subject line names the run the way the report itself does,
/// so a row and the document it exports agree on the display, the reason and
/// the day.
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

  /// CK29's name, and the store's own encoder: a file exported from here is the
  /// same bytes as the one the run wrote, so `validate()` answers the same on
  /// both, and so does `candela-probe checkup validate`.
  private func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = CheckupStore.exportFileName(for: report)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try CheckupStore.encoded(run.envelope).write(to: url, options: .atomic)
    } catch {
      // Silence here would look exactly like a saved file. The report exists to
      // be handed to somebody, so a save that did not happen has to say so.
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
