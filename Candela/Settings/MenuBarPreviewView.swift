import CandelaKit
import SwiftUI

/// The Menu Bar pane's live preview (KMR7): a miniature desktop showing what
/// Candela puts on screen right now: the status icon in the menu bar, the open
/// panel with its slider rows, and one on-screen indicator pill. Every control
/// on the pane changes something here, so the choices stop being phrases.
///
/// Fidelity (KMR8): each miniature replicates the real widget's anatomy at
/// about half scale, from the real sources rather than from imagination:
/// the panel from `PanelView`/`CandelaSlider` (280 pt wide, 13 pt semibold
/// secondary headers, capsule track with a white fill and knob, leading glyph,
/// trailing percent readout, gear/power footer pills), the pill from
/// `BrightnessHUD` (314 x 62, corner radius 22, name label over an icon-flanked
/// 4 pt bar), and the icon from `StatusItemController` (`sun.max`). The real
/// pill sits on `.hudWindow` material; this window is opaque by rule (no
/// effect views in the settings window), so the pill and panel grounds are
/// opaque colors matched per appearance instead.
///
/// Honesty (KMR9): everything shown is derived from the same policies the real
/// widgets consult. Icon presence is `MenuIconPolicy.isStatusItemVisible` with
/// the live rig's inputs; the rows are `PanelView.visibleDisplays` /
/// `showsBuiltIn` / `showsVolumeSlider` / `showsContrastSlider`; the slider
/// fills are the controllers' live values; the pill position is the persisted
/// `HUDPosition`. Nothing is drawn that the current settings would not produce.
///
/// Illustration, not control (KMR10): one accessibility element, no hit
/// targets, and the label below summarizes what is currently depicted.
///
/// `@MainActor` for the same reason as every pane: `PanelView`'s statics and
/// `AppModel` are main-actor, and a `View`'s non-`body` members are nonisolated
/// under complete concurrency checking.
@MainActor
struct MenuBarPreviewView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme

  /// Which indicator the pill depicts. The pane flips this to `.volume` when
  /// the volume position picker was the last one changed (KMR9); it is view
  /// state there, never persisted.
  var pillKind: HUDType

  // Real metrics x this. Half scale keeps a 280 pt panel and a 314 pt pill
  // legible inside one form row without dwarfing the controls below.
  private static let s: CGFloat = 0.5

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // The preview reads prefs directly, and prefs are plain UserDefaults:
    // without this read a position change would redraw only when something
    // else invalidated the pane.
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
      // The panel hangs from the icon; without the icon there is nothing to
      // open it from, so it goes too. The pill outranks the panel in z, as the
      // real one does (a screen-saver-level window draws over everything).
      if iconVisible {
        panelMiniature(externals: externals, showsBuiltIn: showsBuiltIn)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(.top, Self.menuBarHeight + 3)
          .padding(.trailing, 22)
      }
      pillMiniature(externals: externals)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pillAlignment)
        .padding(.top, Self.menuBarHeight + 6)
        .padding(.horizontal, 10)
    }
    .frame(height: 212)
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary(iconVisible: iconVisible))
  }

  // MARK: - Desktop

  /// A fixed depiction of a desktop, deliberately not appearance-adaptive: it
  /// is the scene the widgets sit on, and a stable ground keeps the widgets
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
  }

  // MARK: - Menu bar

  private static let menuBarHeight: CGFloat = 13

  private func menuBar(iconVisible: Bool) -> some View {
    HStack(spacing: 7) {
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
      Text("Wed 14:12").font(.system(size: 6.5))
    }
    .foregroundStyle(.white.opacity(0.85))
    .padding(.horizontal, 8)
    .frame(height: Self.menuBarHeight)
    .frame(maxWidth: .infinity)
    .background(.black.opacity(0.28))
  }

  // MARK: - Panel miniature

  private var panelGround: Color {
    colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.95)
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
      if showsBuiltIn, let builtIn = model.builtIn {
        displaySection(
          name: PanelView.title(for: builtIn.display),
          rows: [miniRow(glyph: "sun.max.fill", value: builtIn.controller.brightness)]
        )
      }
      ForEach(externals) { state in
        displaySection(name: PanelView.title(for: state.display), rows: rows(for: state))
      }
      Divider().opacity(0.6)
      // The real footer: a Settings pill leading, a Quit pill trailing.
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

  /// The same rows, in the same order, gated by the same statics the real
  /// panel consults; a muted volume renders as 0 with the slashed speaker,
  /// exactly as `ValueSliderRow` draws it.
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

  private func displaySection(name: String, rows: [MiniRow]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      // 13 pt semibold secondary in the real panel.
      Text(name)
        .font(.system(size: 13 * Self.s, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      ForEach(rows) { row in
        miniSlider(row)
      }
    }
  }

  /// `CandelaSlider`'s anatomy at half scale: quaternary capsule track, white
  /// fill from the leading edge, white knob with a grey hairline at the fill
  /// boundary, leading glyph dimmed against the fill, optional trailing
  /// percent readout.
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
          .frame(width: 15, alignment: .trailing)
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

  // MARK: - Indicator pill miniature

  private var pillPosition: HUDPosition {
    pillKind == .volume ? prefs.hudPositionVolume : prefs.hudPositionBrightness
  }

  private var pillAlignment: Alignment {
    switch pillPosition {
    case .topLeft: .topLeading
    case .topCenter: .top
    case .topRight: .topTrailing
    }
  }

  private var pillGround: Color {
    colorScheme == .dark ? Color(white: 0.20).opacity(0.97) : Color(white: 0.93).opacity(0.97)
  }

  /// The display the pill names, and the value its bar shows: the first row
  /// the panel would render, which is the same "first visible" ordering the
  /// real HUD grouping resolves to on this rig.
  private func pillSubject(externals: [AppModel.DisplayState]) -> (name: String, value: Double) {
    if pillKind == .volume,
       let state = externals.first(where: {
         PanelView.showsVolumeSlider(for: $0, prefs: DisplayPrefs(persistenceKey: $0.display.persistenceKey))
       }) {
      return (PanelView.title(for: state.display), state.volume.value)
    }
    if let state = externals.first {
      return (PanelView.title(for: state.display), state.controller.brightness)
    }
    if let builtIn = model.builtIn {
      return (PanelView.title(for: builtIn.display), builtIn.controller.brightness)
    }
    return ("Display", 0.5)
  }

  /// `BrightnessHUD` at half scale: 314 x 62 pill, corner radius 22, name
  /// label above an icon-flanked 4 pt bar, secondary icons, primary fill.
  private func pillMiniature(externals: [AppModel.DisplayState]) -> some View {
    let subject = pillSubject(externals: externals)
    let width = 314 * Self.s
    let height = 62 * Self.s
    let margin = 18 * Self.s
    return VStack(alignment: .leading, spacing: 4) {
      Text(subject.name)
        .font(.system(size: 12 * Self.s, weight: .semibold))
        .lineLimit(1)
      HStack(spacing: 4.5) {
        Image(systemName: pillKind.leftSymbolName)
          .font(.system(size: 5.5, weight: .semibold))
          .foregroundStyle(.secondary)
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.primary)
              .frame(width: max(2, geo.size.width * CGFloat(min(max(subject.value, 0), 1))))
          }
        }
        // Kept at the real 4 pt rather than half: 2 pt reads as a hairline and
        // loses the fill boundary the pill exists to show.
        .frame(height: 4)
        Image(systemName: pillKind.rightSymbolName)
          .font(.system(size: 6.5, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, margin)
    .frame(width: width, height: height, alignment: .leading)
    .background(pillGround)
    .clipShape(RoundedRectangle(cornerRadius: 22 * Self.s))
    .overlay(RoundedRectangle(cornerRadius: 22 * Self.s).strokeBorder(.separator, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
  }

  // MARK: - Accessibility

  private func accessibilitySummary(iconVisible: Bool) -> String {
    let icon = iconVisible ? "the menu bar icon with its sliders open" : "no menu bar icon"
    let kind = pillKind == .volume ? "volume" : "brightness"
    let position: String = switch pillPosition {
    case .topLeft: "top left"
    case .topCenter: "top center"
    case .topRight: "top right"
    }
    return "Preview of the current settings, showing \(icon), and the \(kind) indicator at the \(position) of the screen."
  }
}
