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
    .frame(minWidth: 720, minHeight: 560)
    .preferredColorScheme(.dark)
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
