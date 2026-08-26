import AppKit
import CandelaKit
import SwiftUI
import UniformTypeIdentifiers

/// Borrows the setup flow's palette and buttons so the two guided windows are
/// one family; only the accent is its own.
enum CheckupStyle {
  static let accent = Color(red: 0.20, green: 0.78, blue: 0.92)
  static let pageWidth: CGFloat = 560
}

/// Deliberately still: a moving backdrop would compete with the glass being judged.
struct CheckupBackdrop: View {
  var body: some View {
    ZStack {
      Color(red: 0.055, green: 0.06, blue: 0.075)
      RadialGradient(
        colors: [CheckupStyle.accent.opacity(0.16), .clear],
        center: .top, startRadius: 0, endRadius: 620)
    }
    .ignoresSafeArea()
  }
}

/// One claim: the check in prose, its evidence grade, and what stands behind
/// it. Grade is weight and opacity, never green or red: no verdict on the display.
struct CheckupClaimRow: View {
  let claim: CheckupClaim

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(CheckupCopy.claimLabel(id: claim.id))
          .font(.callout.weight(.medium))
          .foregroundStyle(OnboardingStyle.titleColor)
        Text(CheckupCopy.verdictLabel(claim.verdict))
          .font(.caption.weight(.semibold))
          .foregroundStyle(OnboardingStyle.bodyColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.white.opacity(0.09)))
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(OnboardingStyle.faintColor)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var detail: String {
    guard let pixels = claim.detectedAt else { return claim.verdict.text }
    return "\(claim.verdict.text) \(CheckupCopy.detectedAt(pixels: pixels))"
  }
}

struct CheckupClaimList: View {
  let claims: [CheckupClaim]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(claims, id: \.id) { claim in
        CheckupClaimRow(claim: claim)
      }
    }
  }
}

/// Title, body, content, then the page's one primary action: every page in the
/// flow has this shape, so the eye finds Continue in the same place throughout.
struct CheckupPageScaffold<Content: View, Actions: View>: View {
  var title: String
  var subtitle: String?
  @ViewBuilder var content: Content
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 28)
      OnboardingHeading(title: title, subtitle: subtitle)
      Spacer(minLength: 20)
      ScrollView {
        content
          .frame(maxWidth: CheckupStyle.pageWidth, alignment: .leading)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 24)
      }
      .scrollBounceBehavior(.basedOnSize)
      Spacer(minLength: 16)
      actions
        .padding(.bottom, 40)
    }
  }
}

// MARK: - Scenario

struct CheckupScenarioPage: View {
  @Bindable var model: CheckupFlowModel

