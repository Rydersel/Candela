import CandelaKit
import SwiftUI

/// The accent-lit slider: capsule track, glowing fill, draggable. Custom
/// because the system slider ignores the window's lighting entirely, so it
/// carries its own accessibility (SV6): call sites supply the label, and a
/// native `Slider` stands in for the drawn one to supply the role, the value
/// and the adjustable actions.
///
/// It takes what the native `Slider` takes, so a settings row converting to it
/// keeps its semantics: a range, an optional step, a drag-boundary callback for
/// the rows that commit on release rather than per frame, and an accessibility
/// value for the rows whose stored number must never be spoken.
///
/// It is operable by pointer, by VoiceOver and by the keyboard: Tab reaches it,
/// the arrow keys step it, and all three routes go through the same grid and
/// the same editing edges.
///
/// Disabled means dimmed and inert on every route: the track takes no drag,
/// the keyboard cannot reach it, and no write lands from the representation
/// either. A drawn control has to say that itself; nothing greys it for us.
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
  @Environment(\.isEnabled) private var isEnabled
  /// `@GestureState` and not `@State`: SwiftUI never calls `onEnded` for an
  /// interrupted drag, and a flag left true there would swallow the next
  /// drag's opening edge. This one resets itself on a cancel, so the editing
  /// session closes either way.
  @GestureState private var dragging = false
  @FocusState private var focused: Bool

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
          // Explicit, because a gesture on a drawn view is not a control:
          // `.disabled` greys the native slider beside this one and does
          // nothing to a `DragGesture`.
          .onChanged { gesture in
            guard isEnabled else { return }
            value = valueAt(x: gesture.location.x, width: width)
          }
          .onEnded { gesture in
            guard isEnabled else { return }
            value = valueAt(x: gesture.location.x, width: width)
          }
      )
    }
    .frame(height: 22)
    // Nothing greys a drawn control: the same dimming the theme's button styles
    // paint, so a slider inside a blocked section reads like its neighbours.
    .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
    // Both edges come off the tracking flag rather than the two callbacks, so
    // they pair: an unopened `false` and a swallowed `true` are both
    // unreachable, and a cancelled drag still closes.
    .onChange(of: dragging) { _, isDragging in onEditingChanged?(isDragging) }
    // The arrows move it, through the same stepping and committing path every
    // other route uses: one write per keypress, on the grid. A drawn ring
    // rather than the system's, which has no shape to trace on a view made of
    // loose capsules. Unfocusable while disabled, so no key handler can run and
    // no ring can draw around a control that does nothing.
    .focusable(isEnabled)
    .focused($focused)
    .overlay(focusRing)
    .onKeyPress(.leftArrow) { commitStep(up: false); return .handled }
    .onKeyPress(.downArrow) { commitStep(up: false); return .handled }
    .onKeyPress(.rightArrow) { commitStep(up: true); return .handled }
    .onKeyPress(.upArrow) { commitStep(up: true); return .handled }
    // A real slider stands in for the drawn one, so AX gets a native slider's
    // role, value, adjustable actions and focusability. NOT a synthesized
    // element: measured 2026-08-20 against the live app, `children: .ignore`
    // published the label, the value and both adjust actions but no
    // `AXFocused` at all, the same half of the lesson the switch style
    // learned. The binding takes only the DIRECTION of whatever value the
    // representation proposes and turns it into one step on the grid with its
    // editing cycle around it, so no route here can write a raw value.
    .accessibilityRepresentation {
      Slider(value: steppedBinding, in: representableRange)
        .accessibilityValue(Text(verbatim: spokenValue))
    }
  }

  private var spokenValue: String {
    accessibilityValueText ?? SliderSnap.percentText(fraction)
  }

  private var steppedBinding: Binding<Double> {
    Binding(
      get: { value },
      set: { proposed in
        guard proposed != value else { return }
        commitStep(up: proposed > value)
      })
  }

  /// A native `Slider` traps on an empty range; the drawn one merely holds
  /// still.
  private var representableRange: ClosedRange<Double> {
    range.upperBound > range.lowerBound ? range : range.lowerBound...(range.lowerBound + 1)
  }

  @ViewBuilder private var focusRing: some View {
    if focused {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(lighting.accent.opacity(0.8), lineWidth: 2)
        .padding(-3)
        .accessibilityHidden(true)
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

  /// The one gate the keyboard and the representation share: both routes end
  /// here, so a disabled control cannot open an editing cycle at all.
  private func commitStep(up: Bool) {
    guard isEnabled else { return }
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
/// it, the way the theme's switch style carries it for a `Toggle`.
///
/// The pop-up stays the row's one element and keeps its own accessibility: the
/// written label moves onto it and the drawn `Text` leaves the tree. Merging
/// the two with `children: .combine` is what this row must NOT do: measured
/// 2026-08-20 on the switch style, a combined element keeps `AXPress` and
/// loses `AXFocused`, so the row falls out of the Tab order entirely.
struct ThemedChoiceRow<Value: Hashable, Options: View>: View {
  let label: LocalizedStringKey
  @Binding var selection: Value
  @ViewBuilder let options: Options

  @Environment(\.settingsRowIsPadded) private var rowIsPadded
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 12) {
      // Wraps rather than truncates: at large text sizes the pop-up keeps its
      // ideal width, so the label is the half that has to give.
      Text(label)
        .fixedSize(horizontal: false, vertical: true)
        // The theme's own colour rather than whatever it inherits, since this
        // row stands on a card as often as it sits inside a `SettingRow`. It
        // is drawn beside the pop-up rather than inside it, so nothing dims it
        // when the row is disabled except this.
        .foregroundStyle(
          isEnabled
            ? SettingsTheme.titleColor
            : SettingsTheme.titleColor.opacity(SettingsTheme.disabledOpacity))
        .accessibilityHidden(true)
      Spacer(minLength: 16)
      Picker(selection: $selection) {
        options
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .fixedSize()
      .accessibilityLabel(Text(label))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Its own rhythm when it stands on the card, none when a row wrapper
    // already gave it one.
    .padding(.vertical, rowIsPadded ? 0 : SettingsTheme.rowVerticalPadding)
  }
}

/// `LabeledContent` in the row grammar: label leading, control trailing, the
/// same vertical rhythm `SettingRow` uses. Applied once by
/// `SettingsPageScaffold`, so a page's existing `LabeledContent` rows land in
/// the theme without being rewritten.
struct ThemedLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    Row(configuration: configuration)
  }

  private struct Row: View {
    let configuration: Configuration
    @Environment(\.settingsRowIsPadded) private var rowIsPadded
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      HStack(alignment: .center, spacing: 12) {
        configuration.label
          .foregroundStyle(dimmed(SettingsTheme.titleColor))
        Spacer(minLength: 16)
        // A value is quieter than the label naming it. Colour rather than
        // opacity, because this slot sometimes holds a control, which dims
        // itself and must not be dimmed twice. A control a person TYPES into
        // is the exception and says so with `settingsEditableContent()`: a
        // text field honours an inherited foreground style, so it would take
        // both the secondary weight and, disabled, a second dimming on top of
        // AppKit's own.
        configuration.content
          .foregroundStyle(dimmed(SettingsTheme.bodyColor))
      }
      // Nothing when `SettingRow` already padded this row: the two together
      // are what made twelve rows in the window twice the height of their
      // neighbours.
      .padding(.vertical, rowIsPadded ? 0 : SettingsTheme.rowVerticalPadding)
    }

    private func dimmed(_ color: Color) -> Color {
      isEnabled ? color : color.opacity(SettingsTheme.disabledOpacity)
    }
  }
}

