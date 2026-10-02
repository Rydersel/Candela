import AppKit
import CandelaKit
import SwiftUI

/// Control-Center-style menu-bar panel, one section per display. Built-in-first
/// ordering lives here in the view; `model.displays` stays external-only.
struct PanelView: View {
  /// Set from the status item's screen immediately before the menu opens.
  var maximumHeight: CGFloat? = nil

  @Environment(AppModel.self) private var model

  /// Optional so the render tests can lay the panel out with the app model
  /// alone; the app itself always injects it from `PanelRoot`.
  @Environment(UpdaterModel.self) private var updater: UpdaterModel?
  @Environment(UpdateReminderState.self) private var updateReminder: UpdateReminderState?

  /// One disclosure open at a time keeps the display list compact.
  /// Keyed by (display, section): keyed by display alone,
  /// opening one of a display's sections opens the other underneath it.
  var controlledDisclosure: PanelDisclosureID? = nil
  var changeDisclosure: ((PanelDisclosureID?) -> Void)? = nil
  @State private var localDisclosure: PanelDisclosureID?

  private var expandedSection: PanelDisclosureID? {
    get { changeDisclosure == nil ? localDisclosure : controlledDisclosure }
    nonmutating set {
      if let changeDisclosure { changeDisclosure(newValue) }
      else { localDisclosure = newValue }
    }
  }
  @State private var awakeDuration = KeepAwakeDuration.untilTurnedOff

  private var disclosureBinding: Binding<PanelDisclosureID?> {
    Binding(get: { expandedSection }, set: { value in
      expandedSection = value
    })
  }

