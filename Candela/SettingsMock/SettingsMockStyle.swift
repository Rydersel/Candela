#if DEBUG
  import SwiftUI

  /// Settings-specific vocabulary on top of the guided setup flow's style:
  /// the flow's components (OnboardingStyle, OnboardingCard, DisplayGlyph,
  /// the button styles) are reused directly; what is added here is the denser
  /// grammar a settings surface needs. Rows, sections, sliders, chevrons.
  enum SettingsMockStyle {
    static let pageWidth: CGFloat = 620
  }

  /// Left-aligned page lockup: settings pages are working surfaces, so the
  /// title anchors leading rather than centering like the flow's pages.
  struct MockPageHeader: View {
    var title: String
    var subtitle: String?
    var accent: Color

    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 24, weight: .bold, design: .rounded))
          .foregroundStyle(OnboardingStyle.titleColor)
        if let subtitle {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(OnboardingStyle.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The mock's card: the onboarding surface at settings sharpness. Tighter
  /// corner and padding than the flow's card, macOS density over stage
  /// presence.
  struct MockCard<Content: View>: View {
    var isSelected = false
    var accent: Color = .white
    @ViewBuilder var content: Content

    var body: some View {
      content
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? accent.opacity(0.12) : OnboardingStyle.cardFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(
              isSelected ? accent.opacity(0.5) : OnboardingStyle.cardStroke,
              lineWidth: 1)
        )
    }
  }

  /// A titled group of rows on one card: the mock's answer to a Form section.
  struct MockSection<Content: View>: View {
    var title: String?
    var accent: Color = .white
    @ViewBuilder var content: Content

    var body: some View {
      VStack(alignment: .leading, spacing: 5) {
        if let title {
          Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(1.1)
            .foregroundStyle(accent.opacity(0.85))
            .padding(.leading, 4)
        }
        MockCard {
          VStack(alignment: .leading, spacing: 0) {
            content
          }
        }
      }
    }
  }

  /// Label plus optional caption on the left, any control trailing. The
  /// caption rides the row (one consequence sentence), never its own row.
  /// Rows carry no leading icon: the sidebar and heroes own the iconography,
  /// and a glyph per row made every page read busy. `symbol` is accepted and
  /// ignored so call sites stay stable.
  struct MockRow<Trailing: View>: View {
    var label: String
    var caption: String?
    var symbol: String?
    var accent: Color = .white
    @ViewBuilder var trailing: Trailing

    var body: some View {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .foregroundStyle(OnboardingStyle.titleColor)
          if let caption {
            Text(caption)
              .font(.caption)
              .foregroundStyle(OnboardingStyle.faintColor)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 16)
        trailing
      }
      .padding(.vertical, 6)
    }
  }

  /// Hairline between rows, inset like the row content.
  struct MockDivider: View {
    var body: some View {
      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)
    }
  }

  /// A drill-in row: value preview, chevron, hover lift. Static in the mock
  /// unless an action is provided.
  struct MockChevronRow: View {
    var label: String
    var value: String?
    var symbol: String?
    var accent: Color = .white
    var action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
      Button { action?() } label: {
        HStack(spacing: 12) {
          Text(label)
            .foregroundStyle(OnboardingStyle.titleColor)
          Spacer(minLength: 16)
          if let value {
            Text(value)
              .foregroundStyle(OnboardingStyle.bodyColor)
          }
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(hovering ? accent : OnboardingStyle.faintColor)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }

  /// The accent-lit slider: capsule track, glowing fill, draggable. Custom
  /// because the system slider ignores the stage lighting entirely.
  struct MockSlider: View {
    @Binding var value: Double
    var accent: Color

    var body: some View {
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.white.opacity(0.10))
            .frame(height: 5)
          Capsule()
            .fill(accent.opacity(0.85))
            .frame(width: max(5, width * value), height: 5)
          Circle()
            .fill(.white)
            .frame(width: 13, height: 13)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .offset(x: max(0, (width - 13) * value))
        }
        .frame(height: proxy.size.height)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { gesture in
            value = min(1, max(0, gesture.location.x / width))
          }
        )
      }
      .frame(height: 22)
    }
  }

  /// A tinted switch bound to mock state. Small, the size System Settings
  /// uses, so a row reads as a settings row rather than a hero control.
  struct MockToggle: View {
    @Binding var isOn: Bool
    var accent: Color

    var body: some View {
      Toggle("", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent)
    }
  }

  /// Segmented choice shaped like the macOS segmented control: a recessed
  /// rounded-rect track with a raised selected segment, accent-tinted.
  struct MockSegments: View {
    var options: [String]
    @Binding var selection: Int
    var accent: Color

    var body: some View {
      HStack(spacing: 2) {
        ForEach(options.indices, id: \.self) { index in
          SegmentButton(
            label: options[index], isOn: selection == index, accent: accent
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
            .foregroundStyle(isOn ? Color.white : OnboardingStyle.bodyColor)
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isOn)
      }
    }
  }

  /// The mock's standard action button: macOS bordered-button geometry
  /// (rounded rect, compact padding) with the accent carrying the primary.
  struct MockPrimaryButtonStyle: ButtonStyle {
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
          .font(.callout.weight(.medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 5.5)
          .background(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
              .fill(accent.opacity(hovering ? 0.9 : 0.78))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
              .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
          )
          .scaleEffect(configuration.isPressed ? 0.98 : 1)
          .onHover { hovering = $0 }
          .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
          .animation(.easeOut(duration: 0.15), value: hovering)
      }
    }
  }

  /// Quiet sibling of the primary: same geometry, neutral fill.
  struct MockSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
      let configuration: Configuration
      @State private var hovering = false

      var body: some View {
        configuration.label
          .font(.callout)
          .foregroundStyle(hovering ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor)
          .padding(.horizontal, 14)
          .padding(.vertical, 5.5)
          .background(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
              .fill(Color.white.opacity(configuration.isPressed ? 0.13 : (hovering ? 0.10 : 0.07)))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
              .stroke(Color.white.opacity(0.12), lineWidth: 1)
          )
          .onHover { hovering = $0 }
          .animation(.easeOut(duration: 0.15), value: hovering)
      }
    }
  }

  /// The simplified brand mark: the app icon's C reduced to a tintable
  /// vector, an open ring whose upper terminus carries the flame dot. Takes
  /// whatever tint the destination provides, which the full icon cannot.
  struct MockBrandMark: View {
    var tint: Color

    var body: some View {
      GeometryReader { proxy in
        let side = min(proxy.size.width, proxy.size.height)
        // Stroke weight tuned to sit beside bold rounded text as a letter.
        let line = side * 0.24
        let ring = side - line
        let radius = ring / 2
        let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
        // The C opens to the right; the dot sits on the upper terminus.
        let dotAngle = Angle.degrees(-30)
        let dotCenter = CGPoint(
          x: center.x + radius * CGFloat(cos(dotAngle.radians)),
          y: center.y + radius * CGFloat(sin(dotAngle.radians)))
        ZStack {
          Circle()
            .trim(from: 0.10, to: 0.915)
            .stroke(
              tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .frame(width: ring, height: ring)
            .position(center)
          Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: side * 0.30, height: side * 0.30)
            .position(dotCenter)
            .shadow(color: tint.opacity(0.9), radius: side * 0.10)
        }
      }
      .accessibilityHidden(true)
    }
  }

  /// The built-in display drawn as what it is: a laptop, screen over a deck
  /// that is wider than the glass, the way the machine actually closes.
  struct MockLaptopGlyph: View {
    var aspect: Double
    var accent: Color
    var lit: Double = 1
    var faceOverlay: AnyView?

    var body: some View {
      GeometryReader { proxy in
        let bounds = proxy.size
        let deckHeight = max(5, bounds.height * 0.075)
        let faceHeight = bounds.height - deckHeight
        let faceWidth = min(bounds.width * 0.86, CGFloat(aspect) * faceHeight)
        VStack(spacing: 0) {
          DisplayGlyph(
            aspect: aspect, accent: accent, lit: lit, faceOverlay: faceOverlay,
            showsStand: false, showsReflection: false
          )
          .frame(width: faceWidth, height: faceHeight, alignment: .bottom)
          deck(width: min(bounds.width, faceWidth * 1.18), height: deckHeight)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .bottom)
      }
    }

    private func deck(width: CGFloat, height: CGFloat) -> some View {
      ZStack {
        UnevenRoundedRectangle(
          topLeadingRadius: 2, bottomLeadingRadius: height * 0.55,
          bottomTrailingRadius: height * 0.55, topTrailingRadius: 2,
          style: .continuous
        )
        .fill(
          LinearGradient(
            colors: [.white.opacity(0.26), .white.opacity(0.09)],
            startPoint: .top, endPoint: .bottom)
        )
        // Thumb notch.
        Capsule()
          .fill(Color.black.opacity(0.35))
          .frame(width: width * 0.16, height: max(2, height * 0.3))
          .offset(y: -height * 0.2)
      }
      .frame(width: width, height: height)
    }
  }

  /// Small accent capsule for state ("On", "Recommended", "Live").
  struct MockBadge: View {
    var text: String
    var accent: Color

    var body: some View {
      Text(text)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.25)))
        .foregroundStyle(accent)
    }
  }

  /// The drifting glow ground under every mock page, tinted per destination.
  /// Same construction as the flow's canvas; takes hues directly so a
  /// settings destination does not need to be an onboarding act.
  struct SettingsMockCanvas: View {
    var accent: Color
    var secondary: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      ZStack {
        Color(red: 0.035, green: 0.035, blue: 0.06)
        if reduceMotion {
          blobs(at: 0)
        } else {
          TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            blobs(at: context.date.timeIntervalSinceReferenceDate)
          }
        }
        RadialGradient(
          colors: [.clear, Color.black.opacity(0.5)],
          center: .center, startRadius: 220, endRadius: 640
        )
      }
      .ignoresSafeArea()
      .accessibilityHidden(true)
    }

    private func blobs(at time: TimeInterval) -> some View {
      GeometryReader { proxy in
        let size = proxy.size
        let t1 = time / 26
        let t2 = time / 34
        ZStack {
          Circle()
            .fill(accent.opacity(0.21))
            .frame(width: size.width * 0.8)
            .blur(radius: 100)
            .position(
              x: size.width * (0.32 + 0.10 * CGFloat(sin(t1))),
              y: size.height * (0.20 + 0.08 * CGFloat(cos(t1 * 1.3)))
            )
          Circle()
            .fill(secondary.opacity(0.15))
            .frame(width: size.width * 0.7)
            .blur(radius: 110)
            .position(
              x: size.width * (0.80 - 0.09 * CGFloat(cos(t2))),
              y: size.height * (0.88 + 0.07 * CGFloat(sin(t2 * 1.7)))
            )
        }
        .animation(.easeInOut(duration: 1.4), value: accent)
      }
    }
  }
#endif
