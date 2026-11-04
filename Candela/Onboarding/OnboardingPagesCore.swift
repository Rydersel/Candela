import CandelaKit
import SwiftUI

/// Welcome: one large softly-lit display object under ambient light, the
/// pitch, and Begin Setup. The set piece is the product's subject, not
/// decoration.
struct OnboardingWelcomePage: View {
  let model: OnboardingFlowModel
  let accent: Color

  @State private var appeared = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      DisplayGlyph(aspect: heroAspect, accent: accent)
        .frame(width: 300, height: 210)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
      Spacer(minLength: 18)
      OnboardingHeading(
        title: OnboardingTitles.welcome,
        subtitle: "\(AppInfo.productName) looks after your external displays: health, burn-in protection, and the everyday controls, done carefully.",
        // Only the flow's opening frame gives the landing up, because the
        // window becoming key is speaking its own title there. Navigating back
        // to welcome lands on the heading like every other page.
        landsAccessibilityFocus: model.hasNavigated
      )
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 10)
      Spacer(minLength: 22)
      VStack(spacing: 10) {
        Button("Begin Setup") { model.advance() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
        OnboardingSkipLink(model: model)
      }
      .opacity(appeared ? 1 : 0)
      Spacer(minLength: 30)
    }
    .onAppear {
      withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(duration: 0.9)) {
        appeared = true
      }
    }
  }

  /// The user's own first display when there is one; a plain wide face when
  /// there is not.
  private var heroAspect: Double {
    model.environment.displays.first?.drawnAspect ?? (16.0 / 9.0)
  }
}

/// The keys page's words, outside the view so the corpus scan and the tests
/// read the same strings the page draws.
///
/// Counts are external displays at the moment of drawing. The page's presence
/// is latched at flow start, so it can still be up after every external display
/// is unplugged; zero reads as singular and nothing here names a display.
enum OnboardingKeysCopy {
  static func body(externalDisplayCount: Int) -> String {
    let plural = externalDisplayCount >= 2
    return "\(AppInfo.productName) lets your keyboard's brightness and volume keys control "
      + "your external \(plural ? "displays" : "display"). macOS only allows that with "
      + "Accessibility access, so without it those keys won't control your "
      + "\(plural ? "monitors" : "monitor")."
  }

  /// Replaces the body once the grant is live: the cost it warned about is gone.
  static func grantedBody(externalDisplayCount: Int) -> String {
    "Your keyboard's brightness and volume keys now control your external "
      + "\(externalDisplayCount >= 2 ? "displays" : "display")."
  }

  static let allow = "Allow Keyboard Control"

  /// Asks for the drag alone: on 27.2 the dropped row arrives switched on.
  static func waitingCaption(macOSMajor: Int) -> String {
    "Drag \(AppInfo.productName) into the list in "
      + "\(PermissionPane.accessibility.settingsPath(macOSMajor: macOSMajor)). "
      + "This page updates on its own."
  }

  /// The label states the cost, so nobody leaves believing the keys still work.
  static func skipLabel(externalDisplayCount: Int) -> String {
    "Skip: my keys won't control my \(externalDisplayCount >= 2 ? "monitors" : "monitor")"
  }
}