  /// The menu drops the view hierarchy on close, so onAppear re-fires on every
  /// open and the settle plays each time.
  @State private var hasEntered = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Prefs are plain UserDefaults, not observable. Touching prefsRevision is
    // what re-renders the panel after a pane writes a panel-visible pref.
    let _ = model.prefsRevision
    let externals = Self.visibleDisplays(model)
    let showsBuiltIn = Self.showsBuiltIn(model)
    let appPrefs = DisplayPrefs(persistenceKey: "app")
    let snapsToStops = appPrefs.enableSliderSnap
    let showsPercent = appPrefs.enableSliderPercent
    let displayRows = VStack(alignment: .leading, spacing: 14) {
      if externals.isEmpty, !showsBuiltIn {
        emptyState
      }
      let combined = CombinedBrightness.participants(
        builtIn: showsBuiltIn ? model.builtIn : nil, externals: externals,
        prefs: Self.standardPrefs)
      if CombinedBrightness.shows(participantCount: combined.count, appPrefs: appPrefs) {
        VStack(alignment: .leading, spacing: 8) {
          Text("All displays")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true) // the slider carries the name
          CombinedSliderRow(
            participants: combined, snapsToStops: snapsToStops, showsPercent: showsPercent)
        }
      }
      if showsBuiltIn, let builtIn = model.builtIn {
        // Name header only, no HDR chrome: the built-in never routes HDR
        // (role .builtIn). The slider drives the native path, so Control
        // Center's own slider follows live.
        let name = Self.title(for: builtIn.display)
        VStack(alignment: .leading, spacing: 8) {
          Text(name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true) // the slider carries the display name
          DisplaySliderRow(
            controller: builtIn.controller, displayName: name,
            snapsToStops: snapsToStops, showsPercent: showsPercent
          )
        }
      }
      ForEach(externals) { state in
        let name = Self.title(for: state.display)
        let rowPrefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
        VStack(alignment: .leading, spacing: 8) {
          DisplayHeaderRow(
            controller: state.controller, displayName: name,
            toggleHDR: {
              PanelMenu.endTracking()
              Task { @MainActor in
                let result = await model.hdrAction.toggle(state)
                model.hdrFeedback.show(result.message, on: OverlayWindow.screen(for: state.id))
              }
            },
            // Asked of the engine that owns the pairing: a catalog refresh
            // inside an engage window answers "not engaged" with the mirror
            // already up.
            isShowingSynthesizedSize: model.synthesis.isEngaged(displayID: state.display.id),
            careLine: Self.careLine(for: state, model: model),
            careIsExpanded: expandedSection == PanelDisclosureID(state.id, .care),
            // No layout animation: the native window animates the resize, and
            // a second one here moved the controls around it (see Keep Awake).
            toggleCare: Self.offersCareActions(
              enrolled: rowPrefs.oledCareEnrolled, safeMode: model.isSafeMode) ? {
              let disclosure = PanelDisclosureID(state.id, .care)
              expandedSection = expandedSection == disclosure ? nil : disclosure
            } : nil
          )
          if Self.offersCareActions(enrolled: rowPrefs.oledCareEnrolled, safeMode: model.isSafeMode),
             expandedSection == PanelDisclosureID(state.id, .care) {
            carePauseActions(for: state, name: name)
              .transition(.opacity.animation(Motion.disclosure(reduceMotion: reduceMotion)))
          }
          DisplaySliderRow(
            controller: state.controller, displayName: name,
            snapsToStops: snapsToStops, showsPercent: showsPercent
          )
          // Not greyed like the volume denial below; the slider still
          // dims in software. `staysLive` keeps the hover watcher off drags.
          .panelHoverReason(model.brightnessSliderCompactReason(state), staysLive: true)
          if Self.showsVolumeSlider(for: state, prefs: rowPrefs) {
            let volumeEnabled = model.volumeSliderEnabled(state)
            ValueSliderRow(
              controller: state.volume,
              systemImage: "speaker.wave.2.fill",
              // The friendly-name local, not `state.display.name`: a renamed
              // display announces one name in every row of its section.
              accessibilityLabel: "\(name) volume",
              // Non-defaulted on `ValueSliderRow` by design: giving them
              // defaults would silently disable snapping and the percent
              // readout on every volume slider.
              snapsToStops: snapsToStops,
              showsPercent: showsPercent,
              // `ValueSliderRow` derives `snapsToZero: !mutesAtZero` from
              // this glyph. Dropping it lets the row snap to 0, which
              // hardware-mutes the display over VCP 0x8D.
              mutedSystemImage: "speaker.slash.fill"
            )
            .disabled(!volumeEnabled)
            // The reason comes from the policy that decided, so it cannot
            // name a cause other than the one that applied. Hover, not
            // a tooltip: the panel delivers no tooltip anywhere.
            .panelHoverReason(model.volumeSliderCompactReason(state))
          }
          if Self.showsContrastSlider(for: state, prefs: rowPrefs) {
            ValueSliderRow(
              controller: state.contrast,
              systemImage: "circle.lefthalf.filled",
              accessibilityLabel: "\(name) contrast",
              snapsToStops: snapsToStops,
              showsPercent: showsPercent
            )
          }
          PanelResolutionSection(
            displayID: state.id,
            displayName: name,
            coordinator: model.displayModes,
            expanded: disclosureBinding
          )
          // Shares the expansion binding above: only one disclosure may be
          // open. On a single-display rig it must resolve to nothing rather
          // than draw nothing, or the VStack spacing reserves a gap for it.
          PanelMirroringSection(
            displayID: state.id,
            displayName: name,
            coordinator: model.mirroring,
            expanded: disclosureBinding
          )
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    PanelLayout(maximumHeight: maximumHeight) {
      // Same predicate as the Keyboard pane's warning row, never a bare
      // `!isGranted`: an all-custom-shortcut rig needs no grant.
      if model.accessibility.isWarningWarranted {
        accessibilityBanner
          .fixedSize(horizontal: false, vertical: true)
        Divider()
      }
      // The frozen marker, never the live one: the freeze runs in `menuWillOpen`,
      // before the menu lays out, so this row's height is fixed for the open.
      if let marker = updateReminder?.markerAtOpen {
        updateReminderBanner(version: marker.version)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
      }
      // Keep the same hierarchy when a disclosure crosses the height limit.
      // The scroll view's ideal height still fits short lists to their content.
      ScrollView(.vertical) {
        displayRows
          // A transient overflow while a disclosure settles must not reserve
          // a legacy scroll bar's width and shift the brightness knobs.
          .background(OverlayScrollers())
      }
      .layoutValue(key: PanelDisplayViewport.self, value: true)
      .scrollBounceBehavior(.basedOnSize)
      Divider()
      if Self.showsKeepAwake(appPrefs: appPrefs) {
        keepAwakeRow
          .fixedSize(horizontal: false, vertical: true)
        Divider()
      }
      footer
    }
    .frame(width: 280)
    // The offset draws outside layout, so the entrance reflows nothing; the
    // menu window clips the first frames.
    .opacity(hasEntered ? 1 : 0)
    .offset(y: hasEntered ? 0 : -6)
    .onAppear {
      withAnimation(Motion.entrance(reduceMotion: reduceMotion)) { hasEntered = true }
    }
    // The menu can close without a mouse-exit event and drops the view
    // hierarchy, so hasEntered re-arms here for the next open.
    .onDisappear {
      if changeDisclosure == nil { localDisclosure = nil }
      hasEntered = false
    }
  }

  // MARK: - What the panel renders
  //
  // Static and non-private because StatusItemController asks the same question
  // to decide `.sliderOnly` menu-bar visibility.

  /// Externals the panel renders: hide applied, then ascending by
  /// friendly-or-hardware name. One call, so the sort cannot discard the
  /// filter the way the fork's does.
  ///
  /// `@MainActor` explicitly: on `View` only `body` is isolated, so a bare
  /// `static func` would be nonisolated and could not read `AppModel.displays`
  /// under `SWIFT_STRICT_CONCURRENCY: complete`.
  @MainActor
  static func visibleDisplays(_ model: AppModel) -> [AppModel.DisplayState] {
    visibleDisplays(model.displays, prefs: standardPrefs)
  }

  /// The same derivation over plain inputs, so it can be asked what it renders
  /// without an `AppModel` or the app's own prefs domain.
  @MainActor
  static func visibleDisplays(
    _ states: [AppModel.DisplayState],
    prefs: (String) -> DisplayPrefs
  ) -> [AppModel.DisplayState] {
    DisplayOrdering.panelOrder(
      states,
      isHidden: { prefs($0.display.persistenceKey).hideDisplay },
      title: { title(for: $0.display, prefs: prefs) }
    )
  }

  /// The built-in section, behind the app-level toggle. Candela's working
  /// version of the fork's `hideAppleFromMenu`, whose filter never ran.
  /// `@MainActor` because it reads `AppModel`.
  @MainActor
  static func showsBuiltIn(_ model: AppModel) -> Bool {
    showsBuiltIn(hasBuiltIn: model.builtIn != nil, appPrefs: standardPrefs("app"))
  }

  static func showsBuiltIn(hasBuiltIn: Bool, appPrefs: DisplayPrefs) -> Bool {
    hasBuiltIn && !appPrefs.hideBuiltInDisplay
  }

  /// The one name source for a display, so a rename in the Displays pane moves
  /// the header and every accessibility label together.
  static func title(for display: ExternalDisplay) -> String {
    title(for: display, prefs: standardPrefs)
  }

  static func title(for display: ExternalDisplay, prefs: (String) -> DisplayPrefs) -> String {
    DisplayOrdering.title(
      friendlyName: prefs(display.persistenceKey).friendlyName,
      hardwareName: display.name
    )
  }

  /// The prefs the app runs on, so the seams above take a factory instead of
  /// reaching for `UserDefaults.standard` from inside a derivation.
  static func standardPrefs(_ persistenceKey: String) -> DisplayPrefs {
    DisplayPrefs(persistenceKey: persistenceKey)
  }

  /// The built-in's switch lives on Menu Bar, an external's on its own page, so
  /// pointing only at Displays sends a clamshell user to a switch that is not there.
  static func unhideHint(builtInHidden: Bool, externalsHidden: Bool) -> String {
    switch (builtInHidden, externalsHidden) {
    case (true, true):
      "Show them again in Settings → Menu Bar and Settings → Displays."
    case (true, false):
      "Show it again in Settings → Menu Bar."
    case (false, true):
      "Show one again in Settings → Displays."
    default:
      // (false, false): nothing is hidden, so nothing asked this question.
      "Show one again in Settings → Displays."
    }
  }

  /// Two empties: nothing attached is a hardware fact, everything hidden is
  /// undoable, so that branch says where to undo it.
  private var emptyState: some View {
    VStack(spacing: 4) {
      if model.displays.isEmpty, model.builtIn == nil {
        Text("No controllable displays")
        // Discovery drops anything without an IOAVService, so a DisplayLink or
        // AirPlay panel never appears here and the line above reads as a fault.
        emptyCaption(
          "Displays on DisplayLink, AirPlay or Sidecar have no DDC channel, so they cannot be controlled."
        )
      } else {
        Text("Every display is hidden")
        // Nothing is visible here, so every display that exists is hidden.
        emptyCaption(Self.unhideHint(
          builtInHidden: model.builtIn != nil && !Self.showsBuiltIn(model),
          externalsHidden: !model.displays.isEmpty
        ))
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
  }

  /// The panel is fixed-width, so a wrapping caption needs its height freed.
  private func emptyCaption(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.system(size: 11))
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Slider visibility
  //
  // Only externals get value rows: the built-in's volume/contrast controllers
  // are placeholders on a `NoopDDCWriter` that still reports `isAvailable`, so
  // rendering them would show a live-looking slider that does nothing.

  /// Volume slider per DDC display, unless hidden, disabled per command, or
  /// `forceSoftware`. The last two are `DDCValueController.isAvailable`, the
  /// same gate `setValue` self-gates on, so a visible slider is never a dead one.
  ///
  /// This removes the row. `AppModel.volumeSliderEnabled` greys it instead, for
  /// a monitor that denies volume; these conjuncts mean the control does not
  /// apply here at all.
  @MainActor
  static func showsVolumeSlider(for state: AppModel.DisplayState, prefs: DisplayPrefs) -> Bool {
    showsVolumeSlider(
      commandIsAvailable: state.volume.isAvailable, hideVolumeSlider: prefs.hideVolumeSlider)
  }

  static func showsVolumeSlider(commandIsAvailable: Bool, hideVolumeSlider: Bool) -> Bool {
    commandIsAvailable && !hideVolumeSlider
  }

  /// Contrast slider behind the app-level `showContrast` pref (default
  /// false, fork parity), never for a disabled or `forceSoftware` display.
  /// `showContrast` is unkeyed, so the display's own prefs object answers it.
  @MainActor
  static func showsContrastSlider(for state: AppModel.DisplayState, prefs: DisplayPrefs) -> Bool {
    showsContrastSlider(
      commandIsAvailable: state.contrast.isAvailable, showContrast: prefs.showContrast)
  }

  static func showsContrastSlider(commandIsAvailable: Bool, showContrast: Bool) -> Bool {
    showContrast && commandIsAvailable
  }

  /// Banner, not alert (spec §6). Shown only while the grant is missing and a
  /// key mode wants it; `AccessibilityPermission` observes for the app's
  /// lifetime, so a revoked grant brings this back with no relaunch.
  private var accessibilityBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Text("Keyboard control needs Accessibility access")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button("Open Settings…") {
        // No window can take focus during menu tracking, so System Settings would
        // open behind the frontmost app. Queued: `endTracking` only asks the
        // session to end, and a synchronous open still runs inside it.
        PanelMenu.endTracking()
        Task { @MainActor in model.accessibility.openSystemSettings() }
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
      .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  /// A scheduled update never takes the screen, so this row is how it announces
  /// itself. Words rather than a badge, like the mirroring row: the state has to
  /// survive a screenshot in a bug report.
  ///
  /// Rendered from the marker frozen in `menuWillOpen`, so nothing about the row
  /// changes for one open, which keeps it out of the grows-while-open failure
  /// `keepAwakeRow` records.
  private func updateReminderBanner(version: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Text("Update available: \(version)")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      // No ellipsis: this brings forward a dialog the app already prepared rather
      // than opening another app.
      Button("Show Update") {
        // No window can take focus during menu tracking, and `endTracking` only
        // asks the session to end, so a synchronous call would still run inside it.
        PanelMenu.endTracking()
        Task { @MainActor in updater?.bringUpdateForward() }
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
      .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  /// Holds a power assertion for the app rather than touching a display, so it
  /// sits outside the per-display stack.
  ///
  /// One line, and its height never changes with state: a caption that appeared
  /// while the toggle was on grew the panel inside the already-open `NSMenu` and
  /// clipped the footer off the bottom [MEASURED 2026-08-19]. Hence the compact
  /// end time and `lineLimit(1)`; `PanelSizingTests` pins the widest label to
  /// the column.
  ///
  /// OLED care's idle dim, blackout and unfocused dim cannot engage while this
  /// is on, which Settings > Menu Bar states next to the hide switch.
  private var keepAwakeRow: some View {
    let disclosure = PanelDisclosureID(0, .keepAwake)
    let expanded = expandedSection == disclosure
    let title = Self.keepAwakeTitle(expiresAt: model.keepAwake.expiresAt)
    let status = model.keepAwake.expiresAt.map { "Awake until \(CompactEndTimeText.string($0))" }
      ?? (model.keepAwake.isOn ? "Until turned off" : "Off")
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        Button {
          if !expanded { synchronizeAwakeDuration() }
          // The native window animates the size. Animating this layout too
          // makes the flexible display viewport grow and then shrink again.
          expandedSection = expanded ? nil : disclosure
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "cup.and.saucer.fill")
            Text(verbatim: title)
              .lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.system(size: 8, weight: .semibold))
              .rotationEffect(.degrees(expanded ? 180 : 0))
              .animation(Motion.disclosure(reduceMotion: reduceMotion), value: expanded)
          }
          .font(.system(size: Self.keepAwakeFontSize))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keep display awake duration")
        .accessibilityValue(Text(verbatim: Self.disclosureValue(status, expanded: expanded)))
        Spacer(minLength: 8)
        Toggle("", isOn: Binding(
          get: { model.keepAwake.isOn },
          set: { on in
            if on { awakeDuration.apply(to: model.keepAwake) }
            else { model.keepAwake.setOn(false) }
          }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityLabel("Keep display awake")
      }
      if expanded {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Duration").foregroundStyle(.secondary)
            Spacer()
            Text(awakeDuration.title).monospacedDigit()
          }
          .font(.system(size: 11))
          SelectionSlider(value: Binding(
            get: { Double(awakeDuration.rawValue) },
            set: { value in
              if let duration = Self.chooseAwakeDuration(value, keepAwake: model.keepAwake) {
                awakeDuration = duration
              }
            }), stopCount: KeepAwakeDuration.allCases.count,
            accessibilityLabel: "Keep awake duration",
            valueDescription: Self.keepAwakeStopTitle)
            .frame(height: 18)
          HStack {
            Text("15 min")
            Spacer()
            Image(systemName: "infinity")
          }
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          Button("Custom End Time…") {
            expandedSection = nil
            model.chooseKeepAwakeEndTime()
          }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .frame(minHeight: 24, alignment: .leading)
          .accessibilityLabel("Keep display awake, Custom End Time…")
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .transition(.opacity.animation(Motion.disclosure(reduceMotion: reduceMotion)))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .onAppear { synchronizeAwakeDuration() }
  }

  static let keepAwakeFontSize: CGFloat = 12

  /// "Until", not "Awake until": the cup and the switch beside it already say
  /// what is held, and "Awake until tomorrow" at the widest clock time measured
  /// 180 pt in a 170 pt column.
  static func keepAwakeTitle(
    expiresAt: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    expiresAt.map {
      "Until \(CompactEndTimeText.string($0, now: now, calendar: calendar, locale: locale))"
    } ?? "Keep display awake"
  }

  /// A choice on the slider always starts the hold, the current stop included:
  /// the stop shown is only the one nearest the time left, so re-choosing it is
  /// how a person asks for that full duration from now. `start(for:)` replaces
  /// the deadline on the one assertion, so a repeat never takes a second.
  @discardableResult
  static func chooseAwakeDuration(_ value: Double, keepAwake: KeepAwake) -> KeepAwakeDuration? {
    guard let duration = KeepAwakeDuration(rawValue: Int(value.rounded())) else { return nil }
    duration.apply(to: keepAwake)
    return duration
  }

  /// What the native slider speaks for a stop. The `NSSlider` is its own
  /// accessibility element, so a SwiftUI value on the representable may never
  /// reach it, and its default value is the bare stop index.
  nonisolated static func keepAwakeStopTitle(_ value: Double) -> String {
    KeepAwakeDuration(rawValue: Int(value.rounded()))?.title ?? ""
  }

  /// Both panel disclosures put their open state in the value, so VoiceOver
  /// reads the two the same way.
  static func disclosureValue(_ status: String, expanded: Bool) -> String {
    "\(status), \(expanded ? "expanded" : "collapsed")"
  }

  private func synchronizeAwakeDuration() {
    guard model.keepAwake.isOn else { return }
    awakeDuration = model.keepAwake.expiresAt.map {
      KeepAwakeDuration.closest(to: $0.timeIntervalSinceNow)
    } ?? .untilTurnedOff
  }

  /// Presentation only: hiding the row does not release an assertion an earlier
  /// toggle took, so this asks nothing about `KeepAwake` itself.
  @MainActor
  static func showsKeepAwake(appPrefs: DisplayPrefs) -> Bool {
    !appPrefs.hideKeepAwake
  }

  private var footer: some View {
    HStack(spacing: 0) {
      FooterPillButton(systemImage: "gearshape", title: "Settings…") {
        SettingsOpener.open()
      }
      Spacer(minLength: 8)
      // Trailing, so the destructive action is furthest from where the pointer
      // rests after dragging a slider.
      FooterPillButton(systemImage: "power", title: "Quit") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 32)
  }
}

/// The menu host can still propose its old height on the first disclosure
/// frame. Measure against the screen budget, not that stale proposal, so the
/// display viewport and controls above the disclosure keep their positions.
private struct PanelLayout: Layout {
  var maximumHeight: CGFloat?

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 280
    return CGSize(width: width, height: heights(subviews, width: width).reduce(0, +))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let heights = heights(subviews, width: bounds.width)
    var y = bounds.minY
    for (subview, height) in zip(subviews, heights) {
      subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: height))
      y += height
    }
  }

  private func heights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
    var heights = subviews.map {
      $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
    if let maximumHeight, let viewport = subviews.firstIndex(where: { $0[PanelDisplayViewport.self] }) {
      let pinnedHeight = heights.enumerated().reduce(CGFloat.zero) {
        $0 + ($1.offset == viewport ? 0 : $1.element)
      }
      heights[viewport] = min(heights[viewport], max(0, maximumHeight - pinnedHeight))
    }
    return heights
  }
}

private struct PanelDisplayViewport: LayoutValueKey {
  static let defaultValue = false
}

/// The panel's menu tracking session, so a control inside the panel can end it.
/// Set once at launch by `StatusItemController`.
///
/// Tracking holds the main run loop in event-tracking mode: a window cannot take
/// focus and queued main-actor work is starved until tracking ends.
@MainActor
enum PanelMenu {
  static weak var menu: NSMenu?
  private static var isClosing = false
  private static weak var sizingWindow: NSWindow?
  private static var verticalInsets: CGFloat = 0
  private static var disclosureFrame: NSRect?

  static func beginTracking() {
    isClosing = false
    sizingWindow = nil
    disclosureFrame = nil
  }

  static func prepareForDisclosureChange() {
    guard !isClosing, let view = menu?.items.first?.view, let window = view.window,
          window.isVisible else { return }
    disclosureFrame = window.frame
    if sizingWindow !== window {
      verticalInsets = max(0, window.frame.height - view.fittingSize.height)
      sizingWindow = window
    }
  }

  static func refitAfterDisclosureChange() {
    // Called after the click changes state, outside SwiftUI's update callbacks.
    // Reading the new layout here is safe and lets the host and native menu
    // resize together before any intermediate frame is presented.
    guard !isClosing, let menu, let item = menu.items.first, let view = item.view,
          let window = view.window, window.isVisible else { return }
    let fitted = view.fittingSize
    guard fitted.width > 0, fitted.height > 0 else { return }
    let before = disclosureFrame ?? window.frame
    disclosureFrame = nil
    view.setFrameSize(fitted)
    menu.itemChanged(item)
    var destination = before
    destination.size.height = fitted.height + verticalInsets
    destination.origin.y = before.maxY - destination.height
    // AppKit lays the menu's scroll container out at the final height
    // before the window animates. Its default bottom anchor would move
    // every existing control by the disclosure's height during that resize.
    // Pin that container to the content view's top edge instead.
    var container = view
    while let parent = container.superview, parent !== window.contentView {
      container = parent
    }
    if let parent = container.superview, parent === window.contentView {
      var mask = container.autoresizingMask
      mask.remove([.minYMargin, .maxYMargin, .height])
      mask.insert(parent.isFlipped ? .maxYMargin : .minYMargin)
      container.autoresizingMask = mask
    }
    window.setFrame(before, display: false)
    let duration = Motion.windowResize(reduceMotion: Motion.systemReduceMotion)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      if duration == 0 { window.setFrame(destination, display: true) }
      else { window.animator().setFrame(destination, display: true) }
    }
  }

  static func endTracking() {
    // A control closing the menu must also cancel a pending disclosure refit.
    isClosing = true
    menu?.cancelTracking()
  }
}

extension PanelView {
  // MARK: - The care line

