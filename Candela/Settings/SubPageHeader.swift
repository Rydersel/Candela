import SwiftUI

/// A pushed sub-page's title row: the page name, and — when more than one
/// display is connected — a switcher that swaps the SAME sub-page onto another
/// display (SO23, the comparison workflow: stand on Advanced, flip between
/// panels).
///
/// The switcher calls back with a persistence key and nothing else. The root
/// view owns what "switching" means (carry the path, move the sidebar
/// selection); this view must not reach into navigation state it does not own.
///
/// It also carries the page's way back. The window hides the system back item,
/// which macOS draws at the WINDOW's leading edge: over the sidebar's wordmark
/// rather than over the column it acts on, in chrome the rest of this window
/// does not have. Every pushed page opens with this header, so putting the
/// control here is what makes "every pushed page has a back control" true by
/// construction. Cmd-[ and re-clicking the sidebar row still work; they write
/// the path, and this asks the stack.
///
/// On appearance the title takes the VoiceOver cursor (accessibility contract
/// 1's push half): a push announces the page the user landed on, not whatever
/// element happens to be first. Pop focus is the pushing row's job, owned by
/// the hub (Task 13).
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
            // A display's name — never a lookup key.
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

/// The page's back control, in the window's own hover idiom rather than the
/// system's chrome: a bare chevron that lights on hover, the same wash and the
/// same curve `NavigationRow` uses for the rows that push.
///
/// A plain `Button`, so it is one accessibility element that keeps `AXPress`
/// and `AXFocused` and stays reachable by Tab. The label is written out because
/// SwiftUI does not publish a `Button`'s implicit label, and a chevron has no
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
  }
}
