import CandelaKit
import SwiftUI

/// The accent-lit slider: capsule track, glowing fill, draggable. Custom
/// because the system slider ignores the window's lighting entirely, so it
/// carries its own accessibility (SV6): call sites supply the label, this
/// supplies the value and the adjustable action.
///
/// It takes what the native `Slider` takes, so a settings row converting to it
/// keeps its semantics: a range, an optional step, a drag-boundary callback for
/// the rows that commit on release rather than per frame, and an accessibility
/// value for the rows whose stored number must never be spoken.
///
/// **Never bind this to a volume value (D29 rule 4).** It has no zero-free
/// grid, and volume 0 is a hardware mute over VCP 0x8D; a volume row keeps the
/// panel's `DisplaySliderRow`, which snaps and steps over
/// `SliderSnap.stopsWithoutZero`.
struct ThemedSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double> = 0...1
  /// Grid the value lands on, in value units. Nil is continuous.
  var step: Double?
  /// Overrides the spoken value where a percentage would be meaningless or
  /// where the stored number must not reach VoiceOver.
  var accessibilityValueText: String?
  /// True when a drag starts, false when it ends, so a row that writes a pref
  /// on release keeps one write per gesture. A keyboard or VoiceOver step is a
  /// whole gesture of its own and sends both.
  var onEditingChanged: ((Bool) -> Void)?

  @Environment(\.settingsAccent) private var lighting
  /// `@GestureState` and not `@State`: SwiftUI never calls `onEnded` for an
  /// interrupted drag, and a flag left true there would swallow the next
  /// drag's opening edge. This one resets itself on a cancel, so the editing
  /// session closes either way.
  @GestureState private var dragging = false

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.10))
          .frame(height: 5)
        Capsule()
          .fill(lighting.accent.opacity(0.85))
          .frame(width: max(5, width * fraction), height: 5)
        Circle()
          .fill(.white)
          .frame(width: 13, height: 13)
          .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
          .offset(x: max(0, (width - 13) * fraction))
      }
      .frame(height: proxy.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($dragging) { _, isDragging, _ in isDragging = true }
          .onChanged { gesture in
            value = valueAt(x: gesture.location.x, width: width)
          }
          .onEnded { gesture in
            value = valueAt(x: gesture.location.x, width: width)
          }
      )
    }
    .frame(height: 22)
    // Both edges come off the tracking flag rather than the two callbacks, so
    // they pair: an unopened `false` and a swallowed `true` are both
    // unreachable, and a cancelled drag still closes.
    .onChange(of: dragging) { _, isDragging in onEditingChanged?(isDragging) }
    // The track, the fill and the knob are one control, not three shapes.
    .accessibilityElement(children: .ignore)
    .accessibilityValue(Text(verbatim: accessibilityValueText ?? SliderSnap.percentText(fraction)))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: commitStep(up: true)
      case .decrement: commitStep(up: false)
      @unknown default: break
      }
    }
  }

  /// Position along the track, 0...1, whatever the value units are.
  private var fraction: Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(1, max(0, (value - range.lowerBound) / span))
  }

  private func valueAt(x: CGFloat, width: CGFloat) -> Double {
    // A zero-width layout pass makes the division NaN, and `min(1, max(0, NaN))`
    // resolves to 1: a drag on an unlaid-out track would write full scale.
    guard width > 0 else { return value }
    let span = range.upperBound - range.lowerBound
    let raw = range.lowerBound + span * min(1, max(0, Double(x / width)))
    guard let step, step > 0 else { return raw }
    let grid = ((raw - range.lowerBound) / step).rounded()
    return clamped(range.lowerBound + grid * step)
  }

  private func commitStep(up: Bool) {
    onEditingChanged?(true)
    value = stepped(up: up)
    onEditingChanged?(false)
  }

  /// One discrete step, on `SliderSnap`'s grid rather than a raw addition: it
  /// lands ON the grid in the direction of travel and keeps the anti-drift
  /// rounding, so repeated stepping cannot drift a grid point into a readout of
  /// 59%.
  ///
  /// `SliderSnap`'s grid is defined over 0...1, so the step is taken on the
  /// fraction and mapped back. Grid points are multiples of the step measured
  /// from the range's floor whatever the span.
  private func stepped(up: Bool) -> Double {
    let size = step ?? Self.defaultStep
    let span = range.upperBound - range.lowerBound
    guard span > 0, size > 0 else { return value }
    let moved = SliderSnap.stepped(
      from: fraction, up: up, step: size / span, toStops: false)
    // Onto the nearest grid point in value units: the round trip through the
    // fraction leaves a millionth of the span behind, which on a wide integer
    // range is the difference between -7 and -6.999995.
    let grid = ((moved * span) / size).rounded()
    return clamped(range.lowerBound + grid * size)
  }

  private func clamped(_ value: Double) -> Double {
    min(range.upperBound, max(range.lowerBound, value))
  }

  /// One VoiceOver nudge on a continuous slider, matching the panel sliders'
  /// feel rather than the pixel resolution of a drag.
  private static let defaultStep = 0.05
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