  /// The caption under an external display's name, nil when there is nothing to
  /// say. The Menu Bar preview calls this too, so both surfaces derive one line.
  @MainActor
  static func careLine(for state: AppModel.DisplayState, model: AppModel) -> String? {
    careLine(
      persistenceKey: state.display.persistenceKey,
      prefs: standardPrefs(state.display.persistenceKey),
      care: model.oledCare, safeMode: model.isSafeMode)
  }

  /// The rows the care disclosure opens to, in order.
  enum CareAction: CaseIterable {
    case resume, pauseQuarterHour, pauseHour, pauseUntil

    var title: String {
      switch self {
      case .resume: "Resume Now"
      case .pauseQuarterHour: "Pause Dimming for 15 Minutes"
      case .pauseHour: "Pause Dimming for 1 Hour"
      case .pauseUntil: "Pause Dimming Until…"
      }
    }
  }

  /// No disclosure while the care loop is not running (Safe Mode) or the
  /// display is not enrolled: there is no dimming to pause.
  static func offersCareActions(enrolled: Bool, safeMode: Bool) -> Bool {
    enrolled && !safeMode
  }

  static func careActions(enrolled: Bool, safeMode: Bool, paused: Bool) -> [CareAction] {
    guard offersCareActions(enrolled: enrolled, safeMode: safeMode) else { return [] }
    return CareAction.allCases.filter { $0 != .resume || paused }
  }

