import CandelaKit
import SwiftUI

/// The checkup window's root: the backdrop, the current page, and the one piece
/// of fixed chrome the flow has. There is deliberately no Skip and no Cancel
/// button: closing the window is the exit, and the controller records it as an
/// abandoned run rather than losing it (CK27).
struct CheckupFlowView: View {
  @Bindable var model: CheckupFlowModel
  /// The last tap the field window saw. The field is on another display and
  /// the answer buttons are here, so the region a person pointed at has to
  /// travel from the window that received it to the button that reports it.
  var tappedRegion: () -> (x: Int, y: Int)? = { nil }
  /// Fires when the target changes, so the controller can move this window off
  /// the display that is about to be covered by a field.
  var onSelectedDisplayChanged: (CheckupDisplayEntry?) -> Void = { _ in }

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
    .onChange(of: model.selectedDisplay) { _, entry in onSelectedDisplayChanged(entry) }
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

  /// Back exists only where a step back cannot rewrite something already
  /// recorded: the model refuses everywhere else, and a control the model will
  /// ignore is worse than no control.
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
