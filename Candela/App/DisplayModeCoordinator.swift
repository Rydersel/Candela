import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of display-mode enumeration, the preview countdown, and
/// stored-mode writes.
///
/// A view cannot own the session: the countdown has to keep running after the
/// view that started it goes away, which is the whole safety argument for
/// previewing (a mode can leave the screen unreadable, so the safe outcome must
/// be the one that happens when nobody does anything). It lives on `AppModel`,
/// where the settings pane and the panel drive ONE session.
///
/// Two rules hold this together:
///
/// 1. **Every session-touching operation is serialised** through `queue`.
///    Without it, two clicks both suspend inside `begin()`, the actor serialises
///    them, and their main-actor continuations resume in an unrelated order,
///    leaving the banner naming one mode while "Keep" commits the other at
///    session scope.
/// 2. **The UI's state is rebuilt FROM the session** (`adopt`), never from what
///    a caller remembers passing in. The two disagree exactly when something
///    went wrong, and the session decides what is applied.
@MainActor @Observable
final class DisplayModeCoordinator {
  /// Which surface asked for the preview that is outstanding.
  ///
  /// Not where a PREVIEW is answered: `PreviewSurface` decides that, and the two
  /// answer different questions ("who asked" against "who answers"). Origin
  /// decides where a failed `begin()` is reported. The settings pane has a row of
  /// its own and stays on screen, while the panel's `NSMenu` tracking session ends
  /// on the selection itself, so a panel-origin failure would be shown to nobody.
  enum PreviewOrigin: Sendable {
    case settings
    case panel
  }

  /// Which surface ANSWERS the outstanding preview (SO6): exactly one is
  /// answerable per preview. Decided at preview start and carried on the
  /// preview, never re-derived mid-countdown, so the buttons cannot migrate
  /// under the user's pointer.
  ///
  /// THREE owners, not two (DM11). `.settingsBanner` iff the change originated in
  /// the settings window while it was key (the caller reads its own
  /// `controlActiveState` at the click). `.guidedSetup` iff the guided setup flow
  /// started the apply, since that window draws its own Keep and Revert from the
  /// observable preview state. Everything else, the panel and a settings surface
  /// in a non-key window included, is answered by the floating
  /// `ConfirmationPanel`. A non-owning surface renders passive text at most.
  enum PreviewSurface: Sendable {
    case floatingPanel
    case settingsBanner
    case guidedSetup
  }

  /// Everything one display's UI renders, computed once per enumeration.
  /// Enumerating costs several CoreGraphics round-trips, so it is done on
  /// demand and cached, never per body evaluation. A missing entry means "not
  /// enumerated yet" and is deliberately distinct from an entry with no modes.
  struct Catalog: Equatable {
    let display: ConfiguredDisplay
    let rows: [DisplayModeRow]
    let all: [DisplayMode]
    let current: DisplayMode?
    /// Denominator of the curation caption. Distinct LOGICAL SIZES, not modes:
    /// the curated list is one row per size, so counting modes would compare 11
    /// against 332 and read as though we were hiding 321 resolutions.
    let distinctLogicalSizes: Int
    /// The panel's own framebuffer, from the mode carrying the native flag. nil
    /// when no mode carries it: `isScaled` is then undecidable and the badge is
    /// suppressed rather than guessed, since comparing against a zero-sized panel
    /// would mark every mode as scaled.
    ///
    /// The SIZE rather than a bare "is it known" flag, because the full list has
    /// to answer `isScaled` per mode and only curated rows carry a precomputed
    /// answer.
    let nativePixels: PixelSize?
    /// How many revealed modes the wire-timing guard withheld. Reported rather
    /// than merely applied (CR11): on a hardware pass this count is what
    /// distinguishes "the guard fired" from "revelation found nothing".
    let withheldForWireTiming: Int
    /// What the density model made of this panel, judged over the SAME curated
    /// rows this catalog publishes (PD1): a size the wire-timing guard withheld
    /// has no apply path, so it must never become a recommendation.
    ///
    /// nil when the panel's native pixels are unknown, or when no facts provider
    /// is installed. A display with no entry in the app's hardware facts is NOT
    /// this case: the provider still answers, with nil sizes, and the model
    /// abstains with a `.noPhysicalSize` verdict. Either way, no geometry means no
    /// judgement rather than one made from zeros.
    let density: DensityVerdict?
    /// The synthesized stops this panel is offered (SS3/SS4), in the same
    /// descending order as `rows`. Empty when the display has not opted in, is
    /// the built-in (SS14), or has no native geometry to take a percentage of.
    ///
    /// Kept beside `rows` because a selection has to get from a picked ROW back
    /// to the `SyntheticSize` the engine engages, and a row carries only its
    /// geometry and a sentinel mode ID.
    ///
    /// `var` with a default only so the memberwise initialiser carries one: a
    /// `let` with a default is left OUT of that initialiser entirely, and the
    /// app-test fixtures build a catalog by hand. The coordinator always passes
    /// both this and the field below.
    var syntheticStops: [SyntheticSize] = []
    /// The stop currently on the glass, from the ENGINE's pairing table.
    ///
    /// The readback is not the answer. Since the engage tail re-times the slave
    /// onto its own mode, an engaged panel reports a REAL descriptor naming its
    /// native geometry [MEASURED 2026-08-18], so a reader matching against it
    /// lands confidently on the wrong row. This is what the current-row highlight
    /// reads instead; see `isCurrentSize` and `onScreen`.
    var engagedSyntheticSize: SyntheticSize?

    var nativeKnown: Bool { nativePixels != nil }

    /// **What is on the glass**, as a mode a surface can name. The one accessor
    /// every "what is this display running" reader goes through.
    ///
    /// `current` is the raw readback, and while a stop is engaged it is not the
    /// answer: the engage tail re-times the slave, so the panel publishes a REAL
    /// descriptor (the HiDPI twin of its own mode) that readers would match
    /// confidently and wrongly. The engine's pairing decides instead (SS1).
    ///
    /// The RATE comes from the readback, because the twin it re-times onto carries
    /// the panel's own refresh by construction. Label-only: nothing may match or
    /// persist this value, and the sentinel `ioModeID` a synthesized row carries is
    /// never sent to CoreGraphics.
    var onScreen: DisplayMode? {
      guard let engagedSyntheticSize else { return current }
      let row = SyntheticSizeCatalog.row(for: engagedSyntheticSize)
      guard let hz = current?.refreshHz, hz > 0 else { return row }
      return DisplayMode(
        ioModeID: row.ioModeID,
        logicalWidth: row.logicalWidth, logicalHeight: row.logicalHeight,
        pixelWidth: row.pixelWidth, pixelHeight: row.pixelHeight,
        refreshHz: hz, isNative: false, provenance: .synthesized
      )
    }

    /// What the already-on-screen no-op guards compare against. While a stop is
    /// engaged the answer is nil: the stop is what is on screen (SS1), and the
    /// engage tail re-times the slave onto a mode the panel really publishes.
    /// Comparing against that descriptor made picking the native size a silent
    /// no-op, which is the one pick that disengages [MEASURED 2026-08-18: a real
    /// mouse click did nothing]. The re-time lands on the HiDPI twin now, which
    /// moves the collision to another row rather than removing it.
    var alreadyOnScreenModeID: Int32? {
      engagedSyntheticSize == nil ? current?.ioModeID : nil
    }
  }

  /// The panel-derived values a catalog is built from, cached per
  /// `DisplayConfigIdentity.key` while the display is showing its own desktop.
  ///
  /// **Reused while a synthesized size is engaged, and that is the whole point.**
  /// An engaged panel is a mirror slave: its readbacks describe the virtual master
  /// rather than the panel, so a pass that re-derived the native pixels, the
  /// density verdict or the stop ladder from them would rewrite all three from the
  /// wrong display, and the engaged row could vanish from its own picker.
  private struct PanelBaseline {
    let nativePixels: PixelSize?
    /// The native-flagged mode's LOGICAL size, which is what SS3's percentages
    /// are percentages of. Not the pixel size: the two differ on a panel whose
    /// native mode is HiDPI.
    let nativeLogicalWidth: Int?
    let nativeLogicalHeight: Int?
    let stops: [SyntheticSize]
  }

  /// What the app layer knows about a panel that CoreGraphics mode enumeration
  /// does not. Two joins meet here and neither belongs in the Kit (PD7): the
  /// declared physical size, filed per `persistenceKey` because display IDs
  /// reassign across a replug, and the is-virtual predicate, which no plausibility
  /// range could stand in for, since a virtual display declares an ordinary fake
  /// size.
  struct PhysicalPanelFacts: Equatable {
    let physicalWidthCm: Int?
    let physicalHeightCm: Int?
    let isVirtual: Bool
  }

  struct PixelSize: Equatable {
    let width: Int
    let height: Int
  }

  /// A preview that has been applied and not yet resolved. Every field is a
  /// copy of the session's own answer.
  struct Preview: Equatable {
    let displayID: CGDirectDisplayID
    let mode: DisplayMode
    /// The one answerable surface (SO6), fixed at preview start.
    let surface: PreviewSurface
    var secondsRemaining: Int
    /// Set when `confirm()`, `revert()` or the expiry threw. The display did not
    /// move, the session still holds the fallback, and both buttons stay live.
    /// Nothing auto-retries, so a silent failure would leave the user on a mode
    /// they never approved.
    var failure: DisplayConfigError?
    /// Reported by the session, not inferred: a failed expiry disarms the
    /// countdown while a failed commit deliberately leaves it armed.
    var isCountingDown: Bool
    /// Non-nil when this preview is a SYNTHESIZED size (SS4): the engine has a
    /// virtual display up and the panel mirrored onto it, and the answer goes
    /// to `SynthesisPreviewSession` rather than `ModePreviewSession`.
    ///
    /// `mode` above is then the synthesized row, so every surface that draws a
    /// size, a countdown and two buttons keeps working unchanged. Carrying the
    /// whole `PreviewedSynthesis` makes an answer resolve only the preview it was
    /// given for: a re-engage at the same size is a different virtual display in a
    /// different slot.
    var synthesized: PreviewedSynthesis?
    /// A synthesis confirm, revert or expiry that failed. Its own field rather
    /// than a case of `failure`, because `DisplayConfigError` is a CGError and
    /// no synthesis failure is one: `.unwindIncomplete` reported as
    /// "CoreGraphics error 0" would name a source it never came from.
    var synthesisFailure: SynthesisFailure?
  }

  /// What to do with a synthesis failure already on screen when the coordinator
  /// re-reads its sessions. `FailureUpdate`'s three cases over the other error
  /// type; not that enum, for `Preview.synthesisFailure`'s reason.
  enum SynthesisFailureUpdate {
    case clear
    case keep
    case set(SynthesisFailure)
  }

  /// A reapply that could not honour the stored mode exactly.
  ///
  /// Reapply is unattended, so this is the ONLY way the user finds out. Kept per
  /// display, it survives until they dismiss it or pick a mode themselves: it has
  /// to still be there the next time they look. Unplugging the display does not
  /// take it away (SO8), since the display coming back is when someone is in front
  /// of it again.
  struct ReapplyReport: Equatable {
    /// `DisplayConfigIdentity.key`, the SAME key the stored mode is filed under,
    /// not a `CGDirectDisplayID`. IDs reassign across a replug, so an ID-keyed
    /// report either gets thrown away on departure or surfaces on whichever
    /// display takes the ID next. Carried on the report, not only in the
    /// dictionary, so a surface can dismiss exactly the report it is showing.
    let key: String
    /// What the user actually chose, not what we managed, so the report can name
    /// it: "we could not give you X" explains something that "you are on Y" does
    /// not.
    let requested: DisplayModeDescriptor
    let notice: ModeReapplyNotice
  }

  /// A `begin()` that never took effect. Separate from `Preview.failure`
  /// because nothing is outstanding: there is nothing to keep or revert, only
  /// something to report. Carries the display so one display's failure is not
  /// reported on another display's page.
  struct StartFailure: Equatable {
    let displayID: CGDirectDisplayID
    let reason: Reason

    /// Two ways a selection can take no effect, and they are different
    /// statements: the hardware or CoreGraphics saying no, or this app refusing to
    /// reconfigure a display while it is already reconfiguring displays (AR12).
    /// One state with two reasons, so `dismissStartFailure` stays THE only place
    /// either is cleared.
    enum Reason: Equatable {
      case failed(DisplayConfigError)
      case blocked(by: ReconfigurationClaimant)
    }
  }

