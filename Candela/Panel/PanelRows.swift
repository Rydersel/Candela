import CoreGraphics
import SwiftUI

/// THE one open disclosure in the panel: which display, and which of that
/// display's sections.
///
/// A `CGDirectDisplayID?` is NOT enough. Both of a display's disclosures compare
/// the shared binding against that display's own id, so opening either makes the
/// other's test true and the panel opens two lists on one display at once. The
/// pair is what makes "at most one disclosure is open anywhere in the panel"
/// hold across displays AND across sections of one display.
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
/// Shared rather than copied per section: the two sections sit directly on top
/// of each other in one display's block, so any drift in height, inset or hover
/// fill reads as a rendering bug.
///
/// Nothing here knows what a display or a topology is, which is what lets both
/// sections use these shapes without either one owning the other.

/// Hover plus a distinct pressed state, required for any custom button
/// (`buttons.md`), in the same visual language as the panel's footer buttons.
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

/// The collapsed header of a panel disclosure: a title, the current value and a
/// chevron, the shape Control Center uses for a module that opens.
struct PanelDisclosureRow: View {
  let title: LocalizedStringKey
  let detail: String?
  /// The spoken form of `detail`, when the written one is not sayable: a mode
  /// summary is "2,560 by 1,440 at 60 hertz", never "2560 × 1440 · 60 Hz".
  /// Defaults to `detail`, so a row whose value is already words says nothing
  /// twice.
  var spokenDetail: String?
  /// Owns the row for VoiceOver. Every other row in the panel announces itself
  /// as "<display> brightness" or "<display> volume"; without the same prefix a
  /// multi-display rig reads out "Resolution" once per display with no way to
  /// tell them apart.
  let accessibilityName: String
  /// The noun that follows the display name: "resolution", "mirroring". A
  /// parameter rather than the title, because the title is a `LocalizedStringKey`
  /// and there is no supported way to read the words back out of one:
  /// `String(describing:)` yields the key's structure, which VoiceOver would then
  /// read aloud verbatim.
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
        // One glyph rotated, not an up/down symbol swap: rotation rides the
        // same animation as the disclosure toggle, and a swap cannot.
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 180 : 0))
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
    .accessibilityValue(Text(verbatim: spokenDetail ?? detail ?? ""))
  }
}

/// A sentence about something that did not happen, with the OK that dismisses
/// it on the same baseline.
///
/// Takes a built `Text` because the reports differ only in how their words are
/// made, some from a `LocalizedStringKey` and some from an interpolated `String`.
/// Padding and any `.help(…)` stay at the call site: the row sits inside a list
/// on one surface and under a status line on another.
struct PanelReportRow: View {
  let text: Text
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      text
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("OK", action: dismiss)
        .buttonStyle(.link)
        .font(.system(size: 11))
        .fixedSize()
    }
  }
}

/// Explanatory text under a panel disclosure. The hierarchy level is a
/// parameter: a caption under a list of choices sits a step further back than
/// one carrying a refusal.
struct PanelCaption: View {
  let text: LocalizedStringKey
  let style: HierarchicalShapeStyle

  init(_ text: LocalizedStringKey, style: HierarchicalShapeStyle) {
    self.text = text
    self.style = style
  }

  var body: some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(style)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)
  }
}

/// One action inside an open disclosure. A row-shaped button: the whole row is
/// the hit region (a bare `.plain` button is only as clickable as its text is
/// wide), with hover and pressed states, without which it reads as static text.
/// On a control that reconfigures the screen, a click that feels unregistered
/// invites a second.
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