/// A pop-up at row weight: the label leads, the menu sits at the trailing edge.
///
/// The guarantee: a written label, the native `Picker`'s own value, and one
/// accessibility element carrying both, with a `prefIdentifier` attachable from
/// the call site.
///
/// The spread lives here because a `Picker` has no style point that can carry
/// it, the way the theme's switch style carries it for a `Toggle`. The row is
/// ONE accessibility element for the same reason the switch style is: the
/// written label and the chosen value have to land on the thing that changes,
/// and `SettingRow` attaches its caption as that element's hint. `combine`
/// keeps the pop-up's own action, which `ignore` would drop.
struct ThemedChoiceRow<Value: Hashable, Options: View>: View {
  let label: LocalizedStringKey
  @Binding var selection: Value
  @ViewBuilder let options: Options

  var body: some View {
    HStack(spacing: 12) {
      // Wraps rather than truncates: at large text sizes the pop-up keeps its
      // ideal width, so the label is the half that has to give.
      Text(label)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 16)
      Picker(selection: $selection) {
        options
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .fixedSize()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
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

/// The native switch under the destination tint, with the label held at the
/// leading edge and the switch at the trailing one.
///
/// The spread has to live in the style: a switch-style `Toggle` sits beside its
/// own label at its ideal width however wide a frame it is given, measured
/// 2026-08-20 against a rendered card.
private struct ThemedSwitchStyle: ToggleStyle {
  let accent: Color
  let spreads: Bool

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 12) {
      configuration.label
      if spreads {
        Spacer(minLength: 16)
      }
      Toggle(isOn: configuration.$isOn) { EmptyView() }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent)
    }
    // One row element, not a caption beside an unlabeled control: the row's
    // label, its safety sentence and its hint all have to land on the thing
    // that toggles. `combine` keeps the child's action, unlike `ignore`.
    .accessibilityElement(children: .combine)
  }
}

private struct ThemedSwitchModifier: ViewModifier {
  var spreads: Bool

  @Environment(\.settingsAccent) private var lighting

  func body(content: Content) -> some View {
    content.toggleStyle(ThemedSwitchStyle(accent: lighting.accent, spreads: spreads))
  }
}

extension View {
  /// A `Toggle` at settings weight: the native switch, small like System
  /// Settings uses, tinted by the destination, spanning the row with the switch
  /// at its trailing edge.
  ///
  /// The style draws the toggle's own label at the leading edge, so a row is
  /// written as `Toggle("Label", isOn:).themedSwitch()` and nothing else.
  /// `.labelsHidden()` has no effect here: it travels in an environment key no
  /// custom `ToggleStyle` can read, so a row that needs its label drawn
  /// somewhere else keeps the native `.switch` style instead.
  ///
  /// `spreads: false` for a switch that shares a row with something else and
  /// must keep its ideal width.
  func themedSwitch(spreads: Bool = true) -> some View {
    modifier(ThemedSwitchModifier(spreads: spreads))
  }
}
