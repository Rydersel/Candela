import CandelaKit
import SwiftUI

/// Mode-list support shared across the settings surfaces.
///
/// The `DisplayModeSection` view that used to live here was absorbed into
/// `DisplayHubView` (Task 13): its size/refresh pickers and remember row are
/// the hub's Display section now, and its 120–332-row disclosure list becomes
/// the All Sizes & Refresh Rates sub-page (Task 14). What remains is the pieces
/// more than one surface needs.

/// The CoreGraphics code stays out of the sentence and goes in a tooltip — it
/// is diagnostic, and belongs nowhere near text someone reads while working out
/// what happened to their screen. Only a `.failed` notice has one: for a
/// substitution or an unavailable mode there is no error, and an empty tooltip
/// would suggest there was.
struct ReapplyDiagnostic: ViewModifier {
  let notice: ModeReapplyNotice

  @ViewBuilder func body(content: Content) -> some View {
    if case let .failed(error) = notice {
      content.help("CoreGraphics error \(error.cgErrorCode)")
    } else {
      content
    }
  }
}

/// One selectable mode in the full list. A row-shaped button: the whole row is
/// the hit region (a bare `.plain` button is only as clickable as its text is
/// wide), and it carries hover and pressed states, without which it reads as
/// static text.
///
/// Internal rather than private so the All Sizes & Refresh Rates sub-page
/// (Task 14) renders its rows through the same component the disclosure list
/// used.
struct ModeChoice: View {
  let title: String
  let detail: String?
  let isCurrent: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .opacity(isCurrent ? 1 : 0)
          .accessibilityHidden(true)
        Text(verbatim: title)
        if let detail {
          Text(verbatim: detail)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(ModeChoiceButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}

/// Hover and — required for any custom button (`buttons.md`) — a pressed state.
/// Without one the row feels unresponsive and people wonder whether the click
/// registered, which on a control that reconfigures the screen invites a second
/// click.
private struct ModeChoiceButtonStyle: ButtonStyle {
  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(fill(pressed: configuration.isPressed))
      )
      .opacity(configuration.isPressed ? 0.85 : 1)
  }

  private func fill(pressed: Bool) -> AnyShapeStyle {
    if pressed { return AnyShapeStyle(.quaternary) }
    return isHovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)
  }
}
