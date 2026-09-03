import SwiftUI

/// A pushed sub-page's title row, with a switcher that swaps the SAME sub-page
/// onto another display when more than one is connected.
///
/// The switcher calls back with a persistence key and nothing else. The root
/// view owns what "switching" means; this view must not reach into navigation
/// state it does not own.
///
/// It also carries the page's way back, because the window hides the system
/// back item: macOS draws that at the WINDOW's leading edge, over the sidebar's
/// wordmark rather than over the column it acts on. Every pushed page opens
/// with this header, so the control being here is what makes every pushed page
/// have one.
///
/// On appearance the title takes the VoiceOver cursor, so a push announces the
/// page the user landed on rather than whatever element comes first. Pop focus
/// belongs to the pushing row.
@MainActor
struct SubPageHeader: View {
  let title: String
  let currentKey: String
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @AccessibilityFocusState private var titleFocused: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HStack {
      BackButton { dismiss() }
      Text(title)
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .foregroundStyle(SettingsTheme.titleColor)
        .settingsHeading()
        .accessibilityFocused($titleFocused)
      Spacer()
      if displays.count > 1 {
        Picker("Display", selection: Binding(get: { currentKey }, set: { onSwitch($0) })) {
          ForEach(displays, id: \.key) { display in
            // A display's name, never a lookup key.
            Text(verbatim: display.name).tag(display.key)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Display")
      }
    }
    .padding(.bottom, 4)
    .onAppear { titleFocused = true }
  }
}

/// A bare chevron in the window's own hover idiom, the same wash and curve
/// `NavigationRow` uses for the rows that push.
///
/// A plain `Button`, so it stays one accessibility element that keeps `AXPress`
/// and `AXFocused` and stays reachable by Tab. The label is spelled out because
/// SwiftUI does not publish a `Button`'s implicit label and a chevron has no
/// text to derive one from.
private struct BackButton: View {
  let action: () -> Void

  @State private var hovering = false
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(hovering ? lighting.accent : SettingsTheme.bodyColor)
        .frame(width: 22, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(SettingsTheme.hoverMotion, value: hovering)
    .accessibilityLabel(Text("Back"))
    // The shortcut has no other trace: the button carrying it is zero-size and
    // hidden from accessibility, and the window draws no menu item for it.
    .help(Text(verbatim: "Command ["))
  }
}