  static let careActionsCaption =
    "Measurement and display hours continue; macOS can still sleep the display."

  private func carePauseActions(for state: AppModel.DisplayState, name: String) -> some View {
    let key = state.display.persistenceKey
    let actions = Self.careActions(
      enrolled: true, safeMode: false,
      paused: model.oledCare.dimmingPauseDeadline(for: key) != nil)
    return VStack(alignment: .leading, spacing: 2) {
      ForEach(actions, id: \.self) { action in
        PanelActionRow(title: LocalizedStringKey(action.title), accessibilityName: name) {
          switch action {
          case .resume:
            model.oledCare.resumeDimming(for: key)
            expandedSection = nil
            PanelMenu.endTracking()
          case .pauseQuarterHour: pauseDimming(for: state, duration: 15 * 60)
          case .pauseHour: pauseDimming(for: state, duration: 60 * 60)
          case .pauseUntil:
            expandedSection = nil
            model.chooseDimmingPauseEndTime(for: key, name: name)
          }
        }
      }
      PanelCaption(LocalizedStringKey(Self.careActionsCaption), style: .secondary)
    }
  }

  private func pauseDimming(for state: AppModel.DisplayState, duration: TimeInterval) {
    model.oledCare.pauseDimming(for: state.display.persistenceKey, duration: duration)
    expandedSection = nil
    PanelMenu.endTracking()
  }

