import SwiftUI

/// Shared styling for the guided setup flow. The window is forced dark
/// so these paint explicit whites over the canvas rather than
/// semantic colors that would follow a theme the window never shows.
enum OnboardingStyle {
  static let titleColor = Color.white
  static let bodyColor = Color.white.opacity(0.68)
  static let faintColor = Color.white.opacity(0.42)
  static let cardFill = Color.white.opacity(0.055)
  static let cardStroke = Color.white.opacity(0.10)
}

/// The one prominent control per page: a glowing accent capsule whose glow
/// lifts slightly on hover.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
  var accent: Color

  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration, accent: accent)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    let accent: Color
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 11)
        .background(
          Capsule()
            .fill(
              LinearGradient(
                colors: [accent.opacity(hovering ? 1 : 0.95), accent.opacity(hovering ? 0.75 : 0.65)],
                startPoint: .top, endPoint: .bottom
              )
            )
        )
        .overlay(Capsule().stroke(.white.opacity(hovering ? 0.4 : 0.25), lineWidth: 0.5))
        .shadow(
          color: accent.opacity(configuration.isPressed ? 0.25 : (hovering ? 0.7 : 0.55)),
          radius: hovering ? 18 : 14, y: 4
        )
        .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}

/// Quiet secondary action: a hairline capsule that brightens on hover so it
/// reads as clickable before it is clicked.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.callout.weight(.medium))
        .foregroundStyle(hovering ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(
          Capsule().fill(
            Color.white.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.10 : 0.06)))
        )
        .overlay(Capsule().stroke(Color.white.opacity(hovering ? 0.28 : 0.14), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}

/// Bare text link. Hover gives it a faint capsule and brightens the text;
/// without that it reads as a caption rather than a control.
struct OnboardingLinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.callout)
        .foregroundStyle(
          configuration.isPressed
            ? OnboardingStyle.titleColor
            : (hovering ? OnboardingStyle.bodyColor : OnboardingStyle.faintColor)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}

/// The rounded translucent surface page content sits on when it needs a
/// surface at all.
struct OnboardingCard<Content: View>: View {
  var isSelected = false
  var accent: Color = .white
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isSelected ? accent.opacity(0.12) : OnboardingStyle.cardFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isSelected ? accent.opacity(0.65) : OnboardingStyle.cardStroke,
            lineWidth: isSelected ? 1.5 : 1
          )
      )
  }
}

/// Layout arithmetic for the two pages that draw one item per display, derived
/// from the count and the available width so it can be checked without laying
/// a view out.
enum OnboardingCardGrid {
  static let cardSpacing: CGFloat = 14
  static let rowInset: CGFloat = 30

  static let baseGlyphSpacing: CGFloat = 34
  static let minimumGlyphSpacing: CGFloat = 12
  static let minimumGlyphHeight: CGFloat = 60

  /// `DisplayGlyph` gives the stand 12% of its height and the reflection 18%,
  /// leaving 70% for the face, which is the part the aspect ratio widens.
  private static let faceHeightFraction: CGFloat = 0.7
  /// Room either side of the face, and the width a portrait panel never goes
  /// under.
  private static let glyphPadding: CGFloat = 20
  private static let minimumGlyphWidth: CGFloat = 70

  /// One row up to three cards. A fourth wraps two by two rather than stranding
  /// one, and anything wider still wraps at three, the widest row that stays
  /// readable at this window width.
  static func columns(for count: Int) -> Int {
    guard count > 3 else { return max(1, count) }
    return count == 4 ? 2 : 3
  }

  static func gridColumns(for count: Int, maxCardWidth: CGFloat) -> [GridItem] {
    Array(
      repeating: GridItem(.flexible(maximum: maxCardWidth), spacing: cardSpacing, alignment: .top),
      count: columns(for: count))
  }

  static func glyphWidth(aspect: CGFloat, height: CGFloat) -> CGFloat {
    max(minimumGlyphWidth, height * faceHeightFraction * aspect + glyphPadding)
  }

  static func totalWidth(height: CGFloat, spacing: CGFloat, aspects: [CGFloat]) -> CGFloat {
    guard !aspects.isEmpty else { return 0 }
    let glyphs = aspects.reduce(0) { $0 + glyphWidth(aspect: $1, height: height) }
    return glyphs + spacing * CGFloat(aspects.count - 1)
  }

