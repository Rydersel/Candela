import CandelaKit
import SwiftUI

/// A drawn slider, because the system slider ignores the window's lighting.
/// Being drawn, it carries its own accessibility: a native `Slider`
/// stands in for the role, the value and the adjustable actions, and call sites
/// supply the label.
///
/// Pointer, VoiceOver and keyboard all go through the same grid and the same
/// editing edges. Disabled means dimmed and inert on all three, which a drawn
/// control has to say for itself; nothing greys it for us.
///
/// **Never bind this to a volume value.** It has no zero-free
/// grid, and volume 0 is a hardware mute over VCP 0x8D. A volume row keeps the
/// panel's `DisplaySliderRow`, which steps over `SliderSnap.stopsWithoutZero`.
struct ThemedSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double> = 0...1
  /// Grid the value lands on, in value units. Nil is continuous.
  var step: Double?
  /// Overrides the spoken value where a percentage would be meaningless or
  /// where the stored number must not reach VoiceOver.
  var accessibilityValueText: String?
  /// True when a drag starts, false when it ends, so a row writing a pref on
  /// release keeps one write per gesture. A keyboard or VoiceOver step is a
  /// whole gesture of its own and sends both.
  var onEditingChanged: ((Bool) -> Void)?

  @Environment(\.settingsAccent) private var lighting
  @Environment(\.isEnabled) private var isEnabled
  /// `@GestureState`, not `@State`: SwiftUI never calls `onEnded` for an
  /// interrupted drag, and a flag stuck true would swallow the next drag's
  /// opening edge. This resets itself on a cancel.
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
          // Explicit: `.disabled` greys the native slider beside this one and
          // does nothing to a `DragGesture`.
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
    // On the whole control, so track, knob and padding are all exempt. Without
    // it AppKit takes every mouse-down here for a window drag before the
    // gesture above can open; `minimumDistance: 0` does not help, because the
    // decision is made a layer below SwiftUI.
    .blocksWindowDrag()
    // Nothing greys a drawn control, so paint the button styles' dimming here.
    .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
    // Both edges come off the tracking flag rather than the two callbacks, so
    // they always pair and a cancelled drag still closes.
    .onChange(of: dragging) { _, isDragging in onEditingChanged?(isDragging) }
    // Arrows step through the same commit path every other route uses: one
    // write per keypress, on the grid. A drawn ring, since the system's has no
    // shape to trace on a view made of loose capsules. Unfocusable while
    // disabled, so no key handler runs and no ring draws around a dead control.
    .focusable(isEnabled)
    .focused($focused)
    .overlay(focusRing)
    .onKeyPress(.leftArrow) { commitStep(up: false); return .handled }
    .onKeyPress(.downArrow) { commitStep(up: false); return .handled }
    .onKeyPress(.rightArrow) { commitStep(up: true); return .handled }
    .onKeyPress(.upArrow) { commitStep(up: true); return .handled }
    // A real slider stands in, so AX gets a native slider's role, value,
    // adjustable actions and focusability. NOT a synthesized element: measured
    // 2026-08-20 against the live app, `children: .ignore` published the label,
    // the value and both adjust actions but no `AXFocused` at all. The binding
    // takes only the DIRECTION of the proposed value and turns it into one step
    // on the grid, so no route here can write a raw value.
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

  /// The one gate the keyboard and the representation share, so a disabled
  /// control cannot open an editing cycle at all.
  private func commitStep(up: Bool) {
    guard isEnabled else { return }
    onEditingChanged?(true)
    value = stepped(up: up)
    onEditingChanged?(false)
  }

  /// On `SliderSnap`'s grid rather than a raw addition, which keeps the
  /// anti-drift rounding: repeated stepping cannot turn a grid point into a
  /// readout of 59%. The grid is defined over 0...1, so the step is taken on
  /// the fraction and mapped back.
  private func stepped(up: Bool) -> Double {
    let size = step ?? Self.defaultStep
    let span = range.upperBound - range.lowerBound
    guard span > 0, size > 0 else { return value }
    let moved = SliderSnap.stepped(
      from: fraction, up: up, step: size / span, toStops: false)
    // The round trip through the fraction leaves a millionth of the span
    // behind, which on a wide integer range is -6.999995 instead of -7.
    let grid = ((moved * span) / size).rounded()
    return clamped(range.lowerBound + grid * size)
  }

  private func clamped(_ value: Double) -> Double {
    min(range.upperBound, max(range.lowerBound, value))
  }

  /// One VoiceOver nudge on a continuous slider, matching the panel sliders
  /// rather than the pixel resolution of a drag.
  private static let defaultStep = 0.05
}