  /// Reads the summary only where the line will show it, so an un-enrolled
  /// display's history stays unstated, as on the Health pane, and a paused
  /// line costs no store decode in this view body.
  @MainActor
  static func careLine(
    persistenceKey: String, prefs: DisplayPrefs, care: OledCareCoordinator, safeMode: Bool
  ) -> String? {
    let enrolled = prefs.oledCareEnrolled
    let pausedUntil = enrolled && !safeMode ? care.dimmingPauseDeadline(for: persistenceKey) : nil
    return careLine(
      enrolled: enrolled, hours: care.hoursTracker(for: persistenceKey).totalHours,
      safeMode: safeMode, suspended: care.dimStates[persistenceKey] == .suspended,
      pausedUntil: pausedUntil, summary: { care.healthSummary(for: persistenceKey) })
  }

  /// The decision half of the coordinator form above, with the summary read
  /// deferred so the test can see whether the line asked for it.
  static func careLine(
    enrolled: Bool, hours: Double, safeMode: Bool, suspended: Bool, pausedUntil: Date?,
    summary: () -> PanelHealthSummary?,
    now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
  ) -> String? {
    let showsPause = enrolled && !safeMode && !suspended && pausedUntil != nil
    let summary = enrolled && !safeMode && !showsPause ? summary() : nil
    return careLine(
      enrolled: enrolled, hours: hours, summary: summary, safeMode: safeMode,
      suspended: suspended, pausedUntil: pausedUntil,
      now: now, calendar: calendar, locale: locale)
  }