  var body: some View {
    CheckupPageScaffold(title: CheckupCopy.scenarioTitle, subtitle: CheckupCopy.scenarioSubtitle) {
      VStack(spacing: 10) {
        ForEach(CheckupScenario.allCases, id: \.self) { scenario in
          Button {
            model.scenario = scenario
          } label: {
            OnboardingCard(isSelected: model.scenario == scenario, accent: CheckupStyle.accent) {
              HStack(spacing: 12) {
                Image(
                  systemName: model.scenario == scenario
                    ? "largecircle.fill.circle" : "circle")
                  .foregroundStyle(
                    model.scenario == scenario ? CheckupStyle.accent : OnboardingStyle.faintColor)
                Text(CheckupCopy.scenarioLabel(scenario))
                  .foregroundStyle(OnboardingStyle.titleColor)
                Spacer(minLength: 0)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    } actions: {
      CheckupAdvanceButton(model: model, title: CheckupCopy.continueLabel)
    }
  }
}

// MARK: - Display pick

struct CheckupDisplayPickPage: View {
  @Bindable var model: CheckupFlowModel

  var body: some View {
    CheckupPageScaffold(title: CheckupCopy.pickTitle, subtitle: CheckupCopy.pickSubtitle) {
      VStack(spacing: 10) {
        if model.selectableDisplays.isEmpty {
          Text(CheckupCopy.pickEmpty)
            .font(.callout)
            .foregroundStyle(OnboardingStyle.bodyColor)
        }
        ForEach(model.selectableDisplays) { entry in
          Button {
            model.selectedDisplay = entry
          } label: {
            OnboardingCard(
              isSelected: model.selectedDisplay?.id == entry.id, accent: CheckupStyle.accent
            ) {
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                  .font(.callout.weight(.medium))
                  .foregroundStyle(OnboardingStyle.titleColor)
                Text("\(entry.pixelWidth) by \(entry.pixelHeight) pixels")
                  .font(.caption)
                  .foregroundStyle(OnboardingStyle.bodyColor)
                Text(CheckupCopy.panelClassLine(entry.panelClass))
                  .font(.caption)
                  .foregroundStyle(OnboardingStyle.faintColor)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    } actions: {
      CheckupAdvanceButton(
        model: model, title: CheckupCopy.continueLabel, enabled: model.selectedDisplay != nil)
    }
  }
}

// MARK: - Plan

struct CheckupPlanPage: View {
  @Bindable var model: CheckupFlowModel

  var body: some View {
    CheckupPageScaffold(title: CheckupCopy.planTitle, subtitle: CheckupCopy.planSubtitle) {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(model.plan, id: \.id) { step in
          VStack(alignment: .leading, spacing: 3) {
            Text(CheckupCopy.claimLabel(id: step.id))
              .font(.callout)
              .foregroundStyle(
                step.pregraded == nil ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor)
            if let pregraded = step.pregraded {
              Text("\(CheckupCopy.verdictLabel(pregraded)): \(pregraded.text)")
                .font(.caption)
                .foregroundStyle(OnboardingStyle.faintColor)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(CheckupCopy.planWorstCase(seconds: CheckupPlan.worstCaseFieldSeconds))
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      }
    } actions: {
      CheckupAdvanceButton(model: model, title: CheckupCopy.continueLabel)
    }
  }
}

// MARK: - The measured legs

/// The measured legs share one page: a spinner while the leg is in flight,
/// then its claims.
struct CheckupLegPage: View {
  @Bindable var model: CheckupFlowModel
  let title: String
  let family: CheckupFamily

  var body: some View {
    CheckupPageScaffold(title: title, subtitle: nil) {
      VStack(alignment: .leading, spacing: 14) {
        if model.running {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(CheckupCopy.running)
              .font(.callout)
              .foregroundStyle(OnboardingStyle.bodyColor)
          }
        } else {
          CheckupClaimList(claims: model.claims.filter { $0.family == family })
          Text(CheckupCopy.refusalNote)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
      }
    } actions: {
      CheckupAdvanceButton(
        model: model, title: CheckupCopy.continueLabel, enabled: !model.running)
    }
  }
}

// MARK: - The planted control

struct CheckupPlantDisclosurePage: View {
  @Bindable var model: CheckupFlowModel

  var body: some View {
    CheckupPageScaffold(
      title: CheckupCopy.plantDisclosureTitle, subtitle: CheckupCopy.plantDisclosure
    ) {
      EmptyView()
    } actions: {
      CheckupAdvanceButton(model: model, title: CheckupCopy.continueLabel)
    }
  }
}

// MARK: - Fields

/// Where a field rests before and after its showing: what will appear, what to
/// look for, and the two ways onto the panel (the first showing and a repeat).
struct CheckupFieldInstructionPage: View {
  @Bindable var model: CheckupFlowModel
  let kind: CheckupFieldKind

  var body: some View {
    CheckupPageScaffold(
      title: CheckupCopy.fieldTitle(kind), subtitle: CheckupCopy.instruction(for: kind)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if let note = plantNote {
          Text(note)
            .font(.callout)
            .foregroundStyle(OnboardingStyle.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let recorded = recordedClaim {
          Text("\(CheckupCopy.recordedPrefix): \(recorded.verdict.text)")
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } actions: {
      VStack(spacing: 10) {
        if hasBeenShown {
          if model.canShowAgain {
            Button(CheckupCopy.showAgain) { model.showAgain() }
              .buttonStyle(OnboardingSecondaryButtonStyle())
          }
          CheckupAdvanceButton(model: model, title: CheckupCopy.continueLabel)
        } else {
          Button(CheckupCopy.start) { model.startShowing() }
            .buttonStyle(OnboardingPrimaryButtonStyle(accent: CheckupStyle.accent))
            .keyboardShortcut(.defaultAction)
        }
        // Gone once the cap is spent: a rule about what you may still do reads
        // as an offer, and the button it describes is no longer there.
        if model.canShowAgain {
          Text(CheckupCopy.showAgainCap)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }
      }
    }
  }

  private var hasBeenShown: Bool {
    model.showings[CheckupCheckID.field(kind), default: 0] > 0
  }

  private var recordedClaim: CheckupClaim? {
    model.claims.first { $0.id == CheckupCheckID.field(kind) }
  }

  /// CK21's copy, and only on the field the control rides: a miss is a fact
  /// about what is resolvable from where the person is sitting.
  private var plantNote: String? {
    guard kind == CheckupFlowModel.plantedField, let record = model.plantRecord,
      record.detectedAtPixels == nil
    else { return nil }
    if record.missed { return CheckupCopy.plantMissedTwice }
    guard model.currentPlantSize == CheckupFlowModel.retryPlantPixels else { return nil }
    return CheckupCopy.plantMissed(size: CheckupFlowModel.firstPlantPixels)
  }
}

/// The field is on the panel. This page carries the countdown and the answers,
/// and on a two-display setup it is the only place they exist.
struct CheckupFieldShowingPage: View {
  @Bindable var model: CheckupFlowModel
  let kind: CheckupFieldKind
  var tappedRegion: () -> (x: Int, y: Int)?

  var body: some View {
    CheckupPageScaffold(
      title: CheckupCopy.fieldTitle(kind), subtitle: CheckupCopy.answerPrompt
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Text(CheckupCopy.secondsLeft(model.secondsRemaining))
          .font(.title3.monospacedDigit())
          .foregroundStyle(OnboardingStyle.titleColor)
          .frame(maxWidth: .infinity, alignment: .center)
        if kind.carriesPlant {
          Text(CheckupCopy.tapHint)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
      }
    } actions: {
      CheckupAnswerButtons(kind: kind) { answer in
        model.answer(answer, tappedRegion: tappedRegion())
      }
    }
  }
}

/// CK22's confirmation: the same field with nothing planted on it, so a mark
/// still on screen belongs to the panel.
struct CheckupSecondDotPage: View {
  @Bindable var model: CheckupFlowModel
  let kind: CheckupFieldKind
  var tappedRegion: () -> (x: Int, y: Int)?

  var body: some View {
    CheckupPageScaffold(
      title: CheckupCopy.secondDotTitle, subtitle: CheckupCopy.secondDotPrompt
    ) {
      Text(CheckupCopy.secondsLeft(model.secondsRemaining))
        .font(.title3.monospacedDigit())
        .foregroundStyle(OnboardingStyle.titleColor)
        .frame(maxWidth: .infinity, alignment: .center)
    } actions: {
      CheckupAnswerButtons(kind: kind) { answer in
        model.answer(answer, tappedRegion: tappedRegion())
      }
    }
  }
}

/// The answers a field offers, in one place because the flow window and the
/// field's own strip must offer exactly the same ones.
struct CheckupAnswerButtons: View {
  let kind: CheckupFieldKind
  let answer: (CheckupFieldAnswer) -> Void

  var body: some View {
    HStack(spacing: 10) {
      // Indexed rather than keyed by the answer: `CheckupFieldAnswer` is
      // Equatable and nothing else, and the order is the copy's own.
      ForEach(Array(CheckupCopy.answers(for: kind).enumerated()), id: \.offset) { pair in
        Button(CheckupCopy.answerLabel(pair.element)) { answer(pair.element) }
          .buttonStyle(OnboardingSecondaryButtonStyle())
      }
    }
  }
}

// MARK: - Summary

struct CheckupSummaryPage: View {
  @Bindable var model: CheckupFlowModel

  @State private var justCopied = false
  @State private var confirmationTask: Task<Void, Never>?
  @State private var saveError: String?

  var body: some View {
    // The document's own first line is the header sentence, so the scaffold
    // does not print it a second time above it.
    CheckupPageScaffold(title: CheckupCopy.summaryTitle, subtitle: nil) {
      // CK31: the page shows the document itself, the same text Copy summary
      // and the export carry, so there is only one shape of the report to read.
      if let report = model.report {
        Text(verbatim: CheckupSummaryText.render(report))
          .font(.caption.monospaced())
          .foregroundStyle(OnboardingStyle.bodyColor)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } actions: {
      VStack(spacing: 10) {
        HStack(spacing: 10) {
          Button(CheckupCopy.export) { export() }
            .buttonStyle(OnboardingPrimaryButtonStyle(accent: CheckupStyle.accent))
          Button(CheckupCopy.copySummary) { copySummary() }
            .buttonStyle(OnboardingSecondaryButtonStyle())
        }
        if justCopied {
          Text(CheckupCopy.copied)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }
      }
      .alert(
        CheckupCopy.exportFailed,
        isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button(CheckupCopy.acknowledge) { saveError = nil }
      } message: {
        Text(verbatim: saveError ?? "")
      }
    }
  }

  private func export() {
    guard let envelope = model.envelope else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = CheckupStore.exportFileName(for: envelope.report)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try CheckupStore.encoded(envelope).write(to: url, options: .atomic)
    } catch {
      // Silence here would look exactly like a saved file. The report exists to
      // be handed to somebody, so a save that did not happen has to say so.
      saveError = error.localizedDescription
    }
  }

  private func copySummary() {
    guard let report = model.report else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(CheckupSummaryText.render(report), forType: .string)
    justCopied = true
    // Cancelled and replaced on every copy, so a second click restarts the two
    // seconds rather than letting the first click's timer clear the label early.
    confirmationTask?.cancel()
    confirmationTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      justCopied = false
    }
  }
}

// MARK: - Shared actions

/// `advance()` is async because some pages run a leg on the way out, so the
/// button owns the task.
struct CheckupAdvanceButton: View {
  @Bindable var model: CheckupFlowModel
  let title: String
  var enabled = true

  var body: some View {
    Button(title) { Task { await model.advance() } }
      .buttonStyle(OnboardingPrimaryButtonStyle(accent: CheckupStyle.accent))
      .keyboardShortcut(.defaultAction)
      .disabled(!enabled)
      .opacity(enabled ? 1 : 0.4)
  }
}