  private(set) var catalogs: [CGDirectDisplayID: Catalog] = [:]
  private(set) var preview: Preview?
  private(set) var startFailure: StartFailure?
  /// Keyed by `DisplayConfigIdentity.key`, not by display ID, so a report
  /// survives the replug that reassigns the ID and does not land on whatever
  /// display inherits that ID (SO8). Read through `report(for:)`.
  ///
  /// It inherits that key's KNOWN LIMITATION rather than escaping it. Two
  /// identical panels reporting serial 0 produce the SAME key, so with twins
  /// attached one report overwrites the other and the survivor renders on both
  /// panes. The stored mode already collides the same way, so fixing this means
  /// fixing the identity.
  private(set) var reapplyReports: [String: ReapplyReport] = [:]
  /// True from the click until the reconfiguration it started has settled.
  /// `begin()` spans a real CoreGraphics mode change, and a Keep pressed inside
  /// that window queues behind it and would commit the NEW mode while the banner
  /// still named the old one: correct ordering, wrong intent. Set synchronously so
  /// the disable lands in the same body evaluation as the click.
  private(set) var isApplying = false
  /// Displays whose user has applied a size in THIS session (PD8): a person who
  /// just chose a size has answered the recommendation for now, and the durable
  /// opt-out is the dismissal pref.
  ///
  /// In memory and never persisted, for that same split: the dismissal is the
  /// answer that outlives a launch, and a second stored hide-forever key would be
  /// a second way to lose the suggestion for good. Written only by a KEPT preview,
  /// so a reverted or expired try leaves the suggestion standing.
  private(set) var sizeAppliedByUser: Set<CGDirectDisplayID> = []
  /// Whether the select now in flight changes the display's logical SIZE,
  /// sampled before `begin()` moves it. PD8 is about applying a size: a refresh
  /// rate picked at the size already on screen answers nothing about how big
  /// things look, so it must not hide the callout.
  @ObservationIgnored private var selectChangesSize: [CGDirectDisplayID: Bool] = [:]

  let configurator: any DisplayConfiguring
  let persistence: ModePersistence

  /// CR10. False means the mode list is exactly what CoreGraphics publishes,
  /// reported in diagnostics rather than left indistinguishable from a panel that
  /// has no hidden modes.
  var revealsHiddenModes: Bool { configurator.revealsHiddenModes }

  /// Zero withheld modes means something different depending on this, so the two
  /// are always reported together.
  var guardsWireTiming: Bool { configurator.guardsWireTiming }

  /// AR12. Held from just before `begin()` until nothing is outstanding, so no
  /// other display-reconfiguring feature can move a display out from under a
  /// preview whose fallback was captured before it.
  ///
  /// Not defaulted: a per-coordinator default would compile, run, and exclude
  /// nobody, and four private gates are four features that all think they are
  /// alone.
  @ObservationIgnored private let gate: DisplayReconfigurationGate

  /// Where a `.panel`-origin preview is answered. Wired at launch; nil means
  /// the app never installed one, which degrades to "no confirmation surface
  /// for panel selections" rather than to a crash.
  @ObservationIgnored weak var confirmation: (any ModeConfirmationPresenting)?

  /// Called after something actually wrote `storedDisplayMode` (a pin or a kept
  /// preview), so the propagation seam hears about it (D27) no matter which
  /// surface asked. Owned here because two views answering the same question is
  /// one too many: the second one written is the one that forgets.
  @ObservationIgnored var didStoreMode: (CGDirectDisplayID) -> Void = { _ in }

  /// Called when a stored-mode reapply could not be honoured, so the diagnostics
  /// report's event ring carries it. This happens unattended, at reconnect, with
  /// no view on screen, and the notice a surface can render is `report(for:)`,
  /// which holds only the LATEST one per display.
  @ObservationIgnored var didReportReapply: (CGDirectDisplayID, ModeReapplyNotice) -> Void = { _, _ in }

  /// The app's answer to "what is this panel physically". Injected because the
  /// lookup it performs lives one layer up; the coordinator only enumerates modes.
  ///
  /// The default returns nil, which is the pre-density behaviour exactly: no
  /// geometry reaches the Kit, the usability floor falls back to its
  /// fraction-of-native rule, and no catalog carries a verdict.
  @ObservationIgnored var physicalFacts: (ConfiguredDisplay) -> PhysicalPanelFacts? = { _ in nil }

  /// Synthesized sizes (SS4). Injected by `AppModel`, which owns it: a
  /// synthesized stop is a row in THIS catalog and a preview on THIS clock, so
  /// the routing lives here while the engine, the pairing snapshot and the
  /// prefs live there.
  ///
  /// nil degrades to the pre-synthesis behaviour exactly: no synthesized rows
  /// are offered, nothing routes to the engine, and no reapply engages.
  @ObservationIgnored var synthesis: SynthesisCoordinator?

