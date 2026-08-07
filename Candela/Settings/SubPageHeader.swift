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

  var body: some View {
    HStack {
      Text(title)
        .font(.title3.weight(.semibold))
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