extension View {
  /// Marks the content of a `LabeledContent` as something a person types into,
  /// so it keeps the system's own text colour and dims once, natively.
  ///
  /// The exemption lives here at the two call sites rather than in
  /// `ThemedLabeledContentStyle`, which cannot tell a field from a value: the
  /// style keeps its default, so a value row added later cannot silently lose
  /// its weight, and a field added later renders visibly wrong rather than
  /// invisibly wrong.
  func settingsEditableContent() -> some View { foregroundStyle(Color.primary) }
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
    Row(configuration: configuration, accent: accent, spreads: spreads)
      // A real labeled toggle stands in for the drawn row, so the element is
      // focusable, pressable and named. NOT `children: .combine`: measured
      // 2026-08-20 against the live app, a combined element keeps `AXPress`
      // and loses `AXFocused`, which drops every switch row out of the Tab
      // order. The inner style is explicit because this style is still in the
      // environment here and would otherwise recurse into itself.
      .accessibilityRepresentation {
        Toggle(isOn: configuration.$isOn) { configuration.label }
          .toggleStyle(.switch)
      }
  }

  private struct Row: View {
    let configuration: Configuration
    let accent: Color
    let spreads: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      HStack(spacing: 12) {
        // The label is drawn outside the switch, which is the whole point of
        // the style and also why nothing else dims it.
        configuration.label
          .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
        if spreads {
          Spacer(minLength: 16)
        }
        Toggle(isOn: configuration.$isOn) { EmptyView() }
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .tint(accent)
      }
    }
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