/// Segmented choice shaped like the macOS segmented control, accent-tinted.
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
    // A native segmented control would tell AppKit this is not a drag handle;
    // a drawn one has to say so itself.
    .blocksWindowDrag()
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
      // SwiftUI does not publish a `Button` title to accessibility, so without
      // this every segment announces as "button". Here so no call site can forget.
      .accessibilityLabel(Text(verbatim: label))
      // Selection is carried by weight and fill, neither of which a screen
      // reader can see.
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

/// A pop-up at row weight, label leading. The spread lives here because a
/// `Picker` has no style point to carry it the way a `Toggle` does.
///
/// The pop-up stays the row's ONE accessibility element: the written label
/// moves onto it and the drawn `Text` leaves the tree. Never merge the two with
/// `children: .combine`. Measured 2026-08-20 on the switch style, a combined
/// element keeps `AXPress` and loses `AXFocused`, dropping the row out of the
/// Tab order.
struct ThemedChoiceRow<Value: Hashable, Options: View>: View {
  let label: LocalizedStringKey
  @Binding var selection: Value
  @ViewBuilder let options: Options

  @Environment(\.settingsRowIsPadded) private var rowIsPadded
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 12) {
      // Wraps rather than truncates: at large text sizes the pop-up keeps its
      // ideal width, so the label has to give.
      Text(label)
        .fixedSize(horizontal: false, vertical: true)
        // The theme's colour rather than whatever it inherits: the label is
        // drawn beside the pop-up, so nothing else dims it when disabled.
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
      // The control only. The label and the gap beside it stay window-drag
      // handles like the rest of the card's deadspace.
      .blocksWindowDrag()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Own rhythm on the card, none when a row wrapper already gave it one.
    .padding(.vertical, rowIsPadded ? 0 : SettingsTheme.rowVerticalPadding)
  }
}

/// `LabeledContent` in the row grammar. `SettingsPageScaffold` applies it once,
/// so a page's existing `LabeledContent` rows land in the theme unrewritten.
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
        // Colour rather than opacity: this slot sometimes holds a control,
        // which dims itself and must not be dimmed twice. A text field is the
        // exception and opts out with `settingsEditableContent()`, since it
        // honours an inherited foreground style.
        configuration.content
          .foregroundStyle(dimmed(SettingsTheme.bodyColor))
      }
      // Nothing when `SettingRow` already padded this row; the two together
      // ran rows to twice the height of their neighbours.
      .padding(.vertical, rowIsPadded ? 0 : SettingsTheme.rowVerticalPadding)
    }

    private func dimmed(_ color: Color) -> Color {
      isEnabled ? color : color.opacity(SettingsTheme.disabledOpacity)
    }
  }
}

extension View {
  /// Marks a `LabeledContent`'s content as something a person types into, so
  /// it keeps the system text colour and dims once, natively.
  ///
  /// Opt-in at the call site rather than in `ThemedLabeledContentStyle`, which
  /// cannot tell a field from a value. A field added later then renders
  /// visibly wrong rather than invisibly wrong.
  func settingsEditableContent() -> some View { foregroundStyle(Color.primary) }
}

/// The native switch under the destination tint, label leading.
///
/// The spread has to live in the style: measured 2026-08-20 against a rendered
/// card, a switch-style `Toggle` sits beside its own label at its ideal width
/// however wide a frame it is given.
private struct ThemedSwitchStyle: ToggleStyle {
  let accent: Color
  let spreads: Bool

  func makeBody(configuration: Configuration) -> some View {
    Row(configuration: configuration, accent: accent, spreads: spreads)
      // A real labeled toggle stands in, so the element is focusable,
      // pressable and named. NOT `children: .combine`: measured 2026-08-20
      // against the live app, a combined element keeps `AXPress` and loses
      // `AXFocused`, dropping every switch row out of the Tab order. The inner
      // style is explicit or this style recurses into itself.
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
        // Drawn outside the switch, which is why nothing else dims it.
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
          // The switch only. The label and the spread beside it stay
          // window-drag handles.
          .blocksWindowDrag()
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
  /// The style draws the toggle's own label at the leading edge, so a row is
  /// written as `Toggle("Label", isOn:).themedSwitch()` and nothing else.
  /// `.labelsHidden()` has no effect here: it travels in an environment key no
  /// custom `ToggleStyle` can read, so a row needing its label drawn elsewhere
  /// keeps the native `.switch` style.
  ///
  /// `spreads: false` for a switch sharing a row with something else, which
  /// must keep its ideal width.
  func themedSwitch(spreads: Bool = true) -> some View {
    modifier(ThemedSwitchModifier(spreads: spreads))
  }
}
