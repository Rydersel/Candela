import CandelaKit
import SwiftUI

/// Where a click on one of the preview's widgets takes the pane:
/// each widget scrolls to the section that configures it.
enum MenuBarPreviewJump {
  case sliders
  case indicators
}

/// The Menu Bar pane's live preview: a miniature desktop showing what
/// Candela puts on screen right now, so every control on the pane changes
/// something visible.
///
/// Fidelity: each miniature is drawn at half scale from the real source
/// rather than from imagination, the panel from `PanelView`/`CandelaSlider`, the
/// pill from `BrightnessHUD`, the icon from `StatusItemController`. The real
/// pill sits on `.hudWindow` material and this window is opaque by rule, so the
/// grounds here are opaque colors matched per appearance instead.
///
/// Honesty: everything shown comes from the policies
/// the real widgets consult, and every bar shows the controllers' LIVE values.
/// Both pills are depicted so both position choices stay visible; on screen the
/// two kinds take turns in one window per display, which the pane's footer says.
///
/// Doorways, not dead furniture (superseding the earlier no-hit-targets
/// clause): the widgets are buttons whose labels name their destination, and
/// the scenery stays decorative and hidden from accessibility.
///
/// `@MainActor`: `PanelView`'s statics and `AppModel` are main-actor, and a
/// `View`'s non-`body` members are nonisolated under complete concurrency
/// checking.
@MainActor
struct MenuBarPreviewView: View {
  @Environment(AppModel.self) private var model

  /// The widgets follow the SYSTEM appearance while this window is dark by rule,
  /// so reading the window's color scheme would draw a dark panel and pill for
  /// someone whose real ones are light. Feeds the grounds and the depicted
  /// subtree's whole color scheme, since labels and glyphs adapt too.
  @State private var systemAppearance = SystemAppearance()

  /// What the widgets resolve their adaptive colors against.
  private var depictedScheme: ColorScheme { systemAppearance.isDark ? .dark : .light }

  /// Scrolls the pane; supplied by `AppMenuPane`, which owns the
  /// `ScrollViewReader`.
  var jump: (MenuBarPreviewJump) -> Void