  /// The height and spacing the glyph row draws at so the whole rig fits the
  /// width it has. Spacing gives way first, then the panels shrink.
  ///
  /// The row's clip is there to contain the sweep band, and this keeps it from
  /// doubling as the thing hiding a panel: at a fixed height four ultrawides ask
  /// for about 918 pt inside a 760 pt window, and the two outermost were being
  /// cut with nothing on screen saying so.
  ///
  /// A rig wide enough to overflow both base heights fits the scan and the cards
  /// states to the same height, so the row loses its scan-to-cards size change.
  /// Four ultrawide panels already do it.
  static func glyphMetrics(aspects: [CGFloat], availableWidth: CGFloat, baseHeight: CGFloat)
    -> (height: CGFloat, spacing: CGFloat)
  {
    guard !aspects.isEmpty, availableWidth > 0 else { return (baseHeight, baseGlyphSpacing) }
    if totalWidth(height: baseHeight, spacing: baseGlyphSpacing, aspects: aspects)
      <= availableWidth
    {
      return (baseHeight, baseGlyphSpacing)
    }
    // Crowding the panels costs less than shrinking them, so spacing is spent
    // first and only what it cannot cover comes off the height.
    let gaps = CGFloat(aspects.count - 1)
    if gaps > 0 {
      let closer = (availableWidth - totalWidth(height: baseHeight, spacing: 0, aspects: aspects))
        / gaps
      if closer >= minimumGlyphSpacing {
        return (baseHeight, closer.rounded(.down))
      }
    }
    // A narrower panel is never wider, so the fit is monotonic in the height and
    // a halving search finds the tallest one that clears. Closed form would miss
    // the width floor a portrait panel sits on.
    //
    // The floor is never tested, so past a certain count it wins rather than
    // clears: the search returns a floor that still overflows and the clip cuts
    // the ends again. Left alone on purpose, since a row that deep is unreadable
    // at the floor whatever it does with the overflow.
    var tooShort = minimumGlyphHeight
    var tooTall = baseHeight
    // Twelve halvings land inside a twentieth of a point, finer than the whole
    // points the height is rounded to.
    for _ in 0..<12 {
      let middle = (tooShort + tooTall) / 2
      if totalWidth(height: middle, spacing: minimumGlyphSpacing, aspects: aspects)
        <= availableWidth
      {
        tooShort = middle
      } else {
        tooTall = middle
      }
    }
    // Rounding down can only narrow the row, so the fit cannot be lost to it.
    return (tooShort.rounded(.down), minimumGlyphSpacing)
  }
}

/// The vertical container for a page whose content can outgrow the window: a
/// wide rig makes both display pages taller than the fixed 760 by 560.
///
/// The floor is the whole point. A scroll view proposes an unbounded height,
/// and these `Spacer`-built pages answer it with their minimum: a column that
/// fills 400 pt collapses to 70 pt [MEASURED 2026-09-10]. Handing the visible
/// height back as a minimum leaves a page that fits looking as it did before.
struct OnboardingScrollColumn<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        content
          .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
      }
      // Without this a page that already fits rubber-bands.
      .scrollBounceBehavior(.basedOnSize)
    }
  }
}

/// Rendered under every page's primary action, so the exit is always in the
/// same place.
@MainActor
struct OnboardingSkipLink: View {
  let model: OnboardingFlowModel

  var body: some View {
    Button("Skip Setup") { model.skip() }
      .buttonStyle(OnboardingLinkButtonStyle())
  }
}

/// A slow idle bob for hero objects, so a resting page keeps a pulse.
/// Reduce Motion stills it, and so does `active` going false.
///
/// The still state is a separate branch, not a stopped animation. A
/// `repeatForever` animation never completes, so nothing detaches it while
/// the animated offset stays in the tree. [MEASURED 2026-09-09], stop path
/// confirmed running in the log: writing `up` back under
/// `Transaction.disablesAnimations` left the covered window at about 28% CPU;
/// `.animation(_:value:)` on the value, about 18%. Dropping the branch tears
/// the offset and its animation down with it, and the covered window then
/// reads 0.0 to 0.1%, the same as a pane with no animation. Never collapse
/// the two branches into one with a conditional modifier.
struct OnboardingFloatModifier: ViewModifier {
  var active: Bool

  @State private var up = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var floats: Bool { active && !reduceMotion }

  @ViewBuilder
  func body(content: Content) -> some View {
    if floats {
      content
        .offset(y: up ? -4 : 3)
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: up)
        // Reset on removal so the next insertion's `up = true` is a real
        // change and re-arms the animation.
        .onAppear { up = true }
        .onDisappear { up = false }
    } else {
      // Matches the moving branch's first frame (`up` false), so nothing
      // jumps on the edge.
      content.offset(y: 3)
    }
  }
}

extension View {
  func onboardingFloat(active: Bool) -> some View {
    modifier(OnboardingFloatModifier(active: active))
  }
}

/// Title and subtitle lockup every page opens with, in both guided flows.
///
/// On appearance the title takes the VoiceOver cursor, so arriving on a page
/// reads out what the page is about rather than whatever control comes first.
/// The settings window's mode banner lands on Keep instead, but that banner has
/// no title and IS the decision.
struct OnboardingHeading: View {
  var title: String
  var subtitle: String?
  /// Off on a flow's opening frame only: the window becoming key announces its
  /// own title there, and a landing part-way through interrupts it.
  var landsAccessibilityFocus = true

  @AccessibilityFocusState private var titleFocused: Bool

  var body: some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .foregroundStyle(OnboardingStyle.titleColor)
        .multilineTextAlignment(.center)
        .accessibilityFocused($titleFocused)
      if let subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 460)
      }
    }
    .onAppear { titleFocused = landsAccessibilityFocus }
  }
}
