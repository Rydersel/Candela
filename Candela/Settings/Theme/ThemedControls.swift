import CandelaKit
import SwiftUI

/// The accent-lit slider: capsule track, glowing fill, draggable. Custom
/// because the system slider ignores the window's lighting entirely, so it
/// carries its own accessibility (SV6): call sites supply the label, this
/// supplies the value and the adjustable action.
struct ThemedSlider: View {
  @Binding var value: Double

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.10))
          .frame(height: 5)
        Capsule()
          .fill(lighting.accent.opacity(0.85))
          .frame(width: max(5, width * value), height: 5)
        Circle()
          .fill(.white)
          .frame(width: 13, height: 13)
          .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
          .offset(x: max(0, (width - 13) * value))
      }
      .frame(height: proxy.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { gesture in
          value = min(1, max(0, gesture.location.x / width))
        }
      )
    }
    .frame(height: 22)
    // The track, the fill and the knob are one control, not three shapes.
    .accessibilityElement(children: .ignore)
    .accessibilityValue(Text(verbatim: SliderSnap.percentText(value)))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: value = min(1, value + Self.step)
      case .decrement: value = max(0, value - Self.step)
      @unknown default: break
      }
    }
  }

  /// One VoiceOver nudge, matching the panel sliders' feel rather than the
  /// pixel resolution of a drag.
  private static let step = 0.05
}

/// Segmented choice shaped like the macOS segmented control: a recessed
/// rounded-rect track with a raised selected segment, accent-tinted.
struct ThemedSegments: View {
  var options: [String]
  @Binding var selection: Int

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options.indices, id: \.self) { index in
        SegmentButton(
          label: options[index], isOn: selection == index, accent: lighting.accent
        ) { selection = index }
      }
    }
    .padding(2.5)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.black.opacity(0.22))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    )
  }

  private struct SegmentButton: View {
    let label: String
    let isOn: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
      Button(action: action) {
        Text(label)
          .font(.callout.weight(isOn ? .medium : .regular))
          .foregroundStyle(isOn ? Color.white : SettingsTheme.bodyColor)
          .padding(.horizontal, 11)
          .padding(.vertical, 3.5)
          .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(
                isOn
                  ? AnyShapeStyle(accent.opacity(0.6))
                  : AnyShapeStyle(Color.white.opacity(hovering ? 0.07 : 0)))
          )
          .shadow(color: .black.opacity(isOn ? 0.25 : 0), radius: 2, y: 1)
      }
      .buttonStyle(.plain)
      // Which one is chosen is carried by the weight and the fill, neither of
      // which a screen reader can see.
      .accessibilityAddTraits(isOn ? [.isSelected] : [])
      .onHover { hovering = $0 }
      .animation(SettingsTheme.hoverMotion, value: hovering)
      .animation(SettingsTheme.hoverMotion, value: isOn)
    }
  }
}

/// Small accent capsule for state ("On", "Recommended", "Live").
struct SettingsBadge: View {
  var text: String

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Capsule().fill(lighting.accent.opacity(0.25)))
      .foregroundStyle(lighting.accent)
  }
}

/// `LabeledContent` in the row grammar: label leading, control trailing, the
/// same vertical rhythm `SettingRow` uses. Applied once by
/// `SettingsPageScaffold`, so a page's existing `LabeledContent` rows land in
/// the theme without being rewritten.
struct ThemedLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: 12) {
      configuration.label
        .foregroundStyle(SettingsTheme.titleColor)
      Spacer(minLength: 16)
      configuration.content
    }
    .padding(.vertical, 6)
  }
}

private struct ThemedSwitchModifier: ViewModifier {
  @Environment(\.settingsAccent) private var lighting

  func body(content: Content) -> some View {
    content
      .toggleStyle(.switch)
      .controlSize(.small)
      .tint(lighting.accent)
  }
}

extension View {
  /// A `Toggle` at settings weight: the native switch, small like System
  /// Settings uses, tinted by the destination. Labels are left alone; a row
  /// that wants its label hidden says so at its own call site, and the label
  /// still has to exist for VoiceOver.
  func themedSwitch() -> some View { modifier(ThemedSwitchModifier()) }
}