  @ObservationIgnored private let session: ModePreviewSession
  /// Per display, not one value for the coordinator. A settings-select on B whose
  /// `begin()` fails leaves A's preview outstanding and reports the error against
  /// A; with a single `origin` that select would have flipped the coordinator to
  /// `.settings` and torn down A's confirmation window mid-countdown.
  @ObservationIgnored private var origins: [CGDirectDisplayID: PreviewOrigin] = [:]
  /// Keyed like `origins` and for its reason: the answering surface follows the
  /// preview, not the coordinator. Read back in `adopt`, which rebuilds `Preview`
  /// from the session and needs the one field the session does not hold. A missing
  /// entry answers `.floatingPanel`, the safe default, since the floating window
  /// shows on the display that changed.
  @ObservationIgnored private var surfaces: [CGDirectDisplayID: PreviewSurface] = [:]
  @ObservationIgnored private let countdown = PreviewCountdownDriver()
  @ObservationIgnored private let queue = PreviewQueue()
  @ObservationIgnored private var inFlightSelects = 0
  /// Displays anything has asked about. `handleDisplaysChanged` re-enumerates
  /// these rather than only the cached ones, so a display that departs and returns
  /// under the same ID gets its catalog back: a nil catalog renders as nothing at
  /// all, and `.task(id:)` does not re-fire for an unchanged id.
  @ObservationIgnored private var observed: Set<CGDirectDisplayID> = []
  /// The last panel-derived values taken while each display was showing its own
  /// desktop, keyed by `DisplayConfigIdentity.key` so they survive the replug
  /// that reassigns display IDs. See `PanelBaseline`.
  @ObservationIgnored private var baselines: [String: PanelBaseline] = [:]
  /// The panel's own refresh rate at the moment a synthesized size was picked
  /// on it: the FALLBACK for a confirmation label rendered before the engage
  /// settles.
  ///
  /// The catalog's synthesized ROWS carry the `refreshHz: 0` sentinel, because a
  /// stop is a size and the rate it runs at is not the stop's. The engaged rate is
  /// the virtual master's achievable one and can be LOWER than the pre-pick rate
  /// [MEASURED 2026-08-18: 100 on the wire from a 175 start], so the label prefers
  /// the live reading and falls back to this.
  @ObservationIgnored private var synthesisPreviewRefresh: [CGDirectDisplayID: Double] = [:]
  /// The synthesized stop an ordinary pick took down, held for as long as that
  /// pick can still fall through.
  ///
  /// RULING 2026-08-18. Picking an ordinary size over a COMMITTED synthesized set
  /// does a real, irreversible teardown before the reversible preview starts, so
  /// "Revert" would otherwise return the person to the desktop from before the
  /// stop was engaged rather than to the screen they were looking at when they
  /// picked. The revert, the expiry and a failed start all re-engage from this.
  /// Armed only after a teardown that succeeded, dropped the moment the pick
  /// lands.
  @ObservationIgnored private var restoreStopIfPickFalls: [CGDirectDisplayID: SyntheticSize] = [:]
  /// Which displays count as having just arrived: the "launch and reconnect, never
  /// continuously" rule (DM7). It lives in `CandelaKit` under test because both
  /// failure directions are timing and both are invisible from here, too eager
  /// fighting the user forever and too shy restoring nothing on the replug the
  /// feature is named for.
  @ObservationIgnored private var arrivals = DisplayArrivalTracker()
  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  /// Reapply happens with nobody in front of the screen, so every outcome is
  /// also written where it can be read afterwards. The in-app report can be
  /// dismissed and is gone; this is what a bug report can quote.
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "displayModes"
  )

  init(
    gate: DisplayReconfigurationGate,
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
    persistence: ModePersistence = ModePersistence()
  ) {
    self.gate = gate
    self.configurator = configurator
    self.persistence = persistence
    session = ModePreviewSession(configurator: configurator)
    // Observed here rather than in a pane: a display can depart while its pane
    // is being dismissed for that very reason, and an outstanding preview on a
    // departed display has to be dropped whether or not anything is on screen.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // Sampled HERE, synchronously in the notification block, and carried into
      // the handler, never re-read on the other side of the hop.
      //
      // The hop is unavoidable (this block is not main-actor isolated) and its
      // delay is unbounded, since main-actor work is starved during menu tracking.
      // If an unplug and a replug post back-to-back, both handlers would read a
      // list with the display present and conclude it never left, so the
      // remembered resolution would silently not come back. Reading `configurator`
      // rather than `self` is what makes the sample legal: it is `Sendable` and
      // captured directly, so nothing touches the main-actor object off the main
      // actor.
      let live = Set(configurator.displays().map(\.id))
      Task { @MainActor in self?.handleDisplaysChanged(observedLive: live) }
    }
  }

  /// The notification token is deliberately not unregistered: it is not
  /// `Sendable`, so a nonisolated `deinit` cannot touch it. This object lives as
  /// long as the app and the block holds `self` weakly, so the registration is
  /// inert rather than dangling.
  deinit {
    countdown.stop()
    queue.cancel()
  }

  // MARK: - Enumeration

  /// The display's current mode: the cached catalog when one exists, else a live
  /// query. A catalog is populated only when something has SHOWN this display (its
  /// own pane, or the panel's warm pass over externals), so a reader treating
  /// `catalogs` as the answer reports the built-in's mode as "not reported"
  /// exactly when the report is copied from another display's page (D8).
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    catalogs[displayID]?.current ?? configurator.currentMode(for: displayID)
  }

  /// Re-enumerates one display. Called when a pane appears, when the screen
  /// configuration changes, and after any mode this app applies, never on a
  /// timer (DM7).
  func refreshCatalog(for displayID: CGDirectDisplayID) {
    observed.insert(displayID)
    guard let display = configurator.displays().first(where: { $0.id == displayID }) else {
      catalogs[displayID] = nil
      dropPreviewOnDepartedDisplay()
      return
    }
    let all = DisplayModeCatalog.full(configurator.modes(for: displayID))
    // While a synthesized size is engaged, panel-derived values come from the last
    // pass taken with this display on its own desktop: an engaged panel's
    // readbacks describe the virtual master. See `PanelBaseline`.
    let engagedSize = synthesis?.engagedSize(displayID: displayID)
    let baseline = baseline(for: display, modes: all, isEngaged: engagedSize != nil)
    let native = baseline.nativePixels.map { (width: $0.width, height: $0.height) }
    // Sampled once and handed to both the catalog and the verdict: the size the
    // model calls "current" has to be the one this enumeration saw.
    let current = configurator.currentMode(for: displayID)
    // Density is a claim about physical pixels, so no native size means no
    // geometry at all rather than geometry over zeros.
    let geometry = native.flatMap { native in
      physicalFacts(display).map { facts in
        PanelGeometry(
          nativePixelWidth: native.width, nativePixelHeight: native.height,
          physicalWidthCm: facts.physicalWidthCm,
          physicalHeightCm: facts.physicalHeightCm,
          isVirtual: facts.isVirtual
        )
      }
    }
    // One value, two readers (PD1). Curating twice would let the rows the user
    // can pick and the rows the model ranks drift apart.
    let published = DisplayModeCatalog.curated(
      all,
      nativePixelWidth: native?.width ?? 0,
      nativePixelHeight: native?.height ?? 0,
      geometry: geometry
    )
    // Offered only where SS4's opt-in is on, and never on the built-in (SS14). The
    // ladder is cached on the baseline, so the rows a person sees do not change
    // under them while a size is engaged.
    let stops = synthesis?.offersSyntheticSizes(displayID: displayID) == true && !display.isBuiltIn
      ? baseline.stops
      : []
    log.debug(
      "catalog refresh display=\(displayID) engaged=\(engagedSize.map { "\($0.logicalWidth)x\($0.logicalHeight)" } ?? "none", privacy: .public) stops=\(stops.count) published=\(published.count)"
    )
    catalogs[displayID] = Catalog(
      display: display,
      rows: SyntheticSizeCatalog.merged(
        published: published, stops: stops, nativePixels: native
      ),
      all: all,
      current: current,
      distinctLogicalSizes: Set(all.map { LogicalSize(mode: $0) }).count,
      nativePixels: baseline.nativePixels,
      withheldForWireTiming: configurator.modesWithheldByWireTimingGuard(for: displayID),
      density: geometry.map {
        PanelDensityModel.evaluate(
          // PUBLISHED rows only: the model ranks whatever it is handed, so the
          // merged list would recommend a size that costs a virtual display.
          rows: published,
          // The engaged size, not the readback, for `Catalog.onScreen`'s reason:
          // while a stop is engaged the readback names the panel's own native
          // geometry, which is not what is on the glass.
          currentLogicalWidth: engagedSize?.logicalWidth ?? current?.logicalWidth,
          currentLogicalHeight: engagedSize?.logicalHeight ?? current?.logicalHeight,
          geometry: $0
        )
      },
      syntheticStops: stops,
      engagedSyntheticSize: engagedSize
    )
  }

  /// The panel-derived values for this pass: freshly measured while the display
  /// shows its own desktop, and the last such measurement while a synthesized
  /// size is engaged.
  private func baseline(
    for display: ConfiguredDisplay, modes: [DisplayMode], isEngaged: Bool
  ) -> PanelBaseline {
    let key = display.identity.key
    if isEngaged, let cached = baselines[key] { return cached }
    let nativePixels = configurator.nativePixels(for: display.id)
      .map { PixelSize(width: $0.width, height: $0.height) }
    // The native-flagged mode from the SAME list this catalog is built from,
    // which is how `nativePixels(for:)` finds it too.
    let native = modes.first(where: \.isNative)
    let stops: [SyntheticSize] = if let native, !display.isBuiltIn {
      SyntheticSizeCatalog.stops(
        nativeLogicalWidth: native.logicalWidth, nativeLogicalHeight: native.logicalHeight,
        existingRows: modes,
        ceilingPixelWidth: VirtualDisplayIdentity.maxPixels.wide,
        ceilingPixelHeight: VirtualDisplayIdentity.maxPixels.high
      )
    } else {
      []
    }
    let baseline = PanelBaseline(
      nativePixels: nativePixels,
      nativeLogicalWidth: native?.logicalWidth,
      nativeLogicalHeight: native?.logicalHeight,
      stops: stops
    )
    // A pass that could not read the panel's own geometry is not evidence about
    // it, so it does not replace a baseline that could. Neither is a pass that ran
    // while the display sat in a mirror set or an engage was in flight: the engage
    // window reads as not-engaged (the pairing snapshot is empty throughout) while
    // the OS list already carries the mirror-published twins, and one such pass
    // overwrote the cached ladder with the suppressed one, hiding the engaged stop
    // from every surface.
    //
    // **The cache is written ONLY from a stable pass, first sight included.** A
    // non-nil entry is never replaced while the set stands, so admitting one
    // poisoned baseline locks it in: a display first seen inside a mirror window
    // kept a ladder derived from the master until the set came down. An unstable
    // pass RETURNS what it computed without storing it.
    let unstable = synthesis?.baselineUnstable(displayID: display.id) ?? false
    guard native != nil, !unstable else { return baselines[key] ?? baseline }
    baselines[key] = baseline
    return baseline
  }

  /// Screen configuration changed: re-enumerate what is still here, forget what is
  /// not, and end a preview on a display that has departed. Left alone, the expiry
  /// would apply the fallback to a dead display, fail, and leave the session
  /// holding an outstanding preview forever; `begin()` on ANY other display then
  /// reverts-first, fails, and refuses, so one unplug wedges mode switching for
  /// the session.
  /// - Parameter observedLive: the display set as it was WHEN THE NOTIFICATION WAS
  ///   POSTED, not as it is now. A departure has to count as a departure even when
  ///   the display is back by the time this runs. Everything else below reads the
  ///   CURRENT list, because a catalog or a report must describe what is plugged in
  ///   now.
  func handleDisplaysChanged(observedLive: Set<CGDirectDisplayID>) {
    let live = Set(configurator.displays().map(\.id))
    // Over `observed`, not `catalogs`: a departed display's entry is nil, so
    // iterating the cache would never re-enumerate it when it comes back.
    for displayID in observed {
      if live.contains(displayID) {
        refreshCatalog(for: displayID)
      } else {
        catalogs[displayID] = nil
        // Both are keyed by display ID, which the next arrival can inherit, so a
        // departure has to take them: a suggestion silently suppressed on a panel
        // nobody chose a size for has no visible symptom.
        sizeAppliedByUser.remove(displayID)
        selectChangesSize[displayID] = nil
        synthesisPreviewRefresh[displayID] = nil
        // Same rule, same keying. Nothing reads either without having written it
        // first in the same operation, so this changes no answer today; it keeps
        // the next read-before-write from inheriting a departed panel's origin.
        origins[displayID] = nil
        surfaces[displayID] = nil
        // Nothing to restore onto a display that is not attached, and the next
        // arrival can inherit this id.
        restoreStopIfPickFalls[displayID] = nil
      }
    }
    // A departure is what makes the next arrival an arrival, so it is recorded
    // HERE, from the undebounced screen-parameters notification and the set it was
    // posted with. The app's own topology signal cannot be the only source for two
    // reasons: it coalesces a burst into one element, so an unplug and replug
    // inside its one-second quiet window arrive as a single event with the display
    // present at both ends, and this handler can itself run late, which is why it
    // is told what was live rather than asked to look.
    arrivals.noteObserved(live: observedLive)
    // Reports are deliberately NOT pruned here (SO8). Identity keying already
    // stops a report reappearing on whatever display took the ID next, and what is
    // left is the case the report exists for: a reapply nobody watched, on a
    // display the user unplugged before looking. Dropping it on departure would
    // take the account away exactly when they are back in front of that display.
    // Only a dismissal, or a later pass with a newer outcome for the same
    // identity, clears one.
    //
    // A start failure is different and still cleared below: it is about a control
    // on a page that has just disappeared, and its surface is a floating window
    // AppKit would relocate onto another screen. The preview path self-heals here
    // and this one cannot, since a failure has no countdown re-presenting it and
    // `dropPreviewOnDepartedDisplay` returns early when nothing is outstanding.
    if let failure = startFailure, !live.contains(failure.displayID) {
      dismissStartFailure()
    }
    dropPreviewOnDepartedDisplay()
    dropSynthesisOnDepartedDisplay(live: live)
  }

  /// A synthesis set whose physical panel has gone is taken DOWN, not forgotten.
  /// The virtual display outlives the panel's departure and holds one of only two
  /// synthesis slots, so dropping the record instead would strand a display
  /// nothing can reach and lose the slot until the app restarts.
  ///
  /// Reads the CURRENT list rather than the notification's, unlike the departure
  /// bookkeeping above: this is about hardware to take down, so the question is
  /// what is attached now. A display that left and came back has nothing to
  /// unwind.
  private func dropSynthesisOnDepartedDisplay(live: Set<CGDirectDisplayID>) {
    guard let synthesis, !synthesis.pairings.isEmpty || synthesis.refusal != nil else { return }
    queue.enqueue {
      await synthesis.noteDepartures(live: live)
      await self.adopt(.keep, synthesis: .keep)
    }
  }

  // MARK: - Reapply

  /// Reapplies stored modes for displays that have ARRIVED since the last pass.
  ///
  /// Called from launch and from the app's debounced
  /// `CGDisplayReconfigurationCallBack` intake, and nowhere else: never on a pref
  /// write, never on a timer (DM7).
  ///
  /// The arrival gate is the substance of DM7. A reconfiguration event is ALSO
  /// what the user changing resolution in System Settings produces, so a pass that
  /// reapplied on every event would undo that change within a second, with no way
  /// out short of turning the feature off. From arrival until departure, the
  /// display belongs to the user.
  ///
  /// Deliberately NOT a preview: nobody is watching, and a countdown that defaults
  /// to revert would undo every remembered mode a moment after every reconnect. It
  /// commits at session scope directly, which is also why it never calls
  /// `ModePreviewSession.begin()`: `begin()` on one display ends an outstanding
  /// preview on ANOTHER, so an unattended caller could reconfigure a display
  /// nobody named.
  ///
  /// Mirror SLAVES are excluded here and only here. The picker still offers them
  /// every mode, because a pick is a person asking for this display by name and
  /// getting thirty seconds and an auto-revert, while this pass asks nobody.
  /// Hiding the control would make it vanish and reappear under the user's hands,
  /// since mirroring is a hotkey in this very app.
  ///
  /// It writes NO preferences, so a substitute is never stored over the user's
  /// choice: a monitor that came back on a reduced link once does not permanently
  /// rewrite their resolution.
  ///
  /// **Awaitable, and its one caller awaits it.** `UnattendedRestoreSequence` runs
  /// this and the arrangement restore as one operation, in this order, because
  /// both claim the same gate and a refused pass cannot rely on the winner
  /// producing a reconfiguration event.
  func reapplyStoredModes() async {
    let live = configurator.displays()
    // Claiming marks, in one step: the work below is queued, so a second call
    // landing before it finishes must not act on the same arrival twice. A claim
    // not acted on is given back (`release`), never silently kept.
    let claimed = arrivals.claimArrivals(live: Set(live.map(\.id)))
    let displays = live.filter { claimed.contains($0.id) }
    guard !displays.isEmpty else { return }
    // Through the same queue as every session operation. Reapply does not touch
    // the session, but it applies modes at SESSION scope, and landing that inside
    // a `begin()` or `confirm()` would move a display out from under a preview
    // whose fallback was captured before it.
    await queue.enqueueReturning { await self.performReapply(displays) }
  }

  // MARK: - Reports

  /// The report for a display that is plugged in RIGHT NOW.
  ///
  /// The dictionary is keyed by identity, so this resolves the ID it is given
  /// through the live display list. The emptiness test first is not a
  /// micro-optimisation: without it every sidebar row pays a CoreGraphics
  /// enumeration per body evaluation to be told "no".
  func report(for displayID: CGDirectDisplayID) -> ReapplyReport? {
    guard !reapplyReports.isEmpty, let key = identity(for: displayID)?.key else { return nil }
    return reapplyReports[key]
  }

  func hasUnreadReport(for displayID: CGDirectDisplayID) -> Bool {
    report(for: displayID) != nil
  }

  /// THE one place a person clears a report, whichever surface they clicked OK in.
  /// Keyed rather than taking a display: a surface rendering a report can then
  /// only dismiss the one it was showing, while an ID would have to be re-resolved
  /// and could resolve to nothing, or after a replug to something else.
  func dismissReport(forKey key: String) {
    reapplyReports[key] = nil
  }

  private func performReapply(_ displays: [ConfiguredDisplay]) async {
    // Unattended, and still a reconfiguration, so AR12 applies exactly as it does
    // to a pick: a stored mode re-asserted mid-arrangement-preview changes the very
    // tile sizes that layout was computed from. Refused, every arrival claim goes
    // back, since keeping it would mean "never".
    //
    // Whether anything calls this again is NOT a property of the gate. It holds
    // only for a claimant holding the gate around an outstanding reconfiguration
    // or preview, whose resolution is itself a reconfiguration. It does NOT hold
    // for a claimant that applies nothing, which is the arrangement restore's
    // dominant case and was this pass's too, so the two starved each other.
    // `UnattendedRestoreSequence` is why they no longer race: the layout restore
    // does not run until this pass has finished and released.
    if await gate.claim(.displayModes).refusedBy != nil {
      for display in displays { arrivals.release(display.id) }
      return
    }
    // Asked of the session rather than of `preview`, for
    // `dropPreviewOnDepartedDisplay`'s reason: the derived copy is nil for several
    // awaits after `begin()` succeeds, and reapplying over a live preview would
    // strand it, so the countdown would "revert" to a mode the display had left.
    let previewed = await session.previewedMode?.displayID
    if let previewed, displays.contains(where: { $0.id == previewed }) {
      // An explicit choice the user is looking at RIGHT NOW outranks one they
      // made some other day, but the claim goes back, so this is "not now" rather
      // than "never": without the release, a display that was mid-preview when it
      // arrived would go unreapplied for the rest of the connection. The retry
      // needs no scheduler, since resolving the preview is itself a
      // reconfiguration and the event it produces calls this again.
      arrivals.release(previewed)
    }
    for display in displays where display.id != previewed {
      // Synthesis reapply runs AFTER the stored-mode decision for the same
      // display, never beside it: engaging makes the panel a mirror slave, and a
      // stored mode applied to a slave is the case `ModeReapplyPolicy` defers for.
      // That deferral is also why a display already carrying a synthesis set never
      // fights its own remembered resolution.
      guard reapplyStoredMode(for: display) == .done else { continue }
      await reapplySynthesis(for: display)
    }
    // Reapply opens no preview, so its claim is spent when the loop ends, but it
    // can run while a preview stands on ANOTHER display and releasing then would
    // free the claim protecting that preview. The session is the authority on
    // whether anything is outstanding; `preview` is not, being nil for several
    // awaits after a `begin()` succeeds.
    if await session.previewedMode == nil, await synthesis?.session.previewedSynthesis == nil {
      await gate.release(.displayModes)
    }
  }

  /// How far the stored-mode half of one display's reapply got. The synthesis
  /// half runs only after `.done`: the other two mean the display is not in a
  /// state to be reconfigured at all, and each has already given its arrival
  /// claim back.
  private enum ModeReapplyStep {
    case done
    case deferred
    case gone
  }

  private func reapplyStoredMode(for display: ConfiguredDisplay) -> ModeReapplyStep {
    let identity = display.identity
    let stored = persistence.storedMode(for: identity)
    // Enumerated for every arrival, including displays that never opted in: the
    // opt-in gate lives inside the tested policy, so asking costs one
    // `CGDisplayCopyAllDisplayModes` per arrival, the same call `warmModeCatalogs`
    // makes on every menu close.
    let decision = ModeReapplyPolicy.decide(
      isEnabled: persistence.isEnabled(for: identity),
      // From the entry the list handed us, not asked again now: the mirror state
      // has to describe the same instant as the enumeration that claimed this
      // arrival.
      isMirroringAnotherDisplay: display.isMirrorSlave,
      stored: stored,
      available: configurator.modes(for: display.id),
      current: configurator.currentMode(for: display.id)
    )
    // "Not now": a mirror slave, or a display that cannot say what mode it is
    // running. The claim goes back, since only an observed ABSENCE re-arms one and
    // keeping it would mean "never". Mirroring ends and a display wakes through
    // reconfiguration events, and those events call this again.
    if decision.isDeferred {
      arrivals.release(display.id)
      return .deferred
    }
    guard let requested = stored,
          decision.modeToApply != nil || decision.notice != nil
    else { return .done }

    var notice = decision.notice
    if let mode = decision.modeToApply {
      do {
        try configurator.apply(mode, to: display.id, scope: .session)
        log.log("reapplied stored mode on display \(display.id): \(mode.logicalWidth)x\(mode.logicalHeight) @\(mode.refreshHz)Hz")
      } catch {
        // `apply` throws when staging or completion fails AND when the resolved
        // `CGDisplayMode`'s descriptor does not match the one asked for, a
        // reassigned `ioModeID` now denoting a different mode. On the unattended
        // path that second case must not be swallowed: `try?` would leave the
        // display on some third mode with the app reporting a successful restore.
        let configError = error as? DisplayConfigError
          ?? DisplayConfigError(cgErrorCode: -1)
        notice = .failed(configError)
      }
      refreshCatalog(for: display.id)
    }

    guard let notice else {
      // Replacement, not a clear-on-departure: this pass has a newer answer for
      // the same identity, and the answer is "nothing to say".
      reapplyReports[identity.key] = nil
      return .done
    }
    // A display can leave across the queue wait or the apply itself. Not because
    // a report about an absent display is unshowable (SO8 keeps those), but
    // because this one describes an attempt that never finished. The claim goes
    // back with it, so the display's return is an arrival again and that pass
    // writes a fresh outcome in place of this half-answer.
    guard configurator.displays().contains(where: { $0.id == display.id }) else {
      arrivals.release(display.id)
      return .gone
    }
    reapplyReports[identity.key] = ReapplyReport(
      key: identity.key, requested: requested, notice: notice
    )
    didReportReapply(display.id, notice)
    log.error("could not restore stored mode on display \(display.id): \(String(describing: notice), privacy: .public)")
    return .done
  }

  /// The unattended synthesis half (SS9/SS14, through `SynthesisReapplyPolicy`).
  ///
  /// Everything the policy needs about the panel comes from THIS pass's baseline,
  /// and the stored descriptor is resolved through
  /// `SyntheticSizeCatalog.size(matching:)` first: the policy cannot tell a
  /// genuinely stale descriptor from a caller that skipped the lookup.
  private func reapplySynthesis(for display: ConfiguredDisplay) async {
    guard let synthesis, !display.isBuiltIn else { return }
    // Through `DisplayModeCatalog.full`, exactly as `refreshCatalog` feeds
    // `baseline()`: in the RAW list the native flag rides the HiDPI twin, the
    // ladder computes from that, and every stop lands under the minor-axis floor.
    // The stored stop then resolves nil and the relaunch restore reports
    // staleDescriptor forever.
    let modes = DisplayModeCatalog.full(configurator.modes(for: display.id))
    let baseline = baseline(
      for: display, modes: modes, isEngaged: synthesis.isEngaged(displayID: display.id)
    )
    let decision = await synthesis.reapply(
      for: display,
      nativeLogicalWidth: baseline.nativeLogicalWidth,
      nativeLogicalHeight: baseline.nativeLogicalHeight,
      existingRows: modes
    )
    // Only an engage changes what is on the glass, and it changes it enough
    // that every derived value here is stale.
    if case .engage = decision { refreshCatalog(for: display.id) }
  }

  func isRemembering(_ displayID: CGDirectDisplayID) -> Bool {
    guard let identity = identity(for: displayID) else { return false }
    return persistence.isEnabled(for: identity)
  }

  /// Turning it ON also pins what is on screen now. Without that the toggle stores
  /// nothing until the next kept change, so it reads as broken on the very
  /// reconnect it was turned on for. Turning it OFF leaves the stored mode alone:
  /// "forget my choice" and "stop remembering" are separate answers, and the pin
  /// survives the toggle coming back on.
  ///
  /// The seeding is queued and can decline (a preview outstanding on this
  /// display), so turning it on mid-countdown enables the flag and pins nothing.
  /// That is the intended order: there is no mode the user has accepted yet, and
  /// keeping that preview stores it because the flag is on by then.
  func setRemembering(_ remembering: Bool, for displayID: CGDirectDisplayID) {
    guard let identity = identity(for: displayID) else { return }
    persistence.setEnabled(remembering, for: identity)
    guard remembering else { return }
    pinCurrentMode(on: displayID)
  }

  /// Pins whatever is on screen now, reached from the Remember toggle's
  /// turn-on seeding and from the hub's `Set to Current`.
  ///
  /// Not the only route to `store`: a kept preview writes the stored mode too
  /// while the toggle is on, which leaves `Set to Current` as the re-pin for a mode
  /// already on screen.
  ///
  /// Queued, and it asks the SESSION whether that display is mid-preview, for
  /// `dropPreviewOnDepartedDisplay`'s reason: `preview` is nil for several awaits
  /// after a `begin()` succeeds, so the main-actor copy would answer "nothing
  /// outstanding" during exactly the window a pin must not be taken in. A mode
  /// still under a countdown is one the user has not accepted.
  ///
  /// Silently skipped rather than reported: the UI disables its pin control while
  /// a preview stands, so only a click racing the countdown reaches the guard, and
  /// a notice for a pin they can take again a second later is noise. Also silent
  /// when the display cannot report the mode it is running, since leaving an
  /// existing pin alone beats replacing it with a guess.
  func pinCurrentMode(on displayID: CGDirectDisplayID) {
    queue.enqueue {
      guard await self.session.previewedMode?.displayID != displayID else { return }
      // A synthesis-engaged panel's readback is not the size on the glass: the
      // engage tail re-times the slave, so it names the HiDPI twin of the panel's
      // own mode [MEASURED 2026-08-18]. Pinning it would store a real, resolvable
      // mode that is not what the person is looking at and reapply it at every
      // reconnect. The synthesized choice has its own store.
      guard self.synthesis?.isEngaged(displayID: displayID) != true else { return }
      // Live read FIRST, cache only as the fallback: a countdown expiry reverts on
      // the session actor and enqueues nothing but `adopt(.keep)`, which never
      // refreshes the catalog, so in that window the cache still names the mode
      // the display has already reverted away from.
      guard let identity = self.identity(for: displayID),
            let current = self.configurator.currentMode(for: displayID)
              ?? self.catalogs[displayID]?.current
      else { return }
      self.store(current, on: displayID, for: identity)
    }
  }

  /// Removes this display's stored resolution, leaving the opt-in flag alone.
  ///
  /// The two are separate answers: "forget the resolution I pinned" is not "stop
  /// remembering resolutions here", and the toggle above the button answers the
  /// second. With the toggle still on, the next resolution the user keeps is
  /// pinned in the cleared one's place.
  ///
  /// Queued for `pinCurrentMode`'s reason: the queue serialises every other write
  /// to `storedDisplayMode`, and a clear that skipped it could be overtaken by an
  /// in-flight pin and silently undone. Announced through `didStoreMode` because
  /// the propagation seam has to hear about a removal on the same terms as a write
  /// (D27).
  ///
  /// A stored SYNTHESIZED size is deliberately untouched: it is a different store
  /// with its own control, and a button in the resolution section is not where
  /// someone looks to retire it.
  func forgetStoredMode(on displayID: CGDirectDisplayID) {
    queue.enqueue {
      guard let identity = self.identity(for: displayID) else { return }
      self.persistence.clear(for: identity)
      // The report is about a mode that no longer exists to be reapplied, so it
      // goes with it. Otherwise the banner that sent the user here outlives its
      // own subject and keeps apologising for a resolution nothing holds.
      self.dismissReport(forKey: identity.key)
      self.didStoreMode(displayID)
    }
  }

  /// The pin as stored, for the row that shows it and for `Set to Current`'s
  /// enabled state. Read-only: writes go through `store`, BECAUSE it announces
  /// itself (`didStoreMode`).
  func storedDescriptor(for displayID: CGDirectDisplayID) -> DisplayModeDescriptor? {
    guard let identity = identity(for: displayID) else { return nil }
    return persistence.storedMode(for: identity)
  }

  // MARK: - Preview

  /// Applies `mode` as a preview and starts the countdown.
  ///
  /// Only ever from an explicit choice naming THIS display: `begin()` on a display
  /// other than the one holding an outstanding preview performs a session-scope
  /// apply on that other display, so a speculative call would reconfigure a display
  /// the user never touched.
  ///
  /// Synchronous and fire-and-forget: the queue owns the ordering, so no caller can
  /// create a second in-flight `begin()` by spawning its own task.
  ///
  /// `origin` and `surface` are not defaulted: every caller has to say where a
  /// failure is reported and where the answer is offered, because getting either
  /// wrong is invisible until a countdown expires against nobody. Settings callers
  /// decide `surface` from their own window's key state at the click (SO6), the
  /// guided setup flow passes `.guidedSetup` (DM11), everything else
  /// `.floatingPanel`.
  func select(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface
  ) {
    // Raised HERE, synchronously, not inside the queued operation: the banner's
    // buttons have to be disabled by the time the reconfiguration starts, so
    // nobody can confirm a mode they are not reading. Counted rather than boolean,
    // so two queued selects do not have the first completion clear the flag.
    inFlightSelects += 1
    isApplying = true
    queue.enqueue {
      // Routed on PROVENANCE (SS5): a synthesized row's sentinel mode ID denotes
      // nothing in either mode-ID space, so no configuration transaction could
      // apply it. The configurator's refusal is a tripwire for a bypass rather
      // than a path anything is meant to take.
      if mode.isSynthesized {
        await self.performSynthesisSelect(mode, on: displayID, from: origin, surface: surface)
      } else {
        await self.performSelect(mode, on: displayID, from: origin, surface: surface)
      }
      self.inFlightSelects -= 1
      if self.inFlightSelects == 0 { self.isApplying = false }
    }
  }

  /// `select`, plus the no-op guard every mode LIST needs: applying the mode
  /// already on screen reconfigures nothing and then demands "Keep this
  /// resolution?" with a full countdown for a change nobody made.
  ///
  /// Here rather than at each call site because the settings window offers modes
  /// from two surfaces, the hub's size pop-up and the full list, and a guard held
  /// in agreement by discipline is what this branch has been bitten by. The
  /// menu-bar list keeps its own copy deliberately: it also has to decide whether
  /// to end the menu's tracking session.
  func selectFromList(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface, currentModeID: Int32?
  ) {
    guard mode.ioModeID != currentModeID else { return }
    select(mode, on: displayID, from: origin, surface: surface)
  }

  /// `answered` is the preview the caller was LOOKING AT when it answered. It
  /// is carried into the session, which refuses an answer that no longer names
  /// the outstanding preview.
  ///
  /// The button's action runs one main-actor turn before the queued operation, so
  /// a selection can land in between and ordering alone cannot stop the answer from
  /// resolving a preview the user never saw. Carrying the intent makes "an answer
  /// only resolves the preview it was given for" a property of the type.
  @discardableResult
  func confirm(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.performResolve(answered, keeping: true, intent: .answered) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.performResolve(answered, keeping: false, intent: .answered) }
  }

  /// Ends any outstanding MODE preview and reports whether the display is back
  /// where it started.
  ///
  /// Called by `MirroringCoordinator` before a mirror ENGAGE preview begins and
  /// before a mirror BREAK applies. It runs inside THIS coordinator's queue, so
  /// neither path can open a `CGBeginDisplayConfiguration` transaction while a
  /// mode transaction is still open. Two `@MainActor @Observable` coordinators
  /// cannot share one task chain without being merged, so the ordering is enforced
  /// by the mirror chain AWAITING this.
  ///
  /// **That orders the mirror side and nothing else.** `select` does not call the
  /// mirror side's equivalent, and the mirror countdown's expiry runs detached on
  /// the session's executor, so concurrent transactions stay possible in those two
  /// directions.
  ///
  /// A mirror engage would otherwise move a display out from under a preview whose
  /// fallback mode was captured before it, leaving the mode preview's recovery
  /// surface on a display with no `NSScreen`. A break comes through for the
  /// transaction ordering alone and refuses on the same terms.
  ///
  /// Returns false when the revert FAILED, which is the mirror side's cue to
  /// refuse.
  func endOutstandingPreview() async -> Bool {
    await queue.enqueueReturning {
      // BOTH previews, awaited rather than short-circuited: a caller asking every
      // size preview to stand down must not leave one standing because the other
      // refused. A synthesized size is a size.
      let mode = await self.endOutstandingModePreview()
      let synthesized = await self.endOutstandingSynthesisPreview()
      return mode && synthesized
    }
  }

  /// Inside the queue already. Split out of `endOutstandingPreview` because the
  /// select paths call it from a queued operation, where re-entering the queue
  /// would wait on the operation doing the waiting.
  private func endOutstandingModePreview() async -> Bool {
    guard let outstanding = await session.previewedMode else { return true }
    // Built FROM the session, so the intent check inside `performResolve` cannot
    // see it as stale. `secondsRemaining: 0` and `isCountingDown: false` describe
    // an answer nobody waited for.
    let answered = Preview(
      displayID: outstanding.displayID,
      mode: outstanding.mode,
      surface: surfaces[outstanding.displayID] ?? .floatingPanel,
      secondsRemaining: 0,
      failure: nil,
      isCountingDown: false,
      synthesized: nil,
      synthesisFailure: nil
    )
    // `.standDown`, the reason the parameter exists: every caller of this is about
    // to reconfigure displays itself.
    return await performResolve(answered, keeping: false, intent: .standDown) == .reverted
  }

  /// The same for a synthesized size: disengage, and report whether the panel
  /// is back on its own desktop.
  private func endOutstandingSynthesisPreview() async -> Bool {
    guard let synthesis, let outstanding = await synthesis.session.previewedSynthesis
    else { return true }
    let answered = Preview(
      displayID: outstanding.physicalDisplayID,
      mode: synthesizedPreviewRow(outstanding.size, on: outstanding.physicalDisplayID),
      surface: surfaces[outstanding.physicalDisplayID] ?? .floatingPanel,
      secondsRemaining: 0,
      failure: nil,
      isCountingDown: false,
      synthesized: outstanding,
      synthesisFailure: nil
    )
    return await performResolve(answered, keeping: false, intent: .standDown) == .reverted
  }

  /// Reconciles both preview sessions and gives the AR12 claim back if nothing
  /// is outstanding.
  ///
  /// **THE release funnel for `.displayModes`, and the reason it is exposed.**
  /// `adopt` is the only releaser, which keeps a claim from outliving what it
  /// protects and keeps a claim protecting a preview from being freed by unrelated
  /// work. A claimant that takes the gate outside a preview gives it back HERE
  /// rather than calling `release` itself: a select granted during their
  /// multi-second disengage would otherwise have its claim freed underneath it.
  ///
  /// Enters the queue, so it must not be called from inside one of its
  /// operations.
  func releaseReconfigurationClaimIfIdle() async {
    await queue.enqueueReturning { await self.adopt(.keep, synthesis: .keep) }
  }

  /// THE only place `startFailure` is cleared, for the reason `store` is the only
  /// place a mode is written: the standalone window RENDERS this, so clearing it
  /// and syncing the window are one operation rather than two a caller has to
  /// pair.
  func dismissStartFailure() {
    startFailure = nil
    syncConfirmation()
  }

  // MARK: - Operations (always inside the queue)

  private func performSelect(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface
  ) async {
    // Recorded here rather than in `select` so they name the preview about to
    // become outstanding, not whichever click was most recent: two queued selects
    // from different surfaces each get their own surface as they land. `surface`
    // was still DECIDED at the click; this is only where it is filed.
    origins[displayID] = origin
    surfaces[displayID] = surface
    // A new pick supersedes any standing intent to put a torn-down stop back.
    // CONSUMED rather than dropped, so the stored stop goes with it: the previous
    // pick's preview resolves inside `ModePreviewSession.begin`'s revert-first,
    // which reaches no arm here, so a bare drop left the pref naming a stop that
    // will not be on the glass under either outcome.
    dropFallenPickRestore(on: displayID, explain: false)
    // Sampled before `begin()` moves the display, and promoted to
    // `sizeAppliedByUser` only if this preview is KEPT. Every path here is an
    // explicit choice from an offering surface; reapply and restore never preview.
    // An unreadable current mode counts as a size change, since it is the user's
    // choice either way.
    selectChangesSize[displayID] = configurator.currentMode(for: displayID).map {
      $0.logicalWidth != mode.logicalWidth || $0.logicalHeight != mode.logicalHeight
    } ?? true
    // Through `dismissStartFailure`, never a bare `startFailure = nil`: the
    // standalone window renders the failure, so clearing it without syncing leaves
    // an EMPTY floating panel for the whole CoreGraphics mode change below.
    // Reachable by the obvious retry: fail, reopen the panel, pick again.
    dismissStartFailure()
    // The user has answered the report themselves: whatever reapply could not do,
    // they are doing by hand, and leaving the notice up would contradict the choice
    // they just made. Through the one dismissal path.
    if let key = identity(for: displayID)?.key { dismissReport(forKey: key) }
    // One preview at a time across both size paths (SO6). `ModePreviewSession.
    // begin` ends an outstanding preview of its OWN on another display and has
    // never heard of the synthesis session, so this is where the other half ends.
    // A failed disengage refuses, for `MirroringCoordinator`'s reason: reporting
    // success would leave a panel mirrored onto a virtual display nobody approved.
    //
    // **BEFORE the claim, and the order is the whole point.** Ending a preview
    // runs `adopt`, which is the AR12 RELEASER, so standing the other preview down
    // after claiming would hand back the claim this operation just took and the
    // apply below would run unguarded. Standing down first costs nothing, and the
    // claim is then held continuously through the countdown's resolution.
    //
    // The refusal is REPORTED by the synthesis coordinator rather than as a
    // `StartFailure`: that surface says "CoreGraphics error <n>", and what went
    // wrong was a virtual display refusing to come down.
    guard await endOutstandingSynthesisPreview() else {
      log.error("Refused a mode change on display \(displayID): an outstanding synthesized size could not be disengaged")
      await adopt(.keep)
      return
    }
    // A COMMITTED set is not a preview, so the guard above never sees it. Picking
    // an ordinary row while a synthesized size is engaged has to take the set down
    // through the engine first (SS10): the panel is a mirror slave, and a mode
    // applied underneath the mirror lands invisibly. Same stand-down-before-claim
    // ordering as above.
    if !mode.isSynthesized, synthesis?.isEngaged(displayID: displayID) == true {
      // Captured BEFORE the teardown, which is what makes it unrecoverable: the
      // pairing goes, and with it the only record of which stop was on the glass.
      let engaged = synthesis?.engagedSize(displayID: displayID)
      // The MODE preview stands down before the teardown, not at `begin` below.
      // `disengageForModeChange` runs from inside this queue and so skips
      // `endOutstandingPreview` entirely; without this, a preview standing on
      // ANOTHER display would live across a multi-second reconfiguration with a
      // fallback captured before it.
      guard await endOutstandingModePreview() else {
        log.error("Refused a mode change on display \(displayID): an outstanding size preview could not be reverted")
        await adopt(.keep)
        return
      }
      guard let display = configurator.displays().first(where: { $0.id == displayID }),
            await synthesis?.disengageForModeChange(display) == true
      else {
        log.error("Refused a mode change on display \(displayID): the engaged synthesized size could not be disengaged")
        await adopt(.keep)
        return
      }
      // RULING 2026-08-18: this teardown is irreversible and happens BEFORE the
      // reversible preview below, so every way that preview can end badly has to
      // put the stop back. Revert means "return me to the screen I was looking at
      // when I picked". Armed here rather than at the capture, so a refused
      // teardown leaves nothing to restore.
      if let engaged { restoreStopIfPickFalls[displayID] = engaged }
      // The disengage reconfigured the display, so the rows this pick was made
      // from are stale. The apply below still cross-checks the descriptor, so a
      // reassigned ioModeID surfaces as a reported failure, never a wrong mode.
      refreshCatalog(for: displayID)
      // The disengage restored the pre-engage mode. When that IS the picked mode
      // there is no change left to preview and `begin` would wait on a reconfigure
      // that never comes: measured 2026-08-18, the select hung and every later
      // pick queued behind it. Ordinary picks cannot hit this, since a same-value
      // selection never fires. The kept-mode funnel runs so the stored stop is
      // cleared.
      if let current = configurator.currentMode(for: displayID),
         current.descriptor == mode.descriptor {
        // The pick LANDED, so there is nothing to put back.
        restoreStopIfPickFalls[displayID] = nil
        if let identity = identity(for: displayID), persistence.isEnabled(for: identity) {
          store(mode, on: displayID, for: identity)
        } else {
          synthesis?.clearStoredSize(displayID: displayID)
        }
        await adopt(.clear)
        return
      }
    }
    // AR12, asked BEFORE `begin()` so a refusal costs nothing: no transaction is
    // open and no display has moved. Granted when WE already hold it, since a
    // select on a second display while one is previewing is supported and
    // `ModePreviewSession.begin` handles it.
    if let holder = await gate.claim(.displayModes).refusedBy {
      // Before the failure is published and before `adopt` gives the claim back:
      // the pick is not happening, so the stop the teardown took down goes back on
      // the glass first.
      await restoreStopAfterAFallenPick(on: displayID)
      startFailure = StartFailure(displayID: displayID, reason: .blocked(by: holder))
      // Synced by this `adopt`, which must stay immediately after the write: same
      // adjacency rule as the failure branch below.
      await adopt(.clear)
      return
    }
    switch await session.begin(mode: mode, on: displayID) {
    case .success:
      await adopt(.clear)
      startCountdown()
    case let .failure(error):
      // The pick failed after an irreversible teardown, so the stop goes back
      // before anything is published. Ahead of the `startFailure` write for the
      // gate's sake: the claim this operation holds guards the re-engage, and
      // `adopt` below hands it back.
      await restoreStopAfterAFallenPick(on: displayID)
      // One of the two writes to `startFailure` that are not a clear (the other is
      // the gate refusal above). Synced by the `adopt` below, which must stay
      // immediately after it.
      startFailure = StartFailure(displayID: displayID, reason: .failed(error))
      // A `begin()` that fails may or may not have left something outstanding: it
      // refuses when the previous mode is unreadable (nothing applied), and also
      // when ending a preview on ANOTHER display failed, in which case that
      // display is still outstanding and the error is about IT. The session
      // decides, and the error attaches only if there is something to attach to.
      await adopt(.set(error))
    }
    refreshCatalog(for: displayID)
  }

  /// `performSelect` for a synthesized stop (SS4/SS5): the same recording, the
  /// same gate, the same countdown, a different engine underneath.
  ///
  /// The guards are checked HERE rather than inside the engine because a refusal
  /// has to be a sentence about this display: HDR is on (SS9), the display is the
  /// built-in (SS14), the opt-in is off, or the stop is no longer offered.
  private func performSynthesisSelect(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface
  ) async {
    guard let synthesis,
          let display = configurator.displays().first(where: { $0.id == displayID })
    else { return }
    // Already on the glass, and asked FIRST, before any view state below is
    // rewritten. Re-engaging would tear the pairing down and build a fresh virtual
    // display for the size already showing, tens of seconds to arrive back where
    // it started. Asked before the catalog lookup because the side effects below
    // overwrite the pre-pick rate fallback and dismiss a refusal the person may be
    // reading.
    //
    // **A stop's identity IS its logical size.** `SyntheticSize` derives its
    // framebuffer as exactly twice its logical size, and `SyntheticSizeCatalog`
    // emits at most one stop per logical size, so two stops cannot share a logical
    // size and differ anywhere else.
    //
    // Through the funnel like every other exit: `adopt` is the only thing that
    // republishes the preview and syncs the window. `.keep` on both sides because
    // nothing was refused.
    if let engaged = synthesis.engagedSize(displayID: displayID),
       engaged.logicalWidth == mode.logicalWidth,
       engaged.logicalHeight == mode.logicalHeight {
      await adopt(.keep, synthesis: .keep)
      return
    }
    origins[displayID] = origin
    surfaces[displayID] = surface
    // Superseded for `performSelect`'s reason, and consumed for the same one.
    dropFallenPickRestore(on: displayID, explain: false)
    // Sampled BEFORE the engage, while the panel still shows its own desktop:
    // this is the rate the mirror preserves and what the confirmation surfaces
    // name. Recorded even if the engage fails, since it describes the panel.
    synthesisPreviewRefresh[displayID] = configurator.currentMode(for: displayID)?.refreshHz
    // Every synthesized pick is a size the user chose, so it answers the
    // recommendation the same way a published size does (PD8), and only if the
    // preview is KEPT.
    selectChangesSize[displayID] = true
    dismissStartFailure()
    synthesis.dismissRefusal()
    if let key = identity(for: displayID)?.key { dismissReport(forKey: key) }

    if let reason = synthesis.refusalReason(for: display) {
      synthesis.note(reason, for: displayID)
      // `.keep` for the mode side: this refusal is about a synthesized size on
      // THIS display and says nothing about a preview standing on another one.
      await adopt(.keep, synthesis: .clear)
      return
    }
    // Re-found in the ladder this panel generates TODAY rather than taken from
    // the row, so a size the catalog has stopped offering is refused rather than
    // engaged. The row is the pointing finger; the catalog is the authority.
    guard let size = catalogs[displayID]?.syntheticStops.first(where: {
      $0.logicalWidth == mode.logicalWidth && $0.logicalHeight == mode.logicalHeight
    }) else {
      synthesis.note(.sizeNoLongerOffered, for: displayID)
      // `.keep` for the mode side: this refusal is about a synthesized size on
      // THIS display and says nothing about a preview standing on another one.
      await adopt(.keep, synthesis: .clear)
      return
    }
    // The mode side stands down FIRST, and a failure refuses: an engage would
    // otherwise mirror a panel whose previewed mode nobody has answered, and that
    // preview's fallback describes a display it no longer owns. The synthesis
    // session ends its OWN outstanding preview inside `begin`.
    //
    // **Before the claim**, for the reason `performSelect` states at the same
    // step: ending a preview runs `adopt`, the AR12 releaser, so a stand-down
    // after the claim would give back the claim this operation just took. The
    // engage runs for tens of seconds and the preview stands for thirty more, and
    // every second has to be guarded.
    guard await endOutstandingModePreview() else {
      log.error("Refused a synthesized size on display \(displayID): an outstanding mode preview could not be reverted")
      await adopt(.keep, synthesis: .keep)
      return
    }
    // AR12, before anything is created, for `performSelect`'s reason: a refusal
    // has to cost nothing.
    if let holder = await gate.claim(.displayModes).refusedBy {
      synthesis.note(.blocked(by: holder), for: displayID)
      // `.keep` for the mode side: this refusal is about a synthesized size on
      // THIS display and says nothing about a preview standing on another one.
      await adopt(.keep, synthesis: .clear)
      return
    }
    switch await synthesis.beginPreview(
      size, onPhysical: displayID, identityKey: display.identity.key
    ) {
    case .success:
      await adopt(.clear, synthesis: .clear)
      // Guarded on a preview actually standing, which a successful engage does
      // not guarantee: the engage runs its own departure sweep when it lands, and
      // the panel that just left can be this one. A countdown started over nothing
      // would tick for the rest of the session with no preview to resolve.
      if preview != nil { startSynthesisCountdown() }
    case .failure:
      // The refusal was recorded by `beginPreview`, the one place both busy
      // shapes collapse into one. Nothing is outstanding after a refusal that
      // reached the engine and failed, so `adopt` releases the gate.
      await adopt(.keep, synthesis: .keep)
    }
    refreshCatalog(for: displayID)
  }

  /// The synthesized stop as a mode a preview surface can name, with the rate
  /// the display is actually running rather than the catalog row's
  /// `refreshHz: 0` sentinel.
  ///
  /// Read LIVE first: the countdown appears after the engage tail has run, so the
  /// readback is the rate the re-time put on the wire. When the re-time could not
  /// run it is whatever the mirror negotiated, measured lower than the pre-pick
  /// rate [MEASURED 2026-08-18, OSD confirmed twice], and the live reading is
  /// still the honest one. Label-only: the answer routes on `Preview.synthesized`,
  /// so nothing matches on this value.
  private func synthesizedPreviewRow(
    _ size: SyntheticSize, on displayID: CGDirectDisplayID
  ) -> DisplayMode {
    let row = SyntheticSizeCatalog.row(for: size)
    let live = configurator.currentMode(for: displayID)?.refreshHz
    guard let hz = [live, synthesisPreviewRefresh[displayID], catalogs[displayID]?.current?.refreshHz]
      .compactMap({ $0 }).first(where: { $0 > 0 })
    else { return row }
    return DisplayMode(
      ioModeID: row.ioModeID,
      logicalWidth: row.logicalWidth, logicalHeight: row.logicalHeight,
      pixelWidth: row.pixelWidth, pixelHeight: row.pixelHeight,
      refreshHz: hz, isNative: false, provenance: .synthesized
    )
  }

  /// Puts back the synthesized size an ordinary pick took down, when the pick
  /// did not survive (RULING 2026-08-18).
  ///
  /// Unattended in shape and deliberately so: no preview, no countdown, no pref
  /// write. The person already answered, and what they answered was "put this
  /// back"; the pref naming their stop was never touched by the pick that fell.
  ///
  /// **Only ever called from an ANSWERED outcome, and only while this operation
  /// still holds the AR12 claim.** Both halves are load-bearing.
  /// `SynthesisCoordinator.engage` takes no claim of its own, so running it from a
  /// stand-down would perform tens of seconds of display reconfiguration inside
  /// another claimant's operation, or with nobody holding the gate. `ResolveIntent`
  /// keeps those routes out; running before the `adopt` that hands the claim back
  /// keeps this one in.
  ///
  /// An engine failure goes through the refusal the synthesis coordinator renders,
  /// never a `StartFailure`: that surface says "CoreGraphics error <n>", and what
  /// would have gone wrong is a virtual display.
  private func restoreStopAfterAFallenPick(on displayID: CGDirectDisplayID) async {
    guard let size = restoreStopIfPickFalls.removeValue(forKey: displayID) else { return }
    guard let synthesis,
          let display = configurator.displays().first(where: { $0.id == displayID })
    else { return }
    // The world can have moved while the preview stood: the opt-in switched off,
    // HDR turned on, the display joined a mirror set. The same guard the attended
    // and unattended engages ask, so a restore cannot re-engage into a state every
    // other path refuses.
    if let reason = synthesis.refusalReason(for: display) {
      log.info(
        "Not putting the synthesized size back on display \(displayID): \(String(describing: reason), privacy: .public)"
      )
      // The stop vanishes here as on the other two consume routes, so it gets the
      // same sentence.
      synthesis.note(reason, for: displayID)
      synthesis.clearStoredSize(displayID: displayID)
      return
    }
    // Re-found in the ladder this display generates NOW, exactly as the select
    // path does it: a rotation or a native-geometry change during the preview's
    // thirty seconds regenerates the ladder. The guard above has no
    // `sizeNoLongerOffered` arm because that refusal belongs to this lookup.
    guard let resolved = catalogs[displayID]?.syntheticStops.first(where: {
      $0.logicalWidth == size.logicalWidth && $0.logicalHeight == size.logicalHeight
    }) else {
      synthesis.note(.sizeNoLongerOffered, for: displayID)
      synthesis.clearStoredSize(displayID: displayID)
      return
    }
    log.info("Putting the synthesized size back on display \(displayID): the ordinary size it was taken down for did not stand")
    if case let .failure(failure) = await synthesis.engage(resolved, on: display) {
      synthesis.note(.engine(failure), for: displayID)
    }
    refreshCatalog(for: displayID)
  }

  /// Consumes a fallen pick's restore without performing it.
  ///
  /// The stored stop goes with it, and that is the point: the display is about to
  /// end up on something that is not the stop, so a pref still naming one would
  /// silently re-engage at the next launch a size the person last saw replaced.
  ///
  /// `explain` for the stand-down case only. There the stop disappears because
  /// another display change took over, which is not something the person did, so
  /// it gets a sentence. A superseding pick needs none.
  private func dropFallenPickRestore(on displayID: CGDirectDisplayID, explain: Bool) {
    guard restoreStopIfPickFalls.removeValue(forKey: displayID) != nil else { return }
    synthesis?.clearStoredSize(displayID: displayID)
    guard explain else { return }
    log.info("Not putting the synthesized size back on display \(displayID): another display change took over")
    synthesis?.note(.restoreSuperseded, for: displayID)
  }

  /// Why a preview is being resolved, which is what decides whether a fallen
  /// pick's synthesized size may be put back.
  ///
  /// `.reverted` is produced both when a person answers and when some OTHER
  /// operation stands the preview down on its way to reconfiguring the same
  /// displays. A restore run from one of those is an unbounded display
  /// reconfiguration inside somebody else's operation, and
  /// `SynthesisCoordinator.engage` takes no claim of its own to protect it.
  private enum ResolveIntent {
    /// The person answered, or their clock did. This outcome is the last word
    /// about what should be on the glass.
    case answered
    /// Somebody is clearing the way for an operation of their own.
    case standDown
  }

  private func performResolve(
    _ answered: Preview, keeping: Bool, intent: ResolveIntent
  ) async -> PreviewOutcome {
    if let previewed = answered.synthesized {
      return await performSynthesisResolve(previewed, keeping: keeping)
    }
    let answeredMode = PreviewedMode(displayID: answered.displayID, mode: answered.mode)
    let outcome = keeping
      ? await session.confirm(answeredMode)
      : await session.revert(answeredMode)
    switch outcome {
    case .committed:
      // While the Remember toggle is on, the stored mode tracks the resolution the
      // user KEEPS. Only this branch writes: a reverted or expired preview is a
      // mode nobody accepted and must never become the pin.
      //
      // The guarantee is the FLOW, not the type. `confirm` can return a committed
      // outcome without applying anything, replaying `lastOutcome` for an answer it
      // already gave, and that replay rewrites the SAME descriptor. Any future path
      // reaching `.committed` with a mode the user did not accept breaks this.
      //
      // Deliberately NOT narrowed to size changes the way the recommendation below
      // is: a kept rate-only change is still a kept resolution, and the stored
      // descriptor carries the refresh rate.
      //
      // `answered.mode`, not a live read: `confirm` commits the mode that was
      // PREVIEWED, and reaches `.committed` only when that apply succeeded and its
      // achieved descriptor matched. Reading live could store a mode the session
      // deliberately refused to make permanent.
      //
      // In-app changes only: a resolution changed in System Settings does not pass
      // through here and does not move the pin.
      if let identity = identity(for: answered.displayID),
         persistence.isEnabled(for: identity) {
        store(answered.mode, on: answered.displayID, for: identity)
      }
      // The kept size is an explicit choice against any stored stop, which would
      // otherwise re-engage at the next launch over the size just confirmed.
      // OUTSIDE the Remember guard, and that is the point: `ModePersistence.
      // isEnabled` defaults false, so under stock settings the clear inside `store`
      // is never reached. The two prefs are unrelated and neither may gate the
      // other.
      if !answered.mode.isSynthesized {
        synthesis?.clearStoredSize(displayID: answered.displayID)
      }
      // The pick stood, so the stop it displaced stays displaced.
      restoreStopIfPickFalls[answered.displayID] = nil
      // The size recommendation IS answered here (PD8), and only by a kept size: a
      // revert or an expiry leaves them on the size they were being asked about.
      if selectChangesSize[answered.displayID] == true {
        sizeAppliedByUser.insert(answered.displayID)
      }
      await adopt(.clear)
    case .reverted:
      // Revert and expiry both land here, and both mean the person is back on
      // whatever they had. If an irreversible teardown got them here, that is the
      // synthesized size, so it goes back before `adopt` releases the claim.
      //
      // A stand-down does NOT restore: whoever asked for it is about to reconfigure
      // these displays itself, and standing a virtual display up underneath that is
      // the collision AR12 exists to prevent. The stash is consumed either way, so
      // the pref cannot be left naming a stop the machine is not showing.
      switch intent {
      case .answered:
        await restoreStopAfterAFallenPick(on: answered.displayID)
      case .standDown:
        dropFallenPickRestore(on: answered.displayID, explain: true)
      }
      await adopt(.clear)
    case let .failed(error):
      await adopt(.set(error))
    case .stale:
      // Nothing was resolved: the outstanding preview is not the one this answer
      // was about. Keep whatever failure is on screen; it belongs to that preview.
      await adopt(.keep)
    }
    refreshCatalog(for: answered.displayID)
    return outcome
  }

  /// The synthesized half of `performResolve`.
  ///
  /// **The mapped return value is deliberately coarse.** `PreviewOutcome`'s
  /// failure case carries a `DisplayConfigError`, and no synthesis failure has a
  /// CGError behind it: fabricating one would put "CoreGraphics error 0" in front
  /// of a person whose virtual display would not come down. Everything that
  /// resolved NOTHING maps to `.stale`, which is what the one caller
  /// (`endOutstandingPreview`) needs, since it refuses unless the panel is back.
  /// The detail lives on the preview and on `SynthesisCoordinator.refusal`.
  private func performSynthesisResolve(
    _ previewed: PreviewedSynthesis, keeping: Bool
  ) async -> PreviewOutcome {
    guard let synthesis else { return .stale }
    // A confirm following a FAILED revert can hand back the identical retained
    // pairing, because the engine keeps a pairing whose teardown did not finish.
    // That is the one path where `.committed` is not evidence of a healthy set, so
    // it is sampled BEFORE the answer rather than inferred from it.
    let unwindWasIncomplete: Bool = if case .engine(.unwindIncomplete) = synthesis.refusal?.reason {
      synthesis.refusal?.displayID == previewed.physicalDisplayID
    } else {
      false
    }
    let outcome = keeping
      ? await synthesis.confirmPreview(previewed)
      : await synthesis.revertPreview(previewed)
    switch outcome {
    case let .committed(pairing):
      // SS11's ordering: the engage landed and was verified, the user kept it, and
      // only now is anything written. A revert or an expiry persists nothing.
      synthesis.persist(pairing, unwindWasIncomplete: unwindWasIncomplete)
      if selectChangesSize[previewed.physicalDisplayID] == true {
        sizeAppliedByUser.insert(previewed.physicalDisplayID)
      }
      await adopt(.clear, synthesis: .clear)
      refreshCatalog(for: previewed.physicalDisplayID)
      return .committed
    case .reverted:
      await adopt(.clear, synthesis: .clear)
      refreshCatalog(for: previewed.physicalDisplayID)
      return .reverted
    case let .failed(failure):
      // Surfaced, never swallowed: `.unwindIncomplete` means a virtual display, a
      // mirror set, or both are still standing, and `revert()` is a live retry for
      // as long as the preview stays outstanding.
      await adopt(.keep, synthesis: .set(failure))
      refreshCatalog(for: previewed.physicalDisplayID)
      return .stale
    case .stale, .busy:
      // Neither resolved anything. They differ in whether repeating helps, and
      // that difference is recorded as a refusal.
      await adopt(.keep, synthesis: .keep)
      return .stale
    }
  }

  /// Ends an outstanding preview whose display has gone.
  ///
  /// Asks the SESSION which display is outstanding, and re-reads the live list
  /// inside the queue. Gating on the derived `preview?.displayID` leaves a hole:
  /// between `begin()` succeeding and `adopt()` finishing there are three awaits
  /// where `preview` is nil while the session is outstanding, so a departure in
  /// that window would be skipped, the countdown would expire onto a dead display,
  /// and the session would wedge.
  private func dropPreviewOnDepartedDisplay() {
    queue.enqueue {
      guard let outstanding = await self.session.previewedMode else { return }
      let stillHere = self.configurator.displays().contains { $0.id == outstanding.displayID }
      guard !stillHere else { return }
      await self.session.discard(displayID: outstanding.displayID)
      await self.adopt(.clear)
    }
  }

  /// Rebuilds the UI's picture of the preview from the session. THE only writer of
  /// `preview`, so no path can leave the two disagreeing, including a countdown
  /// tick that resumes late and reconciles here. A discarded outcome is how a
  /// preview with a disarmed countdown and no driver gets created.
  private func adopt(
    _ failure: FailureUpdate, synthesis synthesisFailure: SynthesisFailureUpdate = .keep
  ) async {
    // The synthesis session is asked FIRST, and the two can never both be
    // outstanding: every path that starts one ends the other and refuses if it
    // could not. A fixed order makes that invariant visible.
    if let coordinator = synthesis,
       let outstanding = await coordinator.session.previewedSynthesis {
      let carried: SynthesisFailure? = switch synthesisFailure {
      case .clear:
        nil
      case .keep:
        preview?.synthesized == outstanding ? preview?.synthesisFailure : nil
      case let .set(failure):
        failure
      }
      let counting = await coordinator.session.isCountingDown
      preview = Preview(
        displayID: outstanding.physicalDisplayID,
        // The row rather than the size, so every surface keeps drawing one
        // thing: a mode, a countdown and two buttons.
        mode: synthesizedPreviewRow(outstanding.size, on: outstanding.physicalDisplayID),
        surface: surfaces[outstanding.physicalDisplayID] ?? .floatingPanel,
        secondsRemaining: await coordinator.session.secondsRemaining,
        failure: nil,
        isCountingDown: counting,
        synthesized: outstanding,
        synthesisFailure: carried
      )
      if !counting { stopCountdown() }
      syncConfirmation()
      return
    }
    guard let outstanding = await session.previewedMode else {
      preview = nil
      stopCountdown()
      // THE release (AR12), here rather than at each call site: this funnel
      // already runs after every path that can end a preview, so a claim cannot
      // outlive what it was protecting. Unconditional, because the gate refuses a
      // release from a claimant that is not holding it.
      await gate.release(.displayModes)
      syncConfirmation()
      return
    }
    let carried: DisplayConfigError? = switch failure {
    case .clear:
      nil
    case .keep:
      preview?.displayID == outstanding.displayID && preview?.mode == outstanding.mode
        ? preview?.failure : nil
    case let .set(error):
      error
    }
    let counting = await session.isCountingDown
    preview = Preview(
      displayID: outstanding.displayID,
      mode: outstanding.mode,
      surface: surfaces[outstanding.displayID] ?? .floatingPanel,
      secondsRemaining: await session.secondsRemaining,
      failure: carried,
      isCountingDown: counting,
      synthesized: nil,
      synthesisFailure: nil
    )
    if !counting { stopCountdown() }
    syncConfirmation()
  }

  /// Points the standalone surface at whatever the coordinator now has to say,
  /// or at nothing.
  ///
  /// It reads TWO pieces of state, `preview` and `startFailure`, so it has two
  /// callers: `adopt` (the sole writer of `preview`) and `dismissStartFailure` (the
  /// sole writer of the CLEAR of `startFailure`). The non-clear writes to
  /// `startFailure` live in `performSelect` and are synced by the `adopt` that must
  /// stay immediately after them, by adjacency rather than by a funnel. Every write
  /// to either has to be followed by this call, or the window renders a state that
  /// no longer exists, which is an empty floating panel.
  ///
  /// Called on every countdown tick, so the presenter must treat a repeat
  /// present of unchanged content as a no-op.
  private func syncConfirmation() {
    // A preview outranks a start failure: it has a countdown and a screen at
    // stake. They can only coexist on DIFFERENT displays, since `performSelect`
    // clears the failure before it begins.
    //
    // **The preview's own `surface` decides this window (SO6), fixed at start.**
    // The floating window is the default owner, on the display the question is
    // about. The settings banner owns the answer when the change came from a key
    // settings window, because two button rows asking one question is the defect
    // the surface model exists to prevent. The guided setup flow owns it when that
    // window started the apply (DM11). Either owner takes this window off screen.
    //
    // Known residue, accepted with SO6: ownership does not migrate mid-preview,
    // and the banner region renders only on the preview's own display destination,
    // so switching the sidebar or closing the window hides the answerable surface.
    // An armed countdown survives both and its expiry reverts unattended. A failed
    // EXPIRY in that state leaves the answer only on the owning banner until the
    // user navigates back, which is also the recovery.
    if let preview {
      switch preview.surface {
      case .floatingPanel:
        confirmation?.presentConfirmation(.preview(preview.displayID))
      case .settingsBanner, .guidedSetup:
        confirmation?.dismissConfirmation()
      }
      return
    }
    // A failed `begin()` produces no preview, so without this a panel selection
    // that fails reports nothing at all: the menu closes on selection, taking the
    // panel's own banner with it, and the screen does not change either.
    if let startFailure, origins[startFailure.displayID] == .panel {
      confirmation?.presentConfirmation(.startFailure(startFailure.displayID))
      return
    }
    confirmation?.dismissConfirmation()
  }

  /// The countdown driver.
  ///
  /// Detached, and its main-actor hop is fire-and-forget. Both halves matter: the
  /// tick and the revert it triggers run on the session's executor, and the loop's
  /// next `sleep`/`tick()` never waits on the main actor. A main thread wedged by a
  /// synchronous reconfiguration callback or by blocking work in a pane must not be
  /// able to stop the expiry, which is what rescues a screen nobody can read.
  private func startCountdown() {
    let session = session
    countdown.start(tick: { await session.tick() }) { [weak self] outcome in
      guard let self else { return }
      // Through the queue, never straight to `adopt`: a tick that landed
      // mid-apply would otherwise publish a picture the apply is about to
      // replace.
      queue.enqueue { await self.adoptModeTick(outcome) }
    }
  }

  /// A mode tick that landed, reconciled inside the queue. nil is an ordinary
  /// tick; anything else is the expiry having resolved the preview on the
  /// session's own executor.
  private func adoptModeTick(_ outcome: PreviewOutcome?) async {
    // Sampled BEFORE the reconciliation, which resolves the preview away: after
    // it, nothing names the display it was about.
    let displayID = preview?.displayID
    // An expiry is a revert nobody attended, so it owes the same restore (RULING
    // 2026-08-18), before `adopt` gives the claim back.
    if case .reverted = outcome, let displayID {
      await restoreStopAfterAFallenPick(on: displayID)
    }
    if case let .failed(error) = outcome {
      await adopt(.set(error))
    } else {
      await adopt(.keep)
    }
  }

  /// The same clock for a synthesized size, and the same two properties that
  /// make it safe.
  ///
  /// The tick reaches the SESSION ACTOR directly rather than
  /// `SynthesisCoordinator`, which is main-actor isolated: routing it through that
  /// object would put a wedged main thread back on the expiry's critical path, and
  /// the expiry is what takes down a virtual display nobody answered for. One
  /// driver serves both preview kinds, since only one can be outstanding.
  private func startSynthesisCountdown() {
    guard let synthesis else { return }
    let session = synthesis.session
    countdown.start(tick: { await session.tick() }) { [weak self] outcome in
      guard let self else { return }
      queue.enqueue { await self.adoptSynthesisTick(outcome) }
    }
  }

  /// A synthesis tick that landed, reconciled inside the queue for the mode
  /// side's reason: a tick that arrives mid-apply must not publish a picture
  /// the apply is about to replace.
  private func adoptSynthesisTick(_ outcome: SynthesisPreviewOutcome?) async {
    guard let synthesis else { return }
    guard let outcome else {
      await adopt(.keep, synthesis: .keep)
      return
    }
    // Sampled BEFORE the reconciliation, which resolves the preview away: after
    // it, nothing names the display the expiry was about.
    let displayID = preview?.displayID
    // The clock resolved the preview on the session's own executor, so the pairing
    // snapshot and the refusal state have to catch up before anything is rebuilt
    // from them.
    await synthesis.adoptExpiry(outcome, on: displayID ?? kCGNullDirectDisplay)
    switch outcome {
    case let .failed(failure):
      await adopt(.keep, synthesis: .set(failure))
    case .committed, .reverted, .stale, .busy:
      await adopt(.keep, synthesis: .keep)
    }
    if let displayID { refreshCatalog(for: displayID) }
  }

  private func stopCountdown() {
    countdown.stop()
  }

  /// THE only writer of `storedDisplayMode`. Announcing the write is part of
  /// making it, so no caller can perform one and forget the propagation.
  private func store(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID, for identity: DisplayConfigIdentity
  ) {
    persistence.store(mode.descriptor, for: identity)
    // A kept ordinary mode is an explicit choice against any stored stop, which
    // would otherwise re-engage at the next launch over the size just kept. No-op
    // when nothing is stored.
    //
    // NOT the only site: `store` runs only while Remember is on, off by default,
    // so `performResolve`'s committed arm clears independently. This one covers
    // `pinCurrentMode`, where an explicit pin is the same choice by another
    // gesture.
    if !mode.isSynthesized {
      synthesis?.clearStoredSize(displayID: displayID)
    }
    didStoreMode(displayID)
  }

  private func identity(for displayID: CGDirectDisplayID) -> DisplayConfigIdentity? {
    catalogs[displayID]?.display.identity
      ?? configurator.displays().first { $0.id == displayID }?.identity
  }

  private struct LogicalSize: Hashable {
    let width: Int
    let height: Int

    init(mode: DisplayMode) {
      width = mode.logicalWidth
      height = mode.logicalHeight
    }
  }
}

