import AppKit
import SwiftUI

/// The alert design language every keep-or-revert question is drawn in.
///
/// One language, because every one of them is the same question wearing
/// different words: an irreversible-looking change is in effect, keep it or
/// revert. Not merely cosmetic: the mirror window drew a grey primary for weeks
/// because it re-derived its buttons instead of sharing these.
///
/// Centred, icon-first and 340pt wide: the shape of a macOS alert, because that
/// is what these are. A leading-aligned card read as a tooltip, and a safety
/// question that reads as a tooltip gets treated like one.

/// The card. The icon is the app's own: nothing else on screen says WHO is
/// asking, and a screen that reconfigured itself is otherwise indistinguishable
/// from the display or macOS doing it.
struct ConfirmationCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
      content
    }
    .multilineTextAlignment(.center)
    .padding(24)
    .frame(width: 340)
  }
}

struct ConfirmationTitle: View {
  private let key: LocalizedStringKey
  init(_ key: LocalizedStringKey) { self.key = key }

  var body: some View {
    Text(key)
      .font(.title3.weight(.semibold))
      .multilineTextAlignment(.center)
  }
}

/// The line naming what changed. `Text` rather than a key on the second init:
/// a display's name and a refusal's payload are runtime values, and routing them
/// through a lookup key would translate the user's hardware.
struct ConfirmationSubtitle: View {
  private let text: Text
  init(_ text: Text) { self.text = text }
  init(verbatim string: String) { text = Text(verbatim: string) }

  var body: some View {
    text
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Same modifiers as a subtitle: the distinction is what it says, not how it
/// looks. One type means a caption built from a payload cannot end up styled
/// differently from a written one.
struct ConfirmationCaption: View {
  private let text: Text
  init(_ key: LocalizedStringKey) { text = Text(key) }
  init(_ text: Text) { self.text = text }

  var body: some View {
    ConfirmationSubtitle(text)
  }
}

/// A number that changes every second must not be able to change the WIDTH of
/// what it sits in, or the buttons below shuffle under the pointer once a
/// second.
struct ConfirmationCountdown: View {
  private let string: String
  init(_ string: String) { self.string = string }

  var body: some View {
    Text(verbatim: string)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .monospacedDigit()
  }
}

/// The answers, side by side and equally wide. Not trailing-aligned: at this
/// width a trailing row reads as a form's footer, which is the "easy to miss"
/// these windows were promoted to fix.
struct ConfirmationAnswers<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 10) {
      content
    }
    .padding(.top, 6)
  }
}

/// The two answers, drawn by us rather than by `.bordered` / `.borderedProminent`.
///
/// **`.borderedProminent` renders GREY in these windows and always will.**
/// Candela is an `.accessory` app that is essentially never the active
/// application, and AppKit draws controls in an inactive app in their inactive
/// appearance: the two answers came out visually identical [MEASURED
/// 2026-08-04]. `controlAccentColor` does not dim with activation, so asking for
/// it directly is the only thing that survives.
///
/// Both answers share one style so the two capsules cannot end up different
/// heights, which is what happened when only the primary was custom. Hover and
/// pressed states are required of any custom button (`buttons.md`), and these
/// reconfigure a screen, so a click that feels unregistered invites a second one.
struct AnswerButtonStyle: ButtonStyle {
  let isPrimary: Bool

  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration, isPrimary: isPrimary)
  }

  /// Hover state on a real `View`: SwiftUI does not reliably install dynamic
  /// properties declared on a `ButtonStyle`, and the answers went dead to hover.
  private struct HoverLabel: View {
    let configuration: Configuration
    let isPrimary: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      configuration.label
        .font(.body.weight(isPrimary ? .semibold : .regular))
        .foregroundStyle(isPrimary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        // A long answer ("Stop Mirroring Now") must shrink rather than truncate:
        // a clipped verb on a safety prompt is worse than a small one.
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill(pressed: configuration.isPressed))
        )
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private func fill(pressed: Bool) -> AnyShapeStyle {
      if isPrimary {
        let accent = Color(nsColor: .controlAccentColor)
        return AnyShapeStyle(accent.opacity(pressed ? 0.7 : (isHovering ? 0.88 : 1)))
      }
      if pressed { return AnyShapeStyle(.tertiary) }
      return AnyShapeStyle(isHovering ? AnyShapeStyle(.secondary.opacity(0.35)) : AnyShapeStyle(.quaternary))
    }
  }
}