  /// A suspension outranks the user's pause, as it does in the engine, so a
  /// mirrored display or one showing a checkup field gets the ordinary care
  /// line rather than a pause that is not what holds dimming off. The line has
  /// no room for the suspension's reason; the display's OLED Care page states it.
  /// The paused form stands alone because it is the one thing the row has to
  /// say, and with the hours beside it the widest end time no longer fit one
  /// line (`PanelSizingTests` pins the width). The hours return with the dimming.
  static func careLine(
    enrolled: Bool, hours: Double, summary: PanelHealthSummary?, safeMode: Bool,
    suspended: Bool, pausedUntil: Date?,
    now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
  ) -> String? {
    if enrolled, !safeMode, !suspended, let pausedUntil {
      return "Dimming paused until \(CompactEndTimeText.string(pausedUntil, now: now, calendar: calendar, locale: locale))"
    }
    return PanelCareLine.text(
      enrolled: enrolled, hours: hours, summary: summary, safeMode: safeMode)
  }

  /// Why the panel's HDR button cannot act, or nil when it can.
  ///
  /// Only the ENGAGE direction is refused: with HDR live the button offers the
  /// exit, and greying that would be the forbidden shape: a recovery control
  /// unavailable in the state it recovers from.
  /// `BrightnessController.setHDRMode` enforces the same asymmetry.
  ///
  /// Capability before size: dropping the size would not bring HDR to a display
  /// with no HDR modes. `capabilityProbed` guards the unprobed reading, where
  /// `supportsHDR` is false only because the refresh has not answered.
  static func hdrRefusalReason(
    isShowingSynthesizedSize: Bool, isHDREngaged: Bool,
    supportsHDR: Bool, capabilityProbed: Bool
  ) -> String? {
    guard !isHDREngaged else { return nil }
    if capabilityProbed, !supportsHDR {
      return Self.hdrNoModesCaption
    }
    guard isShowingSynthesizedSize else { return nil }
    return SynthesisCopy.hdrBlockedBySynthesizedSize
  }