/// What the standalone surface is showing.
///
/// Two cases because the outcomes differ: a preview is a question with a
/// countdown behind it, a start failure is a statement with nothing outstanding.
/// They arrive in either order, so the presenter has to be able to tell that its
/// content CHANGED for the same display, which a display ID alone cannot say.
enum ModeConfirmationContent: Hashable {
  /// A preview is applied and unresolved on this display.
  case preview(CGDirectDisplayID)
  /// `begin()` failed on this display. Nothing was applied and nothing is
  /// outstanding; there is only something to report.
  case startFailure(CGDirectDisplayID)

  var displayID: CGDirectDisplayID {
    switch self {
    case let .preview(id), let .startFailure(id): id
    }
  }
}

/// A surface that reports on a mode change independently of whichever view
/// started it. Declared beside the coordinator and AppKit-free, so the contract
/// belongs to the thing that needs it; the window implementing it is an
/// app-target island like every other.
@MainActor
protocol ModeConfirmationPresenting: AnyObject {
  /// Must be idempotent for unchanged content: called again on every countdown
  /// tick.
  func presentConfirmation(_ content: ModeConfirmationContent)
  func dismissConfirmation()
}

extension DisplayModeCoordinator.Catalog {
  /// The words that name one mode of THIS panel: the same logical size is native
  /// on one display and an oversized render on another.
  ///
  /// **RM11 rests on this.** The size label no longer hedges, so these words carry
  /// the claim instead and every surface offering a size has to wear them. Computed
  /// in ONE place, because three private copies is how the rule drifts.
  ///
  /// Words, not a formatted string: a popup item parenthesises them, a two-column
  /// row separates them with a dot. The words are the statement, the punctuation is
  /// layout.
  ///
  /// SO14 retires "HiDPI" from copy. The inversion is macOS's own: the sharp mode
  /// says nothing, and the 1x duplicate it was distinguished FROM carries "low
  /// resolution" instead.
  ///
  /// `isLowResolutionDuplicate` is asked of `DisplayModeCatalog` once per catalog
  /// rather than once per row: the answer depends on the mode's siblings at the
  /// same logical size, and the full list renders hundreds of rows. Curated
  /// surfaces pass `false`.
  ///
  /// "Scaled" is suppressed rather than guessed when the panel's native size is
  /// unknown, and is never said about the native mode itself.
  func tags(for mode: DisplayMode, isLowResolutionDuplicate: Bool) -> [String] {
    var tags: [String] = []
    if mode.isNative { tags.append("Native") }
    // A synthesized row never says "Scaled": the rendered badge subsumes it, and
    // the pair truncates a menu-bar row to "(Scaled, Rendered by C...)".
    if isScaled(mode), !mode.isSynthesized { tags.append("Scaled") }
    if isLowResolutionDuplicate { tags.append("low resolution") }
    return tags
  }