/// The keys page: pushes for the Accessibility grant, because the Mac's own
/// brightness and volume keys reach an external display only through it. The
/// way past turns keyboard control off and says so in its label.
struct OnboardingAccessibilityPage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  private var externalDisplayCount: Int { model.environment.displays.count }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      // Keys and words are one unit: fixed spacing binds them, so the
      // stretch lands around the group rather than between its parts.
      VStack(spacing: 18) {
        keycaps
        OnboardingHeading(
          title: OnboardingTitles.accessibility,
          subtitle: model.accessibilityGranted
            ? OnboardingKeysCopy.grantedBody(externalDisplayCount: externalDisplayCount)
            : OnboardingKeysCopy.body(externalDisplayCount: externalDisplayCount)
        )
      }
      Spacer()
      // The actions are one cluster pinned to the bottom: the primary
      // directly above its quiet escape, never floating mid-page.
      VStack(spacing: 12) {
        permissionState
        if !model.accessibilityGranted {
          Button(OnboardingKeysCopy.skipLabel(externalDisplayCount: externalDisplayCount)) {
            model.skipKeys()
          }
          .buttonStyle(OnboardingLinkButtonStyle())
          // Apart from Skip Setup, so the two quiet links do not read as a
          // pair of answers to one question.
          .padding(.bottom, 10)
        }
        OnboardingSkipLink(model: model)
      }
      .padding(.bottom, 44)
    }
    // A grant landing while the page is up changes what the page says, and
    // the arrival announcement has already been spoken.
    .onChange(of: model.accessibilityGranted) { _, granted in
      guard granted else { return }
      GuidedFlowAnnouncement.queued(
        OnboardingKeysCopy.grantedBody(externalDisplayCount: externalDisplayCount))
    }
  }

  /// The symbols the keys themselves carry, never decorative icons: this row is
  /// the keyboard the user is looking at.
  private var keycaps: some View {
    HStack(spacing: 14) {
      keycap("sun.max.fill")
      keycap("speaker.wave.2.fill")
      keycap("speaker.slash.fill")
    }
    .accessibilityHidden(true)
  }

  private func keycap(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 24, weight: .medium))
      .foregroundStyle(.white.opacity(0.9))
      .frame(width: 64, height: 64)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.white.opacity(0.14), .white.opacity(0.05)],
              startPoint: .top, endPoint: .bottom
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(accent.opacity(0.5), lineWidth: 1)
      )
      .shadow(color: accent.opacity(0.35), radius: 10, y: 3)
  }

  @ViewBuilder
  private var permissionState: some View {
    if model.accessibilityGranted {
      VStack(spacing: 14) {
        Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(Color(red: 0.35, green: 0.9, blue: 0.5))
        Button("Continue") { model.advance() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
      }
      .transition(.opacity)
    } else {
      VStack(spacing: 10) {
        // One label in both states: a second press after closing System
        // Settings brings the pane and its guide back.
        Button(OnboardingKeysCopy.allow) {
          if model.accessibilityRequested {
            model.openAccessibilitySettings()
          } else {
            model.requestAccessibility()
          }
        }
        .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
        if model.accessibilityRequested {
          Text(OnboardingKeysCopy.waitingCaption(macOSMajor: PermissionPane.currentMacOSMajor))
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
      }
    }
  }
}

/// The slim flow's pivot: no external display connected right now.
struct OnboardingNoDisplaysPage: View {
  let model: OnboardingFlowModel
  let accent: Color

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 30)
      DisplayGlyph(aspect: 16.0 / 9.0, accent: accent, lit: 0.25)
        .frame(width: 240, height: 170)
      Spacer(minLength: 20)
      OnboardingHeading(
        title: OnboardingTitles.noDisplays,
        subtitle: "Plug one in anytime. \(AppInfo.productName) picks it up automatically and offers the right size for it in Settings."
      )
      Spacer(minLength: 24)
      VStack(spacing: 10) {
        Button("Continue") { model.advance() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
        OnboardingSkipLink(model: model)
      }
      Spacer(minLength: 30)
    }
  }
}