  /// Not `DiagnosticsCopy.hdrNoAnswer`: alone, "has no HDR answer" reads as the
  /// app not knowing.
  static let hdrNoModesCaption = "No HDR modes were found for this display."

  /// Grey and uncaptioned until the probe answers. Engaged outranks everything,
  /// as in `hdrRefusalReason`: this button is the way out of HDR, and a panel
  /// swap drops the probe flag while the engaged cache still reads true.
  static func hdrButtonIsEnabled(
    isHDREngaged: Bool, capabilityProbed: Bool, supportsHDR: Bool, refusalReason: String?
  ) -> Bool {
    if isHDREngaged { return true }
    return capabilityProbed && supportsHDR && refusalReason == nil
  }
}

/// Section header for one display, all secondary-colored so the slider stays
/// the row's only emphasis.
private struct DisplayHeaderRow: View {
  let controller: BrightnessController
  let displayName: String
  let toggleHDR: () -> Void
  let isShowingSynthesizedSize: Bool
  /// `PanelView.careLine`'s answer. Nil draws nothing, keeping the row one line tall.
  let careLine: String?
  let careIsExpanded: Bool
  let toggleCare: (() -> Void)?

  @State private var isHovering = false
  @State private var isCareHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Reads the state, not the `hdrMode` pref: the two diverge the moment HDR is
  /// toggled in System Settings, and the badge beside this button reads state,
  /// so a mode-sourced label put "HDR" next to "HDR Off".
  private var modeLabel: String {
    controller.isHDREngaged ? "HDR On" : "HDR Off"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(displayName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityHidden(true)  // the slider carries the display name
        if controller.isHDREngaged {
          Text("HDR")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary))
            .accessibilityLabel("HDR engaged")
        }
        Spacer(minLength: 4)
        hdrModeButton
      }
      if let careLine {
        if let toggleCare {
          Button(action: toggleCare) {
            HStack(spacing: 6) {
              careStatus(careLine)
              Spacer(minLength: 4)
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(careIsExpanded ? 180 : 0))
                .animation(Motion.disclosure(reduceMotion: reduceMotion), value: careIsExpanded)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(PanelRowButtonStyle(isHovering: isCareHovering))
          .onHover { isCareHovering = $0 }
          .onDisappear { isCareHovering = false }
          .accessibilityLabel(Text(verbatim: "\(displayName) dimming controls"))
          .accessibilityValue(Text(verbatim: PanelView.disclosureValue(careLine, expanded: careIsExpanded)))
        } else {
          careStatus(careLine)
            .accessibilityLabel(Text(verbatim: "\(displayName), \(careLine)"))
        }
      }
    }
    // On the row, not the button: the caption draws in a leading-aligned column
    // under whatever it wraps, and the button's slot is a few characters wide.
    //
    // The row grows a line when a size engages, but that reconfiguration ends
    // menu tracking and rebuilds the panel, so it cannot clip the footer the way
    // a height change inside an open panel does.
    .panelHoverReason(refusalReason)
  }

  private func careStatus(_ line: String) -> some View {
    Text(verbatim: line)
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  private var refusalReason: String? {
    PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: isShowingSynthesizedSize,
      isHDREngaged: controller.isHDREngaged,
      supportsHDR: controller.supportsHDR,
      capabilityProbed: controller.hdrCapabilityProbed
    )
  }

  /// A toggle, not a `Menu`: the panel is hosted in an `NSMenu` item and the
  /// enclosing menu owns event tracking, so a nested SwiftUI `Menu` never opens
  /// (measured on hardware). Plain buttons do work; the label names the mode.
  private var hdrModeButton: some View {
    Button(action: toggleHDR) {
      Text(modeLabel)
        .font(.system(size: 12))
    }
    .buttonStyle(HDRModeButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // The menu can close without a mouse-exit event (Escape, or clicking the
    // status item), which would leave a phantom highlight on the next open.
    .onDisappear { isHovering = false }
    .fixedSize()
    // Disable, don't hide, on non-HDR displays. Both flags are
    // observation-tracked, so the button enables when the async refresh lands.
    .disabled(!PanelView.hdrButtonIsEnabled(
      isHDREngaged: controller.isHDREngaged,
      capabilityProbed: controller.hdrCapabilityProbed,
      supportsHDR: controller.supportsHDR,
      refusalReason: refusalReason
    ))
    // No `.help`: the panel delivers no tooltip at all, enabled controls
    // included. Menu tracking is the cause, not the greying next door.
    .accessibilityLabel("\(displayName) HDR mode")
    .accessibilityValue(modeLabel)
  }
}