  /// Suppressed rather than guessed when the panel's native size is unknown,
  /// and never said about the native mode itself.
  private func isScaled(_ mode: DisplayMode) -> Bool {
    guard let nativePixels, !mode.isNative else { return false }
    return mode.isScaled(
      nativePixelWidth: nativePixels.width, nativePixelHeight: nativePixels.height
    )
  }

  /// The size and its tags as one label, for surfaces that draw a single
  /// string: a popup item, a panel row, a disclosure summary.
  ///
  /// `isLowResolutionDuplicate: false`, deliberately: the caller renders the
  /// CURATED list, one row per logical size, and a curated row is a 1x mode with a
  /// sharp twin only when that mode is the panel's NATIVE one. Tagging a display's
  /// own native resolution "low resolution" would be an insult rather than a
  /// distinction, and the twin is not on screen to be distinguished from.
  ///
  /// The density model's mark rides along in the SAME bracket as the tags: the
  /// caller draws one string on one line, so a mark of its own would be a second
  /// pair of brackets on a 280 pt row.
  ///
  /// "Rendered by Candela" rides along too (SS5), as a COST rather than a note
  /// about provenance: the menu-bar panel offers these stops from this very label,
  /// and pressing one stands a virtual display up for as long as the size is in
  /// use, so leaving it out would offer the cost invisibly. Last, because nothing
  /// above it is longer than a word.
  func badgedSize(_ mode: DisplayMode) -> String {
    var marks = tags(for: mode, isLowResolutionDuplicate: false)
    if isRecommendedSize(mode) { marks.append(DisplayModeCopy.recommended) }
    if mode.isSynthesized { marks.append(SynthesisCopy.badge) }
    guard !marks.isEmpty else { return DisplayModeCopy.size(mode) }
    return "\(DisplayModeCopy.size(mode)) (\(marks.joined(separator: ", ")))"
  }