/// Finish: the green bloom, a cascade of what was configured, what to
/// fine-tune next, and the launch at login decision.
struct OnboardingFinishPage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  @State private var revealed = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 26)
      // Check and title are one unit; fixed spacing keeps them together.
      // The mark draws itself in, then idles on the float.
      VStack(spacing: 14) {
        AnimatedCheckmark(accent: accent)
          .frame(width: 68, height: 68)
        OnboardingHeading(title: OnboardingTitles.finish)
      }
      Spacer(minLength: 18)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(summaryLines.enumerated()), id: \.offset) { pair in
          summaryRow(pair.element)
            .opacity(revealed > pair.offset + 1 ? 1 : 0)
            .offset(x: revealed > pair.offset + 1 ? 0 : -8)
        }
      }
      .frame(maxWidth: Self.columnWidth, alignment: .leading)
      if !fineTuneItems.isEmpty {
        Spacer(minLength: 18)
        fineTuneSection
          .opacity(revealed > summaryLines.count + 1 ? 1 : 0)
      }
      Spacer(minLength: 18)
      // A switch, not a checkbox: a checked box under a page of green
      // checks reads as one more completed item, not a decision to make.
      Toggle(isOn: $model.launchAtLogin) {
        Text("Open \(AppInfo.productName) at login")
          .foregroundStyle(OnboardingStyle.bodyColor)
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .tint(accent)
      .fixedSize()
      Spacer(minLength: 16)
      Button("Start Using \(AppInfo.productName)") { model.advance() }
        .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
      Spacer(minLength: 26)
    }
    .onAppear { reveal() }
  }

  /// Wide enough that the keys-off line and every fine-tune row stay on one
  /// line, which is what keeps four rows inside the fixed window.
  static let columnWidth: CGFloat = 440

  private var fineTuneItems: [OnboardingFineTuneItem] { model.fineTuneItems }
  private var externalDisplays: Int { model.environment.displays.count }

  private func summaryRow(_ line: OnboardingFinishCopy.Line) -> some View {
    HStack(spacing: 10) {
      Image(systemName: line.done ? "checkmark.circle.fill" : "minus.circle")
        .foregroundStyle(line.done ? accent : OnboardingStyle.faintColor)
        .accessibilityHidden(true)
      Text(line.text)
        .foregroundStyle(OnboardingStyle.bodyColor)
    }
    .font(.callout)
  }

  private var fineTuneSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(OnboardingFinishCopy.fineTuneHeading)
        .font(.caption.weight(.semibold))
        .foregroundStyle(OnboardingStyle.faintColor)
        .accessibilityAddTraits(.isHeader)
        .padding(.leading, 4)
      VStack(spacing: 0) {
        ForEach(Array(fineTuneItems.enumerated()), id: \.element) { pair in
          if pair.offset > 0 {
            Rectangle()
              .fill(OnboardingStyle.cardStroke)
              .frame(height: 0.5)
              .padding(.leading, 42)
          }
          fineTuneRow(pair.element)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(OnboardingStyle.cardFill)
      )
      // The end rows' hover wash would square off the card's corners.
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(OnboardingStyle.cardStroke, lineWidth: 0.5)
      )
    }
    .frame(maxWidth: Self.columnWidth)
  }

  private func fineTuneRow(_ item: OnboardingFineTuneItem) -> some View {
    Button {
      model.finish(opening: item)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: item.symbol)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(accent)
          .frame(width: 22)
        Text(item.title)
          .font(.callout.weight(.medium))
          .foregroundStyle(OnboardingStyle.titleColor.opacity(0.9))
        Text(item.detail(externalDisplays: externalDisplays))
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .lineLimit(1)
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.forward")
          .font(.caption.weight(.semibold))
          .foregroundStyle(OnboardingStyle.faintColor)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(OnboardingFineTuneRowStyle())
    // The title is the action; the detail is what it is about, and the
    // arrow says only that it leaves the page.
    .accessibilityLabel(item.title)
    .accessibilityHint(
      "\(item.detail(externalDisplays: externalDisplays)). Closes setup and opens Settings.")
  }

  private var summaryLines: [OnboardingFinishCopy.Line] {
    OnboardingFinishCopy.summary(
      keysOn: model.keyboardControlOn,
      grantInPlace: model.keysGrantInPlace,
      externalDisplays: externalDisplays,
      protectedOleds: model.protectedOledCount)
  }

  /// The values `revealed` steps through on appear. It ends past every
  /// threshold rather than at the last one counted: a summary line or the
  /// list can arrive while the page is up (the grant landing, a display
  /// plugged in), and a count taken on appear would leave it invisible.
  static func revealSequence(summaryLines: Int, offersFineTune: Bool) -> [Int] {
    // The fine-tune list is the cascade's last step, after the summary.
    let steps = summaryLines + (offersFineTune ? 1 : 0) + 1
    return Array(1...steps) + [Int.max]
  }

  private func reveal() {
    let sequence = Self.revealSequence(
      summaryLines: summaryLines.count, offersFineTune: !fineTuneItems.isEmpty)
    guard !reduceMotion else {
      revealed = Int.max
      return
    }
    revealed = 0
    for (offset, value) in sequence.enumerated() {
      withAnimation(.spring(duration: 0.5).delay(0.15 * Double(offset + 1))) {
        revealed = value
      }
    }
  }
}

/// A fine-tune row: flat at rest, a faint wash on hover so the whole row reads
/// as one target before it is clicked.
private struct OnboardingFineTuneRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .background(
          Rectangle().fill(
            Color.white.opacity(configuration.isPressed ? 0.10 : (hovering ? 0.06 : 0)))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}
