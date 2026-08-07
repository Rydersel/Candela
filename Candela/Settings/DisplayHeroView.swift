import CandelaKit
import SwiftUI

/// The panel-flavored opening of an external display's page (A2/A4): a
/// functional tile, the identity block, and the two live sliders.
///
/// **The tile earns its place by being functional** (A4). It carries the
/// display's real shape — aspect ratio straight off the current mode, which is
/// why a display mounted at 270° renders TALL with no rotation transform
/// anywhere: `CGDisplayCopyDisplayMode` reports the rotated logical size, so
/// the shape IS the orientation. It also carries the mirroring state. A tile
/// that only decorated would have been cut.
///
/// **External displays only.** The built-in gets no hero (spec §4), which is
/// what lets the HDR consequence line below read `.macOSDrivesBrightness` as
/// "HDR is live": `BrightnessPathPolicy` puts an external display on `.native`
/// for exactly one reason, and the built-in — which is constitutively native —
/// never reaches this view.
///
/// **It writes no pref** (no `PrefName`, no `DisplayPrefWriter`). The two
/// sliders write through the engine's own controllers, which is the same path
/// the menu bar's sliders use — D27 governs pref writes, and there are none
/// here.
///
/// `@MainActor` is load-bearing: a `View`'s stored and computed properties
/// other than `body` are nonisolated under complete concurrency, and these read
/// main-actor types (`AppModel`, the controllers, `PanelView.title`).
@MainActor
struct DisplayHeroView: View {
  let state: AppModel.DisplayState

  @Environment(AppModel.self) private var model

  /// The box the tile fits INSIDE, preserving its aspect ratio — never the
  /// tile's own size. A fixed height with a derived width would run a 21:9
  /// ultrawide off the page, and a fixed width would flatten a portrait
  /// display to a sliver.
  ///
  /// Scaled, because it sits beside scalable text (a11y contract 10): at large
  /// text sizes a fixed 56 pt tile would be dwarfed by the name beside it.
  @ScaledMetric(relativeTo: .headline) private var tileBoxWidth: CGFloat = 120
  @ScaledMetric(relativeTo: .headline) private var tileBoxHeight: CGFloat = 56

  /// Keyboard/VoiceOver floor for brightness when the software leg can reach
  /// black (a11y contract 7). Low enough to still be "as dark as it goes",
  /// high enough that the screen is still readable — a keyboard user who
  /// cannot see the screen cannot find the arrow key that undoes it.
  private static let softwareDimmingFloor: Double = 0.05

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  /// THE name resolver every surface shares, so a rename in the Name field
  /// below moves the hero, the menu bar and every tooltip together.
  private var name: String { PanelView.title(for: state.display) }

  private var catalog: DisplayModeCoordinator.Catalog? { model.displayModes.catalogs[state.id] }

  /// nil means "not enumerated yet", which is deliberately distinct from a
  /// display with no modes — nothing below renders a guess for it.
  private var currentMode: DisplayMode? { catalog?.current }