  /// The mode to apply for a curated row: the chosen SIZE at the refresh rate
  /// the display is already running, when that size offers it.
  ///
  /// A size change should not silently move someone from 60 Hz to 175 Hz, and the
  /// curated row carries the size's FASTEST rate as its representative, so taking
  /// the row's own mode would do exactly that.
  ///
  /// `ModePersistence.resolve` is the tested answer (geometry plus desired refresh
  /// to best live mode, deterministic down to `ioModeID`), so the rule is not
  /// re-invented in a view. Its cross-size fallbacks cannot help here, the row
  /// having come from the live list, so a resolved mode at a different size is
  /// rejected in favour of the row's own representative.
  ///
  /// Lives here rather than in either view because the panel and the settings pane
  /// must apply the same rule.
  func modeKeepingCurrentRefreshRate(for row: DisplayModeRow) -> DisplayMode {
    // A synthesized row carries the `refreshHz: 0` sentinel and has no rate to
    // keep: while engaged the rate is the virtual master's achievable one [MEASURED
    // 2026-08-18: 100 Hz on a 5160x2160 master, from both 175 and 100 Hz starts],
    // and the display's own rate returns on disengage. Resolving it against the
    // live list would match on geometry the panel does not publish, or on
    // nothing.
    guard !row.mode.isSynthesized else { return row.mode }
    let wanted = DisplayModeDescriptor(
      logicalWidth: row.mode.logicalWidth,
      logicalHeight: row.mode.logicalHeight,
      pixelWidth: row.mode.pixelWidth,
      pixelHeight: row.mode.pixelHeight,
      refreshHz: current?.refreshHz ?? row.mode.refreshHz
    )
    return mode(matching: wanted, atSizeOf: row.mode) ?? row.mode
  }

