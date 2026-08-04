import CoreGraphics
import SwiftUI

/// THE one open disclosure in the panel — which display, and which of that
/// display's sections.
///
/// A `CGDirectDisplayID?` is NOT enough, and the difference is not theoretical:
/// both of a display's disclosures compare the shared binding against that
/// display's own id, so opening either one makes the other's test true as well
/// and the panel opens two lists on the same display at once. The pair is what
/// makes "at most one disclosure is open anywhere in the panel" actually hold,
/// in both directions — across displays AND across sections of one display.
struct PanelDisclosureID: Hashable {
  enum Section: Hashable { case resolution, mirroring }

  let displayID: CGDirectDisplayID
  let section: Section

  init(_ displayID: CGDirectDisplayID, _ section: Section) {
    self.displayID = displayID
    self.section = section
  }
}

/// The row vocabulary shared by every disclosure the menu-bar panel offers.
///
/// Lifted out of `PanelResolutionSection`, where these were private, when
/// mirroring needed the same shapes. A second copy was the alternative and it is
/// the wrong one twice over: the two sections sit directly on top of each other
/// in the same display's block, so any drift in height, inset or hover fill
/// reads as a rendering bug rather than as a difference; and the phantom-hover
/// fix below is the kind of correction that gets made once and forgotten in the
/// copy.
///
/// Nothing here knows what a display or a topology is. These are the panel's
/// button shapes and nothing more — which is what lets both sections use them
/// without either one owning the other.

/// Hover plus — required for any custom button (`buttons.md`) — a distinct
/// pressed state, in the same visual language as the panel's footer buttons.
struct PanelRowButtonStyle: ButtonStyle {
  let isHovering: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let hovering = isHovering && isEnabled
    let background: AnyShapeStyle = if configuration.isPressed, isEnabled {
      AnyShapeStyle(.tertiary)
    } else if hovering {
      AnyShapeStyle(.quaternary)
    } else {
      AnyShapeStyle(.clear)
    }
    return configuration.label
      .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

/// The collapsed header of a panel disclosure: a title, the current value, and a
/// chevron — the shape Control Center uses for a module that opens.
struct PanelDisclosureRow: View {
  let title: LocalizedStringKey
  let detail: String?
  /// Owns the row for VoiceOver. Every other row in the panel announces itself
  /// as "<display> brightness" / "<display> volume"; without the same prefix a
  /// four-display rig reads out "Resolution" — or "Mirroring" — four times with
  /// no way to tell which display is being described.
  let accessibilityName: String
  /// The noun that follows the display name: "resolution", "mirroring". A
  /// parameter rather than the title, because the title is a
  /// `LocalizedStringKey` and there is no supported way to read the words back
  /// out of one. (`String(describing:)` yields the key's *structure* —
  /// `LocalizedStringKey(key: "Mirroring", …)` — which VoiceOver would then read
  /// aloud verbatim.)
  let accessibilityRole: String
  let isExpanded: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 12))
        Spacer(minLength: 8)
        if let detail {
          Text(verbatim: detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 4)
      .frame(height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(PanelRowButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // The menu can close without a mouse-exit event (Escape, or clicking the
    // status item), which would leave a phantom highlight on the next open.
    .onDisappear { isHovering = false }
    .accessibilityLabel(Text(verbatim: "\(accessibilityName) \(accessibilityRole)"))
    .accessibilityValue(Text(verbatim: detail ?? ""))
  }
}

/// One action inside an open disclosure. A row-shaped button: the whole row is
/// the hit region (a bare `.plain` button is only as clickable as its text is
/// wide), with hover and pressed states, without which it reads as static text —
/// and on a control that reconfigures the screen, a click that feels
/// unregistered invites a second one.
///
/// Distinct from `PanelModeRow` in that it carries no checkmark: these are
/// verbs ("Start Mirroring"), not a list of states one of which is current.
struct PanelActionRow: View {
  let title: LocalizedStringKey
  /// Same rule as `PanelDisclosureRow`: a bare "Start Mirroring" told nobody
  /// which display it would change. The name goes FIRST and the title is
  /// concatenated as a `Text`, so the words stay localizable and are never
  /// reconstructed from the key.
  let accessibilityName: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 12))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, 4)
      .padding(.trailing, 6)
      .frame(height: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(PanelRowButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    .onDisappear { isHovering = false }
    .accessibilityLabel(Text(verbatim: "\(accessibilityName), ") + Text(title))
  }
}