/// Same hover/press feedback language as `FooterIconButtonStyle`, with text
/// metrics instead of a square icon frame.
private struct HDRModeButtonStyle: ButtonStyle {
  let isHovering: Bool
  // The style must read enablement itself, or a disabled button renders live
  // (hover fill, primary text) and silently does nothing.
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
    let foreground: HierarchicalShapeStyle = if !isEnabled {
      .quaternary
    } else if hovering {
      .primary
    } else {
      .secondary
    }
    return configuration.label
      .foregroundStyle(foreground)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

// `DisplaySliderRow` and `ValueSliderRow` are shared with the settings hero, so
// the mute-strand rule's `snapsToZero` derivation exists in one place.

/// Footer action button: a symbol and a word on a rounded background that
/// appears on hover, with a distinct pressed state.
///
/// `power` means "shut down" on macOS, so on the quit button the word carries
/// the meaning and the symbol only balances the gear opposite it.
private struct FooterPillButton: View {
  let systemImage: String
  let title: LocalizedStringKey
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .medium))
        Text(title)
          .font(.system(size: 12))
      }
      .padding(.horizontal, 8)
      .frame(height: 22)
    }
    .buttonStyle(FooterIconButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // The menu can close without a trailing mouse-exit event (Escape, or
    // clicking the status item), leaving a stuck highlight on the next open.
    .onDisappear { isHovering = false }
  }
}

private struct FooterIconButtonStyle: ButtonStyle {
  let isHovering: Bool
  // Same enablement handling as HDRModeButtonStyle.
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
    let foreground: HierarchicalShapeStyle = if !isEnabled {
      .quaternary
    } else if hovering {
      .primary
    } else {
      .secondary
    }
    return configuration.label
      .foregroundStyle(foreground)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

/// An end time short enough for a one-line panel row: the time alone today,
/// "tomorrow", a weekday within the week, a month and day further out, and the
/// year only where a deadline a year out would otherwise read as today's date.
///
/// Names are English whatever the system language, because the app ships in
/// English only and the words around them are English; only the 12- or 24-hour
/// clock follows the person's own locale.
enum CompactEndTimeText {
  static func string(
    _ deadline: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    var names = Locale.Components(locale: Locale(identifier: "en_US"))
    names.hourCycle = locale.hourCycle
    var style = Date.FormatStyle(
      locale: Locale(components: names), calendar: calendar, timeZone: calendar.timeZone)
    let time = deadline.formatted(style.hour().minute())
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: deadline)
    ).day ?? 0
    switch days {
    case ...0: return time
    case 1: return "tomorrow, \(time)"
    case 2...6:
      style = style.weekday(.abbreviated)
      return "\(deadline.formatted(style)), \(time)"
    default:
      style = style.month(.abbreviated).day()
      let sameDate = calendar.dateComponents([.month, .day], from: deadline)
        == calendar.dateComponents([.month, .day], from: now)
      if sameDate { style = style.year() }
      return "\(deadline.formatted(style)), \(time)"
    }
  }
}