  /// Resolves `descriptor` against the live list, keeping the answer only when
  /// it is still the size the caller asked about.
  func mode(matching descriptor: DisplayModeDescriptor, atSizeOf size: DisplayMode) -> DisplayMode? {
    let match: DisplayMode? = switch ModePersistence.resolve(descriptor, in: all) {
    case let .exact(mode): mode
    case let .refreshRateDiffers(mode): mode
    case let .scaleDiffers(mode): mode
    case let .sizeDiffers(mode): mode
    case .none: nil
    }
    guard let match,
          match.logicalWidth == size.logicalWidth,
          match.logicalHeight == size.logicalHeight
    else { return nil }
    return match
  }

  /// True for the row whose LOGICAL SIZE the display is running. Comparing
  /// `ioModeID` instead would leave the checkmark off whenever the user is at a
  /// size's slower refresh rate: the curated row's representative mode is that
  /// size's FASTEST rate, so the IDs differ while the size is plainly selected.
  ///
  /// **While a synthesized size is engaged, the ENGINE decides this and the
  /// readback is not consulted.** The engage tail re-times the slave, so the
  /// readback names the panel's own native mode [MEASURED 2026-08-18] and matching
  /// against it would tick a published row that is not on the glass.
  func isCurrentSize(_ mode: DisplayMode) -> Bool {
    if let engagedSyntheticSize {
      return mode.isSynthesized
        && engagedSyntheticSize.logicalWidth == mode.logicalWidth
        && engagedSyntheticSize.logicalHeight == mode.logicalHeight
    }
    // Nothing is engaged, so a synthesized row is an offer rather than a state.
    guard !mode.isSynthesized, let current else { return false }
    return current.logicalWidth == mode.logicalWidth && current.logicalHeight == mode.logicalHeight
  }

