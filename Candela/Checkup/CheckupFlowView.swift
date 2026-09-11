import CandelaKit
import SwiftUI

/// The checkup window's root. No Skip and no Cancel, deliberately: closing the
/// window is the exit, and the controller saves it as an abandoned run.
struct CheckupFlowView: View {
  @Bindable var model: CheckupFlowModel
  /// The field's last tap. The field is on another display and the answer
  /// buttons are here, so the region travels with the answer.
  var tappedRegion: () -> (x: Int, y: Int)? = { nil }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      CheckupBackdrop()
      page
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(String(describing: model.page))
        .transition(.opacity)
      chrome
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.page)
    // Default priority: a page change must not cut off a sentence VoiceOver is
    // part-way through, and the listener cannot ask for it back. `onChange`
    // skips the first render, which keeps the opening page silent while the
    // window becoming key speaks its own title.
    .onChange(of: model.page) { _, page in
      GuidedFlowAnnouncement.queued(CheckupCopy.pageAnnouncement(page))
    }
    // High priority: a deadline is the one case where interrupting is the
    // point. Posted from here, not the field window, because this view is what
    // stays alive through the showing.
    .onChange(of: model.secondsRemaining) { _, seconds in
      guard let kind = countdownFieldKind,
        let text = CheckupCopy.secondsLeftAnnouncement(seconds: seconds, cap: kind.capSeconds)
      else { return }
      GuidedFlowAnnouncement.interrupting(text)
    }
    .frame(minWidth: 720, minHeight: 560)
    .preferredColorScheme(.dark)
  }

  /// The field the seconds are counting down from, nil when nothing is on the
  /// glass. The cap matters: the white field's is 10, so its opening value must
  /// not be read as the 10-second threshold.
  private var countdownFieldKind: CheckupFieldKind? {
    switch model.page {
    case .fieldShowing(let kind), .fieldConfirmSecondDot(let kind): kind
    // Written out rather than defaulted: a later page with a field on it would
    // take the default and count down in silence.
    case .scenario, .displayPick, .plan, .identity, .capabilities, .nativeMode, .refresh,
      .witness, .plantDisclosure, .fieldInstruction, .hdr, .summary:
      nil
    }
  }

  @ViewBuilder
  private var page: some View {
    switch model.page {
    case .scenario:
      CheckupScenarioPage(model: model)
    case .displayPick:
      CheckupDisplayPickPage(model: model)
    case .plan:
      CheckupPlanPage(model: model)
    case .identity:
      CheckupLegPage(model: model, title: CheckupCopy.identityTitle, family: .identity)
    case .capabilities:
      CheckupLegPage(model: model, title: CheckupCopy.capabilitiesTitle, family: .capabilities)
    case .nativeMode:
      CheckupLegPage(model: model, title: CheckupCopy.nativeModeTitle, family: .nativeMode)
    case .refresh:
      CheckupLegPage(model: model, title: CheckupCopy.refreshTitle, family: .refresh)
    case .witness:
      CheckupFieldInstructionPage(model: model, kind: .witness)
    case .plantDisclosure:
      CheckupPlantDisclosurePage(model: model)
    case .fieldInstruction(let kind):
      CheckupFieldInstructionPage(model: model, kind: kind)
    case .fieldShowing(let kind):
      CheckupFieldShowingPage(model: model, kind: kind, tappedRegion: tappedRegion)
    case .fieldConfirmSecondDot(let kind):
      CheckupSecondDotPage(model: model, kind: kind, tappedRegion: tappedRegion)
    case .hdr:
      CheckupLegPage(model: model, title: CheckupCopy.hdrTitle, family: .hdr)
    case .summary:
      CheckupSummaryPage(model: model)
    }
  }

  /// Back exists only where a step back cannot rewrite a recorded claim; a
  /// control the model will ignore is worse than none.
  private var chrome: some View {
    VStack {
      HStack {
        if canGoBack {
          Button {
            model.back()
          } label: {
            Image(systemName: "chevron.left")
              .font(.body.weight(.semibold))
          }
          .buttonStyle(OnboardingLinkButtonStyle())
          .disabled(model.running)
          .accessibilityLabel(CheckupCopy.back)
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.top, 16)
      Spacer()
    }
  }

  private var canGoBack: Bool {
    switch model.page {
    case .displayPick, .plan: true
    default: false
    }
  }
}