  var body: some View {
    // Required even though this view binds no pref directly: `name` resolves
    // `DisplayPrefs.friendlyName`, the sliders read the app-level appearance
    // prefs, and `volumeSliderEnabled` reads `audioSinkOverride`. `DisplayPrefs`
    // is plain `UserDefaults` and is not observable, so without this read a
    // rename in the section below would leave the old name standing here.
    let _ = model.prefsRevision
    HStack(alignment: .top, spacing: 14) {
      tile
      VStack(alignment: .leading, spacing: 8) {
        identity
        brightnessSlider
        volumeSlider
        if let consequenceSentence {
          // Hidden from VoiceOver because the same sentence already travels in
          // the brightness slider's LABEL (a11y contract 3) — leaving the
          // caption readable announced it twice (T12 review).
          SettingsCaption(verbatim: consequenceSentence)
            .accessibilityHidden(true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Tile

  /// Decoration for VoiceOver, by the arrangement canvas's own precedent: a
  /// shape has no reading. What it draws is said in words by the sections this
  /// page already carries — the mode caption right beside it, and Mirroring
  /// below — so a hero that ever draws a fact NOT stated in words has broken
  /// this, and the fix is the words, not an accessibility label on a rectangle.
  private var tile: some View {
    let box = tileFit
    return RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(.quaternary)
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(.separator, lineWidth: 1)
      }
      .overlay {
        if isMirroring {
          Image(systemName: "rectangle.on.rectangle")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: box.width, height: box.height)
      // The full BOX is reserved, not just the tile's own size, so the identity
      // column's left edge stays put whatever shape the display is — a portrait
      // Dell must not shift every label 90 pt left of where the MAG puts them
      // (T12 review).
      .frame(width: tileBoxWidth, height: tileBoxHeight, alignment: .top)
      .accessibilityHidden(true)
  }

  /// Aspect ratio from the CURRENT MODE's logical size, which already carries
  /// rotation. 16:9 when no mode has been enumerated yet — a fallback shape,
  /// never a claim about this display.
  private var aspectRatio: CGFloat {
    guard let mode = currentMode, mode.logicalWidth > 0, mode.logicalHeight > 0 else {
      return 16.0 / 9.0
    }
    return CGFloat(mode.logicalWidth) / CGFloat(mode.logicalHeight)
  }

  /// Largest aspect-correct rectangle inside the box.
  private var tileFit: CGSize {
    let width = min(tileBoxWidth, tileBoxHeight * aspectRatio)
    return CGSize(width: width, height: width / aspectRatio)
  }

  /// The coordinator's own topology sample, read the way `MirroringSection`
  /// reads it — `MirrorTopology` is the one definition of "mirrored" in this
  /// app and this is a reader of it, never a second opinion.
  private var isMirroring: Bool {
    !model.mirroring.topology.setMembers(containing: state.id).isEmpty
  }

  // MARK: - Identity

  /// ONE grouped element with a heading trait (a11y contract 4): the name and
  /// the mode are one fact about one display, and reading them as two elements
  /// makes the top of every display page twice as long to get past.
  private var identity: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: name)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
      if let modeCaption {
        Text(verbatim: modeCaption)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spokenIdentity)
    .accessibilityAddTraits(.isHeader)
    .accessibilityHeading(.h1)
  }

  /// `2560 × 1440 · 60 Hz`, with `(max 175 Hz)` only when this size really does
  /// offer something faster. Absent entirely until the catalog arrives — "not
  /// enumerated yet" is not a fact about the display and must not be rendered
  /// as one.
  ///
  /// No "HiDPI", and no "Scaled" (SO14): this line NAMES the mode in force, it
  /// does not offer a size to choose from, which is the distinction
  /// `DisplayModeCopy.size` documents for the badges.
  private var modeCaption: String? {
    guard let mode = currentMode else { return nil }
    let base = "\(DisplayModeCopy.size(mode)) · \(DisplayModeCopy.refresh(mode.refreshHz))"
    guard let faster = fasterRateAtCurrentSize else { return base }
    return "\(base) (max \(DisplayModeCopy.refresh(faster)))"
  }

  /// The fastest rate this size offers, when it is strictly faster than the one
  /// running.
  ///
  /// Quantized before comparing as belt and braces: live modes are already
  /// quantized at the construction boundary, but `refreshRates(in:…)` dedupes
  /// on RAW doubles, so the day an unquantized rate reaches the catalog its
  /// noise would read as a faster rate rather than as the same one. The
  /// quantizer still keeps a genuine 59.94 apart from 60 — it is designed for
  /// exactly that.
  private var fasterRateAtCurrentSize: Double? {
    guard let mode = currentMode, let catalog else { return nil }
    let rates = DisplayModeCatalog.refreshRates(
      in: catalog.all, logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight
    ).map(DisplayMode.quantizedRefresh)
    let running = DisplayMode.quantizedRefresh(mode.refreshHz)
    guard let top = rates.max(), top > running else { return nil }
    return top
  }

  /// Words, grouped digits and no glyphs — the shared helper, so the hero, the
  /// mode rows and the report all say a mode the same way (a11y contract 5).
  private var spokenIdentity: String {
    var parts = [name]
    if let mode = currentMode {
      parts.append(ModeSpeech.spoken(
        logicalWidth: mode.logicalWidth,
        logicalHeight: mode.logicalHeight,
        // nil, never 0: a mode with no rate has no rate, and "at 0 hertz" is a
        // claim.
        refreshHz: mode.refreshHz > 0 ? mode.refreshHz : nil
      ))
      if let faster = fasterRateAtCurrentSize {
        parts.append("maximum \(ModeSpeech.spokenRate(faster))")
      }
    }
    if state.controller.isHDREngaged { parts.append("HDR on") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Sliders
  //
  // The menu bar's own slider component, bound to the same controllers — not a
  // second control over one model. The app-level appearance prefs come with it,
  // so snapping and the percent readout mean one thing everywhere.

  private var appPrefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  private var brightnessSlider: some View {
    DisplaySliderRow(
      controller: state.controller,
      displayName: name,
      snapsToStops: appPrefs.enableSliderSnap,
      showsPercent: appPrefs.enableSliderPercent,
      // Contract 3: the safety sentence rides in the LABEL, not only in the
      // caption beside the slider.
      accessibilityLabel: brightnessAccessibilityLabel,
      keyboardFloor: brightnessKeyboardFloor
    )
  }

  /// The volume command turned off for this display, or hardware control off
  /// altogether, removes the row — the same conjunct the menu bar applies
  /// (`DDCValueController.isAvailable`, which `setValue` self-gates on, so a
  /// visible slider is never a silently dead one).
  ///
  /// The row is the panel's own `ValueSliderRow`, so D29 rule 4 — a muting row
  /// never snaps to 0 — is DERIVED from the muted glyph in one place rather
  /// than passed by hand at a second construction site (T12 review).
  ///
  /// `hideVolumeSlider` is deliberately NOT read: that pref governs the menu
  /// bar's row, and this page is where you go to change it.
  @ViewBuilder private var volumeSlider: some View {
    if state.volume.isAvailable {
      let enabled = model.volumeSliderEnabled(state)
      ValueSliderRow(
        controller: state.volume,
        systemImage: "speaker.wave.2.fill",
        accessibilityLabel: "\(name) volume",
        snapsToStops: appPrefs.enableSliderSnap,
        showsPercent: appPrefs.enableSliderPercent,
        mutedSystemImage: "speaker.slash.fill"
      )
      .disabled(!enabled)
      // D24: greyed by the MONITOR's own denial, never by CoreAudio.
      .help(enabled ? "" : "\(name) reports no volume control over DDC")
    }
  }

  /// Above black-screen for the keyboard and VoiceOver routes only (a11y
  /// contract 7) — a drag can still reach 0, which is deliberate: a pointer
  /// user can see where they are going and can drag straight back.
  ///
  /// nil unless the screen can actually go black, which takes BOTH a software
  /// leg and the "Allow a fully dark display" pref: without it
  /// `DimmingMath.swTransform` floors the software leg at 15% of the panel's
  /// output, so 0 is dim and legible and a floor would only cost range.
  /// (`allowZeroSwBrightness` is stored unkeyed — it is app-wide, whichever
  /// `DisplayPrefs` reads it.)
  private var brightnessKeyboardFloor: Double? {
    guard prefs.allowZeroSwBrightness else { return nil }
    switch state.controller.brightnessPath {
    case .software, .combined, .softwareOnly:
      return Self.softwareDimmingFloor
    // `.hardware` bottoms out at the display's own minimum, `.native` at
    // macOS's, and `.unavailable` moves nothing at all.
    case .native, .hardware, .unavailable:
      return nil
    }
  }

  /// The safety sentence travels in the slider's LABEL, not only in the caption
  /// beside it (a11y contract 3): a VoiceOver user who lands on the slider hears
  /// why it is not doing what it looks like it does.
  private var brightnessAccessibilityLabel: String {
    guard let consequenceSentence else { return "\(name) brightness" }
    return "\(name) brightness. \(consequenceSentence)"
  }

  // MARK: - What the brightness value is worth

  /// ONE optional, so the two lines cannot both render (HDR wins, because it
  /// explains the readback silence as well: DDC is dead under HDR, so a
  /// write-only verdict recorded there would describe the cause, not the
  /// display).
  private enum BrightnessConsequence {
    case hdrEngaged
    case valueNotReadBack
  }

  private var consequence: BrightnessConsequence? {
    // Reused, never re-derived: the same projection the tuning grid and the
    // diagnostics page gate on, so one page cannot give two answers about one
    // display. On an EXTERNAL display `.macOSDrivesBrightness` is reachable
    // only through live HDR.
    if DisplayCardPolicy.ddcTrafficBlock(for: state.controller.brightnessPath)
      == .macOSDrivesBrightness {
      return .hdrEngaged
    }
    // The brightness controller's OWN evidence, not the folded worst-of-three
    // the diagnostics page states: this sentence is about the number on the
    // brightness slider, and a volume read that answered must not speak for it.
    // Both silent verdicts are grouped exactly as the diagnostics page groups
    // them — either way the value shown is what we last wrote.
    switch state.controller.readEvidence {
    case .allZeros, .noReply:
      return .valueNotReadBack
    case .answered, .notAttempted:
      return nil
    }
  }

  /// SO25: a remembered value is never presented with a measurement's
  /// confidence. Two sentences for HDR — one of the three cases that get the
  /// bigger budget (SO15), spent where the user is looking.
  private var consequenceSentence: String? {
    switch consequence {
    case .hdrEngaged:
      "HDR is on. macOS is setting this display's brightness; hardware commands are inactive."
    case .valueNotReadBack:
      "Brightness shown as last set: this display doesn't report its values."
    case nil:
      nil
    }
  }
}