  /// True for the row whose LOGICAL SIZE the density model ranked best.
  ///
  /// A size match, the same rule `isCurrentSize` follows, because a recommendation
  /// IS a logical size: `SizeRecommendation` carries no `ioModeID` precisely so
  /// mode-id instability cannot reach it.
  ///
  /// Reads `bestInBand` rather than `recommendation`, so the mark persists while
  /// the display is already running the recommended size: a mark is an endorsement,
  /// still true once the suggestion has nothing left to suggest. The callout keys
  /// to `recommendation` and still hides on every abstention. False whenever there
  /// is no verdict or nothing applicable reached the band.
  ///
  /// A synthesized stop whose logical size equals the recommended one inherits the
  /// mark. **Ruled 2026-08-18: that ships as it is.** Do not add a guard for it
  /// here or at a call site.
  func isRecommendedSize(_ mode: DisplayMode) -> Bool {
    guard let recommendation = density?.bestInBand else { return false }
    return recommendation.logicalWidth == mode.logicalWidth
      && recommendation.logicalHeight == mode.logicalHeight
  }

  /// Whether this size is the one macOS itself calls Default for the panel.
  ///
  /// Built-in only, deliberately. On a high-PPI panel the default is the
  /// looks-like size whose framebuffer IS the panel (the HiDPI native-flagged mode:
  /// 1512x982 on a 3024x1964 panel, measured 2026-08-19), so the flag answers
  /// directly. On a standard-PPI external the same flag rides the HiDPI twin, which
  /// is NOT what System Settings calls Default there, so answering for externals
  /// would badge the wrong row confidently. Externals get the density model's
  /// Recommended instead; the built-in never does, since no physical size is filed
  /// for it.
  ///
  /// The 1x fallback covers a non-Retina panel, where the only native-flagged mode
  /// is the panel size itself and that IS the default.
  func isDefaultSize(_ mode: DisplayMode) -> Bool {
    guard display.isBuiltIn else { return false }
    guard let anchor = all.first(where: { $0.isNative && $0.isHiDPI })
      ?? all.first(where: \.isNative)
    else { return false }
    return anchor.logicalWidth == mode.logicalWidth
      && anchor.logicalHeight == mode.logicalHeight
  }
}
