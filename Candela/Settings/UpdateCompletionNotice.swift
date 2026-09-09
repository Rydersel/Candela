import SwiftUI

@MainActor
struct UpdateCompletionOverlay: ViewModifier {
  let state: UpdateCompletionState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if let notice = state.notice {
          UpdateCompletionNotice(version: notice.version, reduceMotion: reduceMotion) {
            state.dismiss(notice.id)
          }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .transition(.opacity)
            .id(notice.id)
        }
      }
      .animation(Motion.notice(reduceMotion: reduceMotion), value: state.notice?.id)
      .task(id: voiceOver ? nil : state.notice?.id) {
        guard let notice = state.notice, !voiceOver else { return }
        await state.dismissAfterDelay(notice.id)
      }
      .onDisappear {
        if let notice = state.notice { state.dismiss(notice.id) }
      }
  }
}

struct UpdateCompletionNotice: View {
  let version: String
  let reduceMotion: Bool
  let dismiss: () -> Void
  @Environment(\.settingsAccent) private var lighting
  @State private var appeared = false

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle().fill(lighting.accent.opacity(0.14))
        Circle()
          .trim(from: 0, to: appeared || reduceMotion ? 1 : 0)
          .stroke(lighting.accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Image(systemName: "checkmark")
          .font(.system(size: 19, weight: .semibold))
          .foregroundStyle(lighting.accent)
          .scaleEffect(appeared || reduceMotion ? 1 : 0.8)
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("Update complete")
          .font(.headline)
          .foregroundStyle(SettingsTheme.titleColor)
        Text("You're running \(AppInfo.productName) \(version).")
          .font(.callout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 4)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(SettingsTheme.bodyColor)
      .accessibilityLabel("Dismiss update confirmation")
      .help("Dismiss update confirmation")
    }
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
        .fill(SettingsTheme.noticeFill)
        .overlay {
          RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
            .stroke(lighting.accent.opacity(0.3), lineWidth: 1)
        }
    }
    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    .onAppear {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) { appeared = true }
    }
  }
}