  // Real metrics x this. Half scale keeps a 280 pt panel and a 314 pt pill
  // legible inside one form row without dwarfing the controls below.
  private static let s: CGFloat = 0.5

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // Prefs are plain UserDefaults: without this read a position change would
    // redraw only when something else invalidated the pane.
    let _ = model.prefsRevision
    let externals = PanelView.visibleDisplays(model)
    let showsBuiltIn = PanelView.showsBuiltIn(model)
    let iconVisible = MenuIconPolicy.isStatusItemVisible(
      mode: prefs.menuIcon,
      hasExternalDisplay: !model.displays.isEmpty,
      hasVisibleSlider: !externals.isEmpty || showsBuiltIn
    )
    ZStack(alignment: .top) {
      wallpaper
      menuBar(iconVisible: iconVisible)
      anchorColumn(.topLeft, externals: externals, showsBuiltIn: showsBuiltIn, iconVisible: iconVisible)
      anchorColumn(.topCenter, externals: externals, showsBuiltIn: showsBuiltIn, iconVisible: iconVisible)
      anchorColumn(.topRight, externals: externals, showsBuiltIn: showsBuiltIn, iconVisible: iconVisible)
    }
    // The system-appearance exception covers the INK as well as the grounds: every adaptive color inside a
    // widget resolves against the environment's color scheme, and this window
    // pins that dark, so on a light-mode system the panel and pills drew light
    // with white text on them. The literal whites below are NOT covered and must
    // not be: they copy `CandelaSlider`'s own literals, white in both
    // appearances, and the fixed-dark menu bar's.
    //
    // Applied to the scene, not the whole `body`: the card frame below is the
    // settings window's chrome and stays themed.
    .environment(\.colorScheme, depictedScheme)
    // Sized for the tallest realistic column: both pills at top right above a
    // panel with a built-in row and two externals. Columns top-align, so
    // smaller content just leaves ground.
    .frame(height: 300)
    .frame(maxWidth: .infinity)
    // The frame is the settings window's: the widgets inside it keep
    // the real look, and only what surrounds them is themed.
    .clipShape(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
        .strokeBorder(SettingsTheme.cardStroke, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Preview of the menu bar and the on-screen indicators")
  }

  // MARK: - Anchor columns

  /// The pills anchored at one position, in stack order (brightness
  /// above volume when they share an anchor).
  private func pillKinds(at position: HUDPosition) -> [HUDType] {
    var kinds: [HUDType] = []
    if prefs.hudPositionBrightness == position { kinds.append(.brightness) }
    if prefs.hudPositionVolume == position { kinds.append(.volume) }
    return kinds
  }

  /// One position's stack: its pills, and at top right the panel beneath them.
  /// The true z-overlap is illegible at miniature scale, so the corner stacks
  /// instead.
  @ViewBuilder
  private func anchorColumn(
    _ position: HUDPosition, externals: [AppModel.DisplayState],
    showsBuiltIn: Bool, iconVisible: Bool
  ) -> some View {
    let kinds = pillKinds(at: position)
    let holdsPanel = position == .topRight && iconVisible
    if !kinds.isEmpty || holdsPanel {
      VStack(alignment: columnHorizontalAlignment(position), spacing: 9) {
        ForEach(kinds, id: \.leftSymbolName) { kind in
          LiftButton(label: pillAccessibilityLabel(kind: kind, position: position)) {
            jump(.indicators)
          } content: {
            pillMiniature(kind: kind, externals: externals)
          }
        }
        if holdsPanel {
          LiftButton(label: "Menu bar sliders preview; opens the Sliders settings below") {
            jump(.sliders)
          } content: {
            panelMiniature(externals: externals, showsBuiltIn: showsBuiltIn)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: columnAlignment(position))
      .padding(.top, Self.menuBarHeight + (holdsPanel ? 5 : 8))
      .padding(.bottom, 8)
      .padding(.leading, position == .topLeft ? 14 : 0)
      .padding(.trailing, position == .topRight ? 16 : 0)
    }
  }

  private func columnAlignment(_ position: HUDPosition) -> Alignment {
    switch position {
    case .topLeft: .topLeading
    case .topCenter: .top
    case .topRight: .topTrailing
    }
  }

  private func columnHorizontalAlignment(_ position: HUDPosition) -> HorizontalAlignment {
    switch position {
    case .topLeft: .leading
    case .topCenter: .center
    case .topRight: .trailing
    }
  }

  // MARK: - Desktop

  /// Deliberately not appearance-adaptive: a stable ground keeps the widgets
  /// (which DO adapt) readable in both appearances.
  private var wallpaper: some View {
    LinearGradient(
      colors: [
        Color(red: 0.16, green: 0.23, blue: 0.42),
        Color(red: 0.24, green: 0.16, blue: 0.36),
        Color(red: 0.10, green: 0.09, blue: 0.16),
      ],
      startPoint: .topLeading, endPoint: .bottomTrailing
    )
    .accessibilityHidden(true)
  }

  // MARK: - Menu bar

  private static let menuBarHeight: CGFloat = 13

  private func menuBar(iconVisible: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: "apple.logo").font(.system(size: 6.5))
      Text("Finder").font(.system(size: 6.5, weight: .bold))
      Text("File").font(.system(size: 6.5))
      Text("Edit").font(.system(size: 6.5))
      Spacer()
      if iconVisible {
        // The real status icon (StatusItemController): sun.max.
        Image(systemName: "sun.max").font(.system(size: 7, weight: .medium))
      }
      Image(systemName: "wifi").font(.system(size: 6))
      Image(systemName: "battery.75percent").font(.system(size: 7))
      // Fixed-size: letting the clock compress put its last digits under the
      // rounded corner's clip.
      Text("Wed 14:12").font(.system(size: 6.5)).fixedSize()
    }
    .foregroundStyle(.white.opacity(0.85))
    .padding(.leading, 10)
    .padding(.trailing, 13)
    .frame(height: Self.menuBarHeight)
    .frame(maxWidth: .infinity)
    .background(.black.opacity(0.28))
    .accessibilityHidden(true)
  }

  // MARK: - Panel miniature

  private var panelGround: Color {
    systemAppearance.isDark ? Color(white: 0.16) : Color(white: 0.95)
  }

  private func panelMiniature(externals: [AppModel.DisplayState], showsBuiltIn: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if externals.isEmpty, !showsBuiltIn {
        // The real panel's hardware-empty line, at miniature size.
        Text("No controllable displays")
          .font(.system(size: 6.5))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
      // Same participant set and floor as the panel, so the miniature shows
      // the row exactly when the panel does.
      let combined = CombinedBrightness.participants(
        builtIn: showsBuiltIn ? model.builtIn : nil, externals: externals,
        prefs: PanelView.standardPrefs)
      if CombinedBrightness.shows(
        participantCount: combined.count, appPrefs: DisplayPrefs(persistenceKey: "app")) {
        displaySection(
          name: "All displays",
          rows: [miniRow(
            glyph: "sun.max.fill",
            value: CombinedBrightness.mean(combined.map(\.controller.brightness)))]
        )
      }
      if showsBuiltIn, let builtIn = model.builtIn {
        displaySection(
          name: PanelView.title(for: builtIn.display),
          rows: [miniRow(glyph: "sun.max.fill", value: builtIn.controller.brightness)]
        )
      }
      ForEach(externals) { state in
        // Same derivation as the panel's header, so the preview grows a line
        // exactly when the panel does.
        displaySection(
          name: PanelView.title(for: state.display),
          careLine: PanelView.careLine(for: state, model: model),
          rows: rows(for: state))
      }
      Divider().opacity(0.6)
      HStack {
        footerPill(glyph: "gearshape", title: "Settings…")
        Spacer(minLength: 4)
        footerPill(glyph: "power", title: "Quit")
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 6)
    .frame(width: 280 * Self.s)
    .background(panelGround)
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
  }

  private struct MiniRow: Identifiable {
    let id = UUID()
    let glyph: String
    let value: Double
  }

  private func miniRow(glyph: String, value: Double) -> MiniRow {
    MiniRow(glyph: glyph, value: min(max(value, 0), 1))
  }

  /// The same rows in the same order, gated by the statics the real panel
  /// consults; a muted volume renders as 0 with the slashed speaker, the way
  /// `ValueSliderRow` draws it.
  private func rows(for state: AppModel.DisplayState) -> [MiniRow] {
    let rowPrefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
    var rows = [miniRow(glyph: "sun.max.fill", value: state.controller.brightness)]
    if PanelView.showsVolumeSlider(for: state, prefs: rowPrefs) {
      rows.append(miniRow(
        glyph: state.volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
        value: state.volume.isMuted ? 0 : state.volume.value
      ))
    }
    if PanelView.showsContrastSlider(for: state, prefs: rowPrefs) {
      rows.append(miniRow(glyph: "circle.lefthalf.filled", value: state.contrast.value))
    }
    return rows
  }

  private func displaySection(
    name: String, careLine: String? = nil, rows: [MiniRow]
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      VStack(alignment: .leading, spacing: 2 * Self.s) {
        // 13 pt semibold secondary in the real panel.
        Text(name)
          .font(.system(size: 13 * Self.s, weight: .semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let careLine {
          // 11 pt secondary under the name in the real panel.
          Text(verbatim: careLine)
            .font(.system(size: 11 * Self.s))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      ForEach(rows) { row in
        miniSlider(row)
      }
    }
  }

  /// `CandelaSlider`'s anatomy at half scale: quaternary track, white fill and
  /// knob, a glyph dimmed against the fill, optional percent readout.
  private func miniSlider(_ row: MiniRow) -> some View {
    let h: CGFloat = 30 * Self.s
    return HStack(spacing: 4) {
      GeometryReader { geo in
        let travel = max(geo.size.width - h, 1)
        let fillWidth = h + CGFloat(row.value) * travel
        ZStack(alignment: .leading) {
          Capsule().fill(.quaternary)
          Capsule().fill(.white).frame(width: fillWidth)
          Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.gray.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 1)
            .frame(width: h, height: h)
            .offset(x: fillWidth - h)
          Capsule().strokeBorder(Color.gray.opacity(0.5), lineWidth: 0.5)
          Image(systemName: row.glyph)
            .font(.system(size: 13 * Self.s, weight: .medium))
            .foregroundStyle(.black.opacity(0.6))
            .frame(width: h, height: h)
        }
      }
      .frame(height: h)
      if prefs.enableSliderPercent {
        Text(SliderSnap.percentText(row.value))
          .font(.system(size: 6).monospacedDigit())
          .foregroundStyle(.secondary)
          // Fixed-size: "100%" wrapped to two lines in a compressible frame.
          .fixedSize()
          .frame(width: 18, alignment: .trailing)
      }
    }
  }

  private func footerPill(glyph: String, title: String) -> some View {
    HStack(spacing: 2.5) {
      Image(systemName: glyph).font(.system(size: 5.5))
      Text(title).font(.system(size: 6))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 5)
    .padding(.vertical, 2.5)
    .background(Capsule().fill(.quaternary.opacity(0.5)))
  }

  // MARK: - Indicator pill miniatures

  /// Lighter than the first pass: the native pill's material reads
  /// brighter than `.hudWindow` did.
  private var pillGround: Color {
    systemAppearance.isDark
      ? Color(white: 0.27).opacity(0.97) : Color(white: 0.95).opacity(0.97)
  }

  /// A LIGHT edge, never a dark one: the black-reading `separatorColor` border
  /// is one of the deltas the revision names against the native pill.
  private var pillHairline: Color {
    systemAppearance.isDark ? .white.opacity(0.22) : .black.opacity(0.08)
  }

  /// Mirrors the panel miniature's row ordering on the same live reads, so the
  /// two surfaces name the same subject and move together. The REAL pill's
  /// subject depends on the key target mode, so this is a preview convention,
  /// not a claim about which display a press would name.
  private func pillSubject(kind: HUDType, externals: [AppModel.DisplayState])
    -> (name: String, value: Double, muted: Bool) {
    if kind == .volume || kind == .volumeMuted,
       let state = externals.first(where: {
         PanelView.showsVolumeSlider(for: $0, prefs: DisplayPrefs(persistenceKey: $0.display.persistenceKey))
       }) {
      return (PanelView.title(for: state.display),
              state.volume.isMuted ? 0 : state.volume.value,
              state.volume.isMuted)
    }
    if let state = externals.first {
      return (PanelView.title(for: state.display), state.controller.brightness, false)
    }
    if let builtIn = model.builtIn {
      return (PanelView.title(for: builtIn.display), builtIn.controller.brightness, false)
    }
    // No hardware at all: the pill still previews position and style, on an
    // illustrative value.
    return ("Display", 0.5, false)
  }

  /// The selected `HUDStyle` at half scale, from the spec's pinned
  /// geometry. One definition in the spec, two implementations (here and
  /// `BrightnessHUD`), reconciled side by side.
  @ViewBuilder
  private func pillMiniature(kind: HUDType, externals: [AppModel.DisplayState]) -> some View {
    let subject = pillSubject(kind: kind, externals: externals)
    // The real HUD's muted anatomy: slashed speakers, empty bar.
    let shownKind: HUDType = kind == .volume && subject.muted ? .volumeMuted : kind
    switch prefs.hudStyle {
    case .system, .segments:
      VStack(alignment: .leading, spacing: 4) {
        Text(subject.name)
          .font(.system(size: 12 * Self.s, weight: .semibold))
          .lineLimit(1)
        pillBarRow(kind: shownKind, value: subject.value)
      }
      .padding(.horizontal, 18 * Self.s)
      .frame(width: 314 * Self.s, height: 62 * Self.s, alignment: .leading)
      .modifier(PillChrome(radius: 22 * Self.s, ground: pillGround, hairline: pillHairline))
    case .compact:
      pillBarRow(kind: shownKind, value: subject.value)
        .padding(.horizontal, 14 * Self.s)
        .frame(width: 220 * Self.s, height: 36 * Self.s)
        .modifier(PillChrome(radius: 18 * Self.s, ground: pillGround, hairline: pillHairline))
    }
  }

  /// The icon-flanked value readout every style shares; only the track between
  /// the icons changes shape.
  private func pillBarRow(kind: HUDType, value: Double) -> some View {
    HStack(spacing: 4.5) {
      Image(systemName: kind.leftSymbolName)
        .font(.system(size: 5.5, weight: .semibold))
        .foregroundStyle(.secondary)
      Group {
        if prefs.hudStyle == .segments {
          segmentedTrack(value: value)
        } else {
          continuousTrack(value: value)
        }
      }
      // The real 4 pt rather than half: 2 pt reads as a hairline and loses the
      // fill boundary the pill exists to show.
      .frame(height: 4)
      Image(systemName: kind.rightSymbolName)
        .font(.system(size: 6.5, weight: .semibold))
        .foregroundStyle(.secondary)
    }
  }

  /// Match macOS: continuous fill, with the native track's tick dots hinted on
  /// the unfilled portion.
  private func continuousTrack(value: Double) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        HStack(spacing: 0) {
          ForEach(0..<15) { _ in
            Spacer(minLength: 0)
            Circle()
              .fill(.secondary.opacity(0.5))
              .frame(width: 1, height: 1)
          }
          Spacer(minLength: 0)
        }
        Capsule().fill(.primary)
          .frame(width: max(2, geo.size.width * CGFloat(min(max(value, 0), 1))))
      }
    }
  }

  /// Segmented: the spec's segment count and gaps, halved here.
  private func segmentedTrack(value: Double) -> some View {
    let filled = Int((min(max(value, 0), 1) * 16).rounded())
    return HStack(spacing: 2 * Self.s) {
      ForEach(0..<16) { index in
        RoundedRectangle(cornerRadius: 2 * Self.s)
          .fill(index < filled ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
          .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: - Accessibility

  private func pillAccessibilityLabel(kind: HUDType, position: HUDPosition) -> String {
    let kindName = kind == .volume ? "volume" : "brightness"
    let positionName: String = switch position {
    case .topLeft: "top left"
    case .topCenter: "top center"
    case .topRight: "top right"
    }
    return "\(kindName.capitalized) indicator preview at the \(positionName) of the screen; opens the On-Screen Indicators settings below"
  }
}

/// The pill's shared chrome: every style differs inside the pill, not
/// around it. The light hairline and softened shadow are the revision's direction.
private struct PillChrome: ViewModifier {
  let radius: CGFloat
  let ground: Color
  let hairline: Color

  func body(content: Content) -> some View {
    content
      .background(ground)
      .clipShape(RoundedRectangle(cornerRadius: radius))
      .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(hairline, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
  }
}

/// Whether the system is drawing in dark, live. The preview depicts widgets
/// that follow the system appearance while this window is pinned dark, so it
/// cannot read the window's color scheme. KVO rather than an activation
/// notification, which would miss a flip made while the window is open.
@MainActor
@Observable
private final class SystemAppearance {
  private(set) var isDark = SystemAppearance.currentIsDark()

  @ObservationIgnored private var observation: NSKeyValueObservation?

  init() {
    observation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      // The value is re-read on the main actor rather than taken from the
      // change: the closure is nonisolated and `NSApplication` is not.
      Task { @MainActor in self?.isDark = SystemAppearance.currentIsDark() }
    }
  }

  private static func currentIsDark() -> Bool {
    NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }
}

/// The preview widgets' doorway affordance: lift, not tint, so the
/// hover survives an unfocused window. Scale is skipped under Reduce Motion; the
/// shadow deepens either way, a non-moving cue.
private struct LiftButton<Content: View>: View {
  let label: String
  let action: () -> Void
  @ViewBuilder let content: Content

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      content
        .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
        .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: 8, y: 3)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.12), value: hovering)
    .accessibilityLabel(label)
  }
}
