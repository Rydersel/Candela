import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of display-mode enumeration, the preview countdown, and
/// stored-mode writes.
///
/// The plan handed Task 8 a section view with `onSelect` closures and never
/// named an owner for `ModePreviewSession`. A view cannot be that owner: the
/// countdown has to keep running after the view that started it goes away —
/// that is the entire safety argument for previewing at all (a mode can leave
/// the screen unreadable, so the safe outcome must be the one that happens when
/// nobody does anything). So it lives on `AppModel`, where the settings pane
/// and the panel drive ONE session and read ONE answer.
///
/// Two rules hold this together and neither is optional:
///
/// 1. **Every session-touching operation is serialised** through `queue`.
///    Without it, two clicks both suspend inside `begin()`, the actor
///    serialises them, and their main-actor continuations resume in an order
///    unrelated to the actor's — leaving the banner naming one mode while
///    "Keep" commits the other at session scope.
/// 2. **The UI's state is rebuilt FROM the session** (`adopt`), never from what
///    a caller remembers passing in. The two disagree exactly when something
///    went wrong, and the session is the one that decides what is applied.
@MainActor @Observable
final class DisplayModeCoordinator {
  /// Which surface asked for the preview that is outstanding.
  ///
  /// It does not decide where a PREVIEW is answered — `PreviewSurface` does,
  /// and the two are separate values because they answer different questions
  /// ("who asked" vs "who answers"). What origin decides is where a failed
  /// `begin()` is reported: the settings pane has a row of its own for that and
  /// stays on screen, while the panel is an `NSMenu` tracking session that ends
  /// on Escape, on a click in the menu bar, and — the case that matters — on
  /// the selection itself, so a panel-origin failure would otherwise be shown
  /// to nobody.
  enum PreviewOrigin: Sendable {
    case settings
    case panel
  }

  /// Which surface ANSWERS the outstanding preview (SO6): exactly one is
  /// answerable per preview. Decided at preview start and carried on the
  /// preview — never re-derived mid-countdown, so the buttons cannot migrate
  /// under the user's pointer.
  ///
  /// `.settingsBanner` iff the change originated from the settings window while
  /// that window was key (the caller reads its own `controlActiveState` at the
  /// click); everything else — the panel, and a settings surface in a non-key
  /// window — is answered by the floating `ConfirmationPanel`, which then does
  /// not show while a banner owns the answer. The non-owning surface renders
  /// passive text only.
  enum PreviewSurface: Sendable {
    case floatingPanel
    case settingsBanner
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
    /// The panel's own framebuffer, from the mode carrying the native flag.
    /// nil when no mode carries it: `isScaled` is then undecidable and the
    /// badge is suppressed rather than guessed — comparing against a
    /// zero-sized panel would mark every mode as scaled.
    ///
    /// Kept as the SIZE rather than as a bare "is it known" flag because the
    /// full list has to answer `isScaled` per mode, and only the curated rows
    /// carry a precomputed answer.
    let nativePixels: PixelSize?
    /// How many revealed modes the #110 wire-timing guard withheld. Reported
    /// rather than merely applied: modes vanishing with no account is the same
    /// silence we refuse elsewhere (CR11), and on the hardware pass this count
    /// is what distinguishes "the guard fired" from "revelation found nothing".
    let withheldForWireTiming: Int
    /// What the density model made of this panel, judged over the SAME curated
    /// rows this catalog publishes (PD1): a size the wire-timing guard withheld
    /// has no apply path, so it must never become a recommendation.
    ///
    /// nil when the panel's native pixels are unknown, or when no facts
    /// provider is installed (the default closure, i.e. every test that does not
    /// wire one). A display with no entry in the app's hardware facts is NOT
    /// this case: the provider still answers, with nil sizes, and the model
    /// abstains with a `.noPhysicalSize` verdict. Both cases here are "no
    /// geometry", and no geometry means no judgement rather than one from zeros.
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
    /// app-test fixtures that build a catalog by hand predate synthesis. The
    /// coordinator always passes both this and the field below.
    var syntheticStops: [SyntheticSize] = []
    /// The stop currently on the glass, from the ENGINE's pairing table.
    ///
    /// Phase 0 measured that a synthesis-engaged panel's `currentMode` readback
    /// is a synthetic descriptor under a fabricated mode ID that appears in no
    /// enumeration, so nothing may match against it. This is what the
    /// current-row highlight reads instead; see `isCurrentSize`.
    var engagedSyntheticSize: SyntheticSize?

    var nativeKnown: Bool { nativePixels != nil }
  }

  /// The panel-derived values a catalog is built from, cached per
  /// `DisplayConfigIdentity.key` while the display is showing its own desktop.
  ///
  /// **Reused while a synthesized size is engaged, and that is the whole
  /// point.** An engaged panel is a mirror slave: its readbacks describe the
  /// virtual master rather than the panel, so a pass that re-derived the native
  /// pixels, the density verdict or the stop ladder from them would rewrite all
  /// three from the wrong display, and the engaged row could vanish from the
  /// picker it is meant to be checked in.
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
  /// reassign across a replug, and the is-virtual predicate, which no
  /// plausibility range could ever stand in for (a virtual display declares a
  /// perfectly ordinary fake size).
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
    /// Set when `confirm()`, `revert()` or the expiry threw. The display did
    /// not move, the session still holds the fallback, and both buttons stay
    /// live — nothing auto-retries, so a silent failure would leave the user on
    /// a mode they never approved, held only until the app exits.
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
    /// whole `PreviewedSynthesis` is what makes an answer resolve only the
    /// preview it was given for: a re-engage at the same size is a different
    /// virtual display in a different slot.
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
  /// Reapply is unattended, so this is the ONLY way the user finds out. It is
  /// kept per display and survives until they dismiss it or pick a mode
  /// themselves — the point is that it is still there the next time they look,
  /// not that it was true at the moment nobody was watching. Unplugging the
  /// display no longer takes it away (SO8): the display coming back is exactly
  /// when someone is in front of it again.
  struct ReapplyReport: Equatable {
    /// `DisplayConfigIdentity.key` — the SAME key the stored mode this report is
    /// about is filed under, not a `CGDirectDisplayID`. IDs reassign across a
    /// replug, so an ID-keyed report either has to be thrown away on departure
    /// or risks surfacing on whichever display takes the ID next. Carried on the
    /// report rather than only in the dictionary so a surface rendering one can
    /// dismiss exactly the report it is showing.
    let key: String
    /// What the user actually chose, not what we managed. Kept so the report
    /// can name it — "we could not give you X" is a different sentence from
    /// "you are on Y", and the first is the one that explains anything.
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
    /// statements: one is the hardware or CoreGraphics saying no, the other is
    /// this app refusing to reconfigure a display while it is already
    /// reconfiguring displays (AR12). One state with two reasons rather than two
    /// states, so `dismissStartFailure` stays THE only place either is cleared.
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
  /// It inherits that key's KNOWN LIMITATION rather than escaping it — see
  /// `DisplayConfigIdentity`'s header. Two identical panels reporting serial 0
  /// (the MAG 341C does) produce the SAME key, so with twins attached one
  /// report overwrites the other and the survivor renders on both panes. The
  /// stored mode already collides the same way for the same displays, so this
  /// is one limitation, not a new one; fixing it means fixing the identity.
  private(set) var reapplyReports: [String: ReapplyReport] = [:]
  /// True from the click until the reconfiguration it started has settled.
  /// `begin()` spans a real CoreGraphics mode change, and a Keep pressed inside
  /// that window is queued behind it and would commit the NEW mode while the
  /// banner still named the old one — correct ordering, wrong intent. Set
  /// synchronously so the disable lands in the same body evaluation as the
  /// click that caused it.
  private(set) var isApplying = false
  /// Displays whose user has applied a size in THIS session (PD8): a person who
  /// just chose a size has answered the recommendation for now, and the durable
  /// opt-out is the dismissal pref.
  ///
  /// In memory and never persisted, deliberately, for that same split: the
  /// dismissal is the answer that outlives a launch, and a second stored
  /// hide-forever key would be a second way to lose the suggestion for good.
  /// Written only by a KEPT preview, so a reverted or expired try leaves the
  /// suggestion standing.
  private(set) var sizeAppliedByUser: Set<CGDirectDisplayID> = []
  /// Whether the select now in flight changes the display's logical SIZE,
  /// sampled before `begin()` moves it. PD8 is about applying a size: a refresh
  /// rate picked at the size already on screen answers nothing about how big
  /// things look, so it must not hide the callout.
  @ObservationIgnored private var selectChangesSize: [CGDirectDisplayID: Bool] = [:]

  let configurator: any DisplayConfiguring
  let persistence: ModePersistence

  /// CR10. False means the mode list is exactly what CoreGraphics publishes —
  /// reported in diagnostics rather than silently indistinguishable from a
  /// panel that simply has no hidden modes.
  var revealsHiddenModes: Bool { configurator.revealsHiddenModes }

  /// #110. Zero withheld modes means something different depending on this, so
  /// the two are always reported together.
  var guardsWireTiming: Bool { configurator.guardsWireTiming }

  /// AR12. Held from just before `begin()` until nothing is outstanding, so no
  /// other display-reconfiguring feature can move a display out from under a
  /// preview whose fallback was captured before it.
  ///
  /// Not defaulted, and deliberately so: a per-coordinator default would compile,
  /// run, and exclude nobody — four private gates are four features that all
  /// think they are alone.
  @ObservationIgnored private let gate: DisplayReconfigurationGate

  /// Where a `.panel`-origin preview is answered. Wired at launch; nil means
  /// the app never installed one, which degrades to "no confirmation surface
  /// for panel selections" rather than to a crash.
  @ObservationIgnored weak var confirmation: (any ModeConfirmationPresenting)?

  /// Called after something actually wrote `storedDisplayMode` (a pin or a kept
  /// preview), so the propagation seam hears about it (D27) no matter which
  /// surface asked.
  /// Owned here because it used to be the asking view's job, and two views
  /// answering the same question is one too many — the second one to be written
  /// is the one that forgets.
  @ObservationIgnored var didStoreMode: (CGDirectDisplayID) -> Void = { _ in }

  /// Called when a stored-mode reapply could not be honoured, so the diagnostics
  /// report's event ring carries it (spec §7). Wired for `didStoreMode`'s
  /// reason: this happens unattended, at reconnect, with no view on screen — and
  /// the notice a surface can still render is `report(for:)`, which holds only
  /// the LATEST one per display and is cleared when the user dismisses it.
  @ObservationIgnored var didReportReapply: (CGDirectDisplayID, ModeReapplyNotice) -> Void = { _, _ in }

  /// The app's answer to "what is this panel physically". Injected because the
  /// lookup it performs (`AppModel.hardwareFacts`, the owned/foreign virtual
  /// check) lives one layer up; the coordinator only enumerates modes.
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
  /// Per display, not one value for the coordinator. A settings-select on B
  /// whose `begin()` fails leaves A's preview outstanding and reports the error
  /// against A — with a single `origin` that select would have flipped the whole
  /// coordinator to `.settings` and torn down A's confirmation window while A
  /// was still counting down. Keyed, the surface follows the preview.
  @ObservationIgnored private var origins: [CGDirectDisplayID: PreviewOrigin] = [:]
  /// Keyed like `origins` and for its reason: the answering surface follows the
  /// preview, not the coordinator. Read back in `adopt`, which rebuilds
  /// `Preview` from the session and needs the one field the session does not
  /// hold. A missing entry answers `.floatingPanel` — the safe default, since
  /// the floating window shows on the display that changed.
  @ObservationIgnored private var surfaces: [CGDirectDisplayID: PreviewSurface] = [:]
  @ObservationIgnored private let countdown = PreviewCountdownDriver()
  @ObservationIgnored private let queue = PreviewQueue()
  @ObservationIgnored private var inFlightSelects = 0
  /// Displays anything has asked about. `handleDisplaysChanged` re-enumerates
  /// these rather than only the currently cached ones, so a display that
  /// departs and returns under the same ID gets its catalog back — a nil
  /// catalog now renders as "not enumerated yet", i.e. as nothing at all, and
  /// `.task(id:)` does not re-fire for an unchanged id.
  @ObservationIgnored private var observed: Set<CGDirectDisplayID> = []
  /// The last panel-derived values taken while each display was showing its own
  /// desktop, keyed by `DisplayConfigIdentity.key` so they survive the replug
  /// that reassigns display IDs. See `PanelBaseline`.
  @ObservationIgnored private var baselines: [String: PanelBaseline] = [:]
  /// The panel's own refresh rate at the moment a synthesized size was picked
  /// on it.
  ///
  /// The catalog's synthesized ROWS carry the `refreshHz: 0` sentinel, because
  /// a stop is a size and the rate it runs at is the panel's, not the stop's.
  /// The confirmation surfaces name a rate though, and "0 Hz" is a number no
  /// display runs at. The mirror preserves the physical panel's refresh
  /// [MEASURED 2026-08-17: 100 Hz before, during and after], so the honest
  /// answer is the rate the panel was already running.
  @ObservationIgnored private var synthesisPreviewRefresh: [CGDirectDisplayID: Double] = [:]
  /// Which displays count as having just arrived — the "launch and reconnect,
  /// never continuously" rule (DM7). It lives in `CandelaKit` under test
  /// because its two failure directions are both timing, and both are invisible
  /// from here: too eager fights the user forever, too shy silently fails to
  /// restore anything on the replug the feature is named for.
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
      // the handler — never re-read on the other side of the hop.
      //
      // The hop is unavoidable (this block is not main-actor isolated) and its
      // delay is unbounded: this codebase documents main-actor work being
      // starved during menu tracking. If an unplug and a replug post
      // back-to-back, both handlers would then read a list with the display
      // present and conclude it never left — and the resolution the user
      // remembered would silently not come back, in exactly the case they
      // enabled the feature for. Reading `configurator` rather than `self` is
      // what makes the sample legal here: it is `Sendable` and captured
      // directly, so nothing touches the main-actor object off the main actor.
      let live = Set(configurator.displays().map(\.id))
      Task { @MainActor in self?.handleDisplaysChanged(observedLive: live) }
    }
  }

  /// The notification token is deliberately not unregistered here: it is not
  /// `Sendable`, so a nonisolated `deinit` cannot touch it. Harmless — this
  /// object lives as long as the app, and the block holds `self` weakly, so a
  /// surviving registration is inert rather than dangling.
  deinit {
    countdown.stop()
    queue.cancel()
  }

  // MARK: - Enumeration

  /// The display's current mode: the cached catalog when one exists, else a
  /// live query. A catalog is populated only when something has SHOWN this
  /// display (its own pane, or the panel's warm pass, which walks externals
  /// only), so a reader treating `catalogs` as the answer reported the
  /// built-in's mode as "not reported" exactly when the report was copied from
  /// another display's page (combined pass D8). Diagnostics reads this
  /// instead; it never enumerates and never caches.
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    catalogs[displayID]?.current ?? configurator.currentMode(for: displayID)
  }

  /// Re-enumerates one display. Called when a pane appears, when the screen
  /// configuration changes, and after any mode this app applies — never on a
  /// timer (DM7).
  func refreshCatalog(for displayID: CGDirectDisplayID) {
    observed.insert(displayID)
    guard let display = configurator.displays().first(where: { $0.id == displayID }) else {
      catalogs[displayID] = nil
      dropPreviewOnDepartedDisplay()
      return
    }
    let all = DisplayModeCatalog.full(configurator.modes(for: displayID))
    // Panel-derived values come from the last pass taken while this display was
    // showing its own desktop whenever a synthesized size is engaged, because
    // an engaged panel's readbacks describe the virtual master instead of the
    // panel. See `PanelBaseline`.
    let engagedSize = synthesis?.engagedSize(displayID: displayID)
    let baseline = baseline(for: display, modes: all, isEngaged: engagedSize != nil)
    let native = baseline.nativePixels.map { (width: $0.width, height: $0.height) }
    // Sampled here, once, and handed to both the catalog and the verdict: the
    // size the model calls "current" has to be the size this enumeration saw,
    // not one re-read after the rows were built.
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
    // Offered only where SS4's opt-in is on, and never on the built-in (SS14).
    // The ladder itself is cached on the baseline, so the rows a person sees do
    // not change under them while a size is engaged.
    let stops = synthesis?.offersSyntheticSizes(displayID: displayID) == true && !display.isBuiltIn
      ? baseline.stops
      : []
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
          // PUBLISHED rows only. Wiring the size recommendation to synthesized
          // stops is a filed non-goal for v1, and the model ranks whatever it
          // is handed, so passing the merged list would recommend a size that
          // costs a virtual display.
          rows: published,
          // The engaged size, not the readback, for `Catalog.engagedSyntheticSize`'s
          // reason: a mirrored panel reports the master's geometry.
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
    // it, so it does not replace a baseline that could.
    if native != nil || baselines[key] == nil { baselines[key] = baseline }
    return baselines[key] ?? baseline
  }

  /// Screen configuration changed: re-enumerate what is still here, forget what
  /// is not, and — the part that matters — end a preview on a display that has
  /// departed. Left alone, the expiry would apply the fallback to a dead
  /// display, fail, and leave the session holding an outstanding preview
  /// forever; `begin()` on ANY other display then reverts-first, fails, and
  /// refuses, so one unplug would wedge mode switching for the whole session.
  /// - Parameter observedLive: the display set as it was WHEN THE NOTIFICATION
  ///   WAS POSTED. Not the same thing as the set live now, and the difference
  ///   is the whole point: a departure has to count as a departure even when
  ///   the display is back by the time this runs. Everything else below reads
  ///   the CURRENT list instead — a catalog or a report must describe what is
  ///   plugged in now, not what was plugged in a moment ago.
  func handleDisplaysChanged(observedLive: Set<CGDirectDisplayID>) {
    let live = Set(configurator.displays().map(\.id))
    // Over `observed`, not over `catalogs`: a departed display's entry is nil,
    // so iterating the cache would never re-enumerate it when it comes back.
    for displayID in observed {
      if live.contains(displayID) {
        refreshCatalog(for: displayID)
      } else {
        catalogs[displayID] = nil
        // Both are keyed by display ID, which the next display to arrive can
        // inherit, so a departure has to take them: a suggestion silently
        // suppressed on a panel nobody has chosen a size for is the failure
        // this feature has no visible symptom for.
        sizeAppliedByUser.remove(displayID)
        selectChangesSize[displayID] = nil
        synthesisPreviewRefresh[displayID] = nil
      }
    }
    // A departure is what makes the next arrival an arrival, so it is recorded
    // HERE, from the undebounced screen-parameters notification and from the
    // set that notification was posted with. Two separate reasons the app's own
    // topology signal cannot be the only source: it coalesces a burst into a
    // single element, so an unplug and replug inside its one-second quiet
    // window would arrive as one event with the display present at both ends;
    // and this handler itself can run late, which is why it is told what was
    // live rather than asked to look.
    arrivals.noteObserved(live: observedLive)
    // Reports are deliberately NOT pruned here (SO8). Pruning existed for one
    // reason — an ID-keyed report would reappear on whatever display took the ID
    // next — and identity keying removes that hazard outright. What is left is
    // the case the report exists for: a reapply nobody watched, on a display the
    // user unplugged before looking. Dropping it on departure means the one
    // moment they are back in front of that display is the moment the account of
    // it is gone. Only a dismissal, or a later pass with a newer outcome for the
    // same identity, clears one.
    //
    // A start failure is different and still cleared below: it is about a
    // control on a page that has just disappeared, and its surface is a floating
    // window AppKit would relocate onto another screen. It needs saying
    // separately because the preview path self-heals here and this one cannot —
    // a failure has no countdown re-presenting it every second, and
    // `dropPreviewOnDepartedDisplay` returns early when nothing is outstanding.
    if let failure = startFailure, !live.contains(failure.displayID) {
      dismissStartFailure()
    }
    dropPreviewOnDepartedDisplay()
    dropSynthesisOnDepartedDisplay(live: live)
  }

  /// A synthesis set whose physical panel has gone is taken DOWN, not
  /// forgotten. The virtual display outlives the panel's departure and holds
  /// one of only two synthesis slots, so dropping the record instead would
  /// strand a display nothing can reach and lose the slot until the app
  /// restarts.
  ///
  /// Reads the CURRENT list rather than the notification's, unlike the
  /// departure bookkeeping above: this is about hardware to take down, so the
  /// question is what is attached now, not what was attached a moment ago. A
  /// display that left and came back before this ran has nothing to unwind.
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
  /// `CGDisplayReconfigurationCallBack` intake, and from nowhere else — never
  /// on a pref write, never on a timer (DM7).
  ///
  /// The arrival gate is the substance of DM7, not bookkeeping. A
  /// reconfiguration event is ALSO what the user changing resolution in System
  /// Settings produces, so a pass that reapplied on every event would undo that
  /// change within a second, permanently, with no way to opt out short of
  /// turning the feature off. Candela's opinion applies when the display
  /// arrives; from then until it leaves, the display belongs to the user.
  ///
  /// Deliberately NOT a preview. Nobody is watching, and a thirty-second
  /// countdown that defaults to revert would undo every remembered mode a
  /// moment after every reconnect — the exact opposite of the feature. It
  /// commits at session scope directly, which is also why it never calls
  /// `ModePreviewSession.begin()`: `begin()` on one display ends an outstanding
  /// preview on ANOTHER, so an unattended caller could reconfigure a display
  /// nobody named.
  ///
  /// Mirror SLAVES are excluded here and only here. The picker still offers them
  /// every mode, because the two paths differ in the one way that matters: a pick
  /// is a person asking for this display by name and getting thirty seconds and
  /// an auto-revert, while this pass asks nobody. Hiding the control instead
  /// would make it vanish and reappear under the user's hands — mirroring is a
  /// hotkey in this very app (`MirroringCoordinator.toggleUnlessSingleDisplay`,
  /// bound to Cmd+BrightnessDown) — to protect them from a
  /// mode change they explicitly requested and can undo by waiting.
  ///
  /// It writes NO preferences — in particular a substitute is never stored over
  /// the user's choice. What they picked is what gets tried again the next time
  /// the display shows up, and a monitor that came back on a reduced link once
  /// does not permanently rewrite their resolution. (Which is also why there is
  /// no `prefDidChange` here: nothing changed.)
  ///
  /// **Awaitable, and its one caller awaits it.** `UnattendedRestoreSequence`
  /// runs this and the arrangement restore as one operation, in this order,
  /// because the two claim the same gate and a refused pass cannot rely on the
  /// winner producing a reconfiguration event — see the comment in
  /// `performReapply` on the refusal, and the type's own documentation.
  func reapplyStoredModes() async {
    let live = configurator.displays()
    // Claiming marks, in one step: the work below is queued and asynchronous,
    // so a second call landing before it finishes must not act on the same
    // arrival twice. A claim that is then deliberately not acted on is given
    // back (`release`), never silently kept.
    let claimed = arrivals.claimArrivals(live: Set(live.map(\.id)))
    let displays = live.filter { claimed.contains($0.id) }
    guard !displays.isEmpty else { return }
    // Through the same queue as every session operation. Reapply does not touch
    // the session, but it does apply modes at SESSION scope — landing that in
    // the middle of a `begin()`/`confirm()` would move a display out from under
    // a preview whose fallback was captured before it.
    await queue.enqueueReturning { await self.performReapply(displays) }
  }

  // MARK: - Reports

  /// The report for a display that is plugged in RIGHT NOW.
  ///
  /// The dictionary is keyed by identity, so this resolves the ID it is given
  /// through the live display list. The emptiness test first is not a
  /// micro-optimisation: without it every sidebar row would pay a CoreGraphics
  /// enumeration per body evaluation for the answer "no", which is the answer
  /// almost always.
  func report(for displayID: CGDirectDisplayID) -> ReapplyReport? {
    guard !reapplyReports.isEmpty, let key = identity(for: displayID)?.key else { return nil }
    return reapplyReports[key]
  }

  func hasUnreadReport(for displayID: CGDirectDisplayID) -> Bool {
    report(for: displayID) != nil
  }

  /// THE one place a person clears a report, whichever surface they clicked OK
  /// in. Keyed rather than taking a display: a surface rendering a report has
  /// the report, so it can only dismiss the one it was showing — an ID would
  /// have to be re-resolved and could resolve to nothing (or, after a replug, to
  /// something else).
  func dismissReport(forKey key: String) {
    reapplyReports[key] = nil
  }

  private func performReapply(_ displays: [ConfiguredDisplay]) async {
    // Unattended, and still a reconfiguration, so AR12 applies to it exactly as
    // it applies to a pick — a stored mode re-asserted in the middle of an
    // arrangement preview changes the very tile sizes that layout was computed
    // from. Refused, every arrival claim goes back: the arrival has not been
    // dealt with, and keeping it would mean "never".
    //
    // Whether anything calls this again is NOT a property of the gate, and this
    // used to claim it was. It holds only for a claimant that holds the gate
    // around an outstanding reconfiguration or preview, because resolving one of
    // those is itself a reconfiguration and produces the event. It does NOT hold
    // for a claimant that decides to apply nothing — which is the arrangement
    // restore's dominant case, and was this pass's too, so the two starved each
    // other. `UnattendedRestoreSequence` is why they no longer race: the layout
    // restore does not run until this pass has finished and released.
    if await gate.claim(.displayModes).refusedBy != nil {
      for display in displays { arrivals.release(display.id) }
      return
    }
    // Asked of the session rather than of `preview`, for the same reason
    // `dropPreviewOnDepartedDisplay` does: the derived copy is nil for several
    // awaits after `begin()` succeeds, and reapplying over a live preview would
    // strand it — the countdown would then "revert" to a mode the display had
    // already left.
    let previewed = await session.previewedMode?.displayID
    if let previewed, displays.contains(where: { $0.id == previewed }) {
      // Skipped because an explicit choice the user is looking at RIGHT NOW
      // outranks one they made some other day — but the claim goes back, so
      // this is "not now" rather than "never". Without the release, a display
      // that happened to be mid-preview when it arrived would go unreapplied
      // for the rest of the connection, which nothing about the skip intends.
      // The retry needs no scheduler of its own: resolving the preview is
      // itself a reconfiguration, and the topology event it produces is what
      // calls this again.
      arrivals.release(previewed)
    }
    for display in displays where display.id != previewed {
      // Synthesis reapply runs AFTER the stored-mode decision for the same
      // display, never beside it: engaging makes the panel a mirror slave, and
      // a stored mode applied to a slave is the case `ModeReapplyPolicy` defers
      // for. The deferral is also why a display that already carries a
      // synthesis set never fights its own remembered resolution.
      guard reapplyStoredMode(for: display) == .done else { continue }
      await reapplySynthesis(for: display)
    }
    // Reapply opens no preview, so the claim it took is spent the moment the
    // loop ends — but it can run while a preview stands on ANOTHER display, and
    // releasing then would free the claim protecting that preview. The session
    // is the authority on whether anything is outstanding; `preview` is not (it
    // is nil for several awaits after a `begin()` succeeds).
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
    // Enumerated for every arrival, including displays that never opted in:
    // the opt-in gate lives inside the tested policy, so the cost of asking
    // is one `CGDisplayCopyAllDisplayModes` per arrival — the same call
    // `warmModeCatalogs` already makes on every menu close.
    let decision = ModeReapplyPolicy.decide(
      isEnabled: persistence.isEnabled(for: identity),
      // Read from the entry the list handed us, not asked again now: the
      // mirror state has to describe the same instant as the enumeration that
      // claimed this arrival.
      isMirroringAnotherDisplay: display.isMirrorSlave,
      stored: stored,
      available: configurator.modes(for: display.id),
      current: configurator.currentMode(for: display.id)
    )
    // "Not now" — a mirror slave, or a display that cannot say what mode it is
    // running. The claim goes back for the same reason it does above: the
    // arrival has not been dealt with, and keeping it would mean "never", since
    // only an observed ABSENCE re-arms one. Mirroring ends and a display wakes
    // through reconfiguration events, and those events are what call this again.
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
        // `apply` throws when staging or completion fails AND when the
        // resolved `CGDisplayMode`'s descriptor does not match the one asked
        // for — a reassigned `ioModeID` now denoting a different mode. On the
        // unattended path that is precisely the failure that must not be
        // swallowed: `try?` here would leave the display on some third mode
        // with the app reporting a successful restore.
        let configError = error as? DisplayConfigError
          ?? DisplayConfigError(cgErrorCode: -1)
        notice = .failed(configError)
      }
      refreshCatalog(for: display.id)
    }

    guard let notice else {
      // Replacement, not a clear-on-departure: this pass has a newer answer
      // for the same identity and the answer is "nothing to say".
      reapplyReports[identity.key] = nil
      return .done
    }
    // A display can leave across the queue wait or across the apply itself.
    // Not because a report about an absent display is now unshowable — SO8
    // keeps those — but because this one describes an attempt that never
    // finished. The claim goes back with it: the arrival was never
    // completed, so its return is an arrival again, and that pass writes a
    // fresh outcome for the same identity in place of this half-answer.
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
  /// Everything the policy needs about the panel comes from THIS pass's
  /// baseline, and the stored descriptor is resolved through
  /// `SyntheticSizeCatalog.size(matching:)` before it goes in: the policy
  /// cannot tell a genuinely stale descriptor from a caller that skipped the
  /// lookup, so it must never be handed an unresolved one.
  private func reapplySynthesis(for display: ConfiguredDisplay) async {
    guard let synthesis, !display.isBuiltIn else { return }
    let modes = configurator.modes(for: display.id)
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

  /// Turning it ON also pins what is on screen now. Without that, the toggle
  /// would store nothing until the next kept change: a control that reads as
  /// broken on the very reconnect it was turned on for. Turning it OFF leaves
  /// the stored mode alone, matching `ModePersistence.clear`'s ruling that
  /// "forget my choice" and "stop remembering" are separate answers, and
  /// keeping the pin intact if the toggle comes back on.
  ///
  /// The seeding is queued and can decline (a preview outstanding on this
  /// display — see `pinCurrentMode`), so turning it on mid-countdown enables
  /// the flag and pins nothing. That is the intended order: the flag is the
  /// user's answer, the pin is a mode, and there is no mode they have accepted
  /// yet. Keeping that preview stores it, because the flag is on by then.
  func setRemembering(_ remembering: Bool, for displayID: CGDirectDisplayID) {
    guard let identity = identity(for: displayID) else { return }
    persistence.setEnabled(remembering, for: identity)
    guard remembering else { return }
    pinCurrentMode(on: displayID)
  }

  /// Pins whatever is on screen now, reached from the Remember toggle's
  /// turn-on seeding and from the hub's `Set to Current`.
  ///
  /// No longer the only route to `store`: a kept preview writes the stored mode
  /// too while the toggle is on, which makes `Set to Current` redundant in the
  /// common case and leaves it as the re-pin for a mode already on screen.
  ///
  /// Queued, and it asks the SESSION whether that display is mid-preview, for
  /// `dropPreviewOnDepartedDisplay`'s reason: `preview` is nil for several
  /// awaits after a `begin()` succeeds, so the main-actor copy would answer
  /// "nothing outstanding" during exactly the window a pin must not be taken
  /// in. A mode still under a countdown is one the user has not accepted — the
  /// countdown may revert it — and pinning it records a choice they never made.
  ///
  /// Silently skipped rather than reported. The UI is expected to disable its
  /// pin control while a preview stands, which leaves a click racing the
  /// countdown as the only way to reach the guard — and a failure notice for a
  /// pin the user can simply take again a second later is noise. The guard does
  /// not depend on that expectation holding; it is what makes it optional.
  ///
  /// Also silent when the display cannot report the mode it is running —
  /// leaving an existing pin alone beats replacing it with a guess.
  func pinCurrentMode(on displayID: CGDirectDisplayID) {
    queue.enqueue {
      guard await self.session.previewedMode?.displayID != displayID else { return }
      // A synthesis-engaged panel reports a SYNTHETIC descriptor: the virtual
      // master's geometry at the panel's own refresh, under a fabricated mode
      // ID that appears in no enumeration [MEASURED 2026-08-17]. Pinning it
      // would store a mode nothing can ever resolve and try to reapply it at
      // every reconnect. The synthesized choice has its own store
      // (`storedSyntheticSize`), written when a synthesis preview is kept.
      guard self.synthesis?.isEngaged(displayID: displayID) != true else { return }
      // Live read FIRST, cache only as the fallback: a countdown expiry
      // reverts on the session actor and enqueues nothing but `adopt(.keep)`,
      // which never refreshes the catalog — so in that window the cache still
      // names the mode that was just reverted away from, while the display has
      // physically changed back.
      guard let identity = self.identity(for: displayID),
            let current = self.configurator.currentMode(for: displayID)
              ?? self.catalogs[displayID]?.current
      else { return }
      self.store(current, on: displayID, for: identity)
    }
  }

  /// The pin as stored, for the row that shows it and for `Set to Current`'s
  /// enabled state. Read-only by design: the writes go through `store`, and they
  /// go through it BECAUSE it announces itself (`didStoreMode`).
  func storedDescriptor(for displayID: CGDirectDisplayID) -> DisplayModeDescriptor? {
    guard let identity = identity(for: displayID) else { return nil }
    return persistence.storedMode(for: identity)
  }

  // MARK: - Preview

  /// Applies `mode` as a preview and starts the countdown.
  ///
  /// Only ever from an explicit choice naming THIS display: `begin()` on a
  /// display other than the one holding an outstanding preview performs a
  /// session-scope apply on that other display, so a speculative call would
  /// reconfigure a display the user never touched.
  ///
  /// Synchronous and fire-and-forget on purpose — the queue owns the ordering,
  /// so no caller can create a second in-flight `begin()` by spawning its own
  /// task.
  ///
  /// `origin` and `surface` are not defaulted: every caller has to say where a
  /// failure is reported and where the answer will be offered, because getting
  /// either wrong is invisible until a countdown expires against nobody. The
  /// settings callers decide `surface` from their own window's key state at the
  /// click (SO6); everything else passes `.floatingPanel`.
  func select(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface
  ) {
    // Raised HERE, synchronously, not inside the queued operation: the whole
    // point is that the banner's buttons are already disabled by the time the
    // reconfiguration starts, so nobody can confirm a mode they are not
    // reading. Counted rather than boolean — two queued selects must not have
    // the first one's completion clear the flag for the second.
    inFlightSelects += 1
    isApplying = true
    queue.enqueue {
      // Routed on PROVENANCE, which is the whole of SS5's routing rule: a
      // synthesized row's sentinel mode ID denotes nothing in either mode-ID
      // space, so there is no configuration transaction that could apply it.
      // The configurator refuses one outright, and that refusal is a tripwire
      // for a bypass rather than a path anything is meant to take.
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
  /// Here rather than at each call site because the settings window now offers
  /// modes from two surfaces — the hub's size pop-up and the full list — and a
  /// guard held in agreement by discipline is the shape this branch has been
  /// bitten by. The menu-bar list keeps its own copy deliberately: it also has
  /// to decide whether to end the menu's tracking session, which is a question
  /// only that surface has.
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
  /// This is what closes the last tail of the concurrency hazard. The button's
  /// action runs one main-actor turn before the queued operation, so a
  /// selection can still land in between — ordering alone cannot stop the
  /// answer from resolving a preview the user never saw. Carrying the intent
  /// makes "an answer only ever resolves the preview it was given for" a
  /// property of the type, and demotes queue ordering to an optimisation.
  @discardableResult
  func confirm(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.performResolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.performResolve(answered, keeping: false) }
  }

  /// Ends any outstanding MODE preview and reports whether the display is back
  /// where it started.
  ///
  /// Called by `MirroringCoordinator` before a mirror ENGAGE preview begins and
  /// before a mirror BREAK applies, and it runs inside THIS coordinator's queue,
  /// so that neither path can open a `CGBeginDisplayConfiguration` transaction
  /// while a mode transaction is still open. The two preview sessions cannot
  /// literally share one task chain — two `@MainActor @Observable` coordinators
  /// cannot without being merged into one object — so the ordering is enforced
  /// by the mirror chain AWAITING this.
  ///
  /// **That orders the mirror side and nothing else.** `select` does not call
  /// the mirror side's equivalent, and the mirror countdown's expiry runs
  /// detached on the session's executor — so concurrent transactions remain
  /// possible in those two directions. Stated rather than implied, because the
  /// narrow guarantee is the one the code delivers.
  ///
  /// A mirror engage would otherwise move a display out from under a preview
  /// whose fallback mode was captured before it — and the mode preview's own
  /// recovery surface would then be on a display that has no `NSScreen`. A break
  /// has no such asymmetry to fix; it comes through for the transaction ordering
  /// alone, and refuses on the same terms rather than inventing a second policy
  /// for the same failure.
  ///
  /// Returns false when the revert FAILED, which is the mirror side's cue to
  /// refuse: the same refusal `ModePreviewSession.begin` already makes across
  /// displays, for the same reason.
  func endOutstandingPreview() async -> Bool {
    await queue.enqueueReturning {
      // BOTH previews, and both are awaited rather than short-circuited: a
      // caller asking every size preview to stand down must not leave one of
      // them standing because the other refused. A synthesized size is a size,
      // so anything that had to end a mode preview has to end this one too.
      let mode = await self.endOutstandingModePreview()
      let synthesized = await self.endOutstandingSynthesisPreview()
      return mode && synthesized
    }
  }

  /// Inside the queue already. Split out of `endOutstandingPreview` because the
  /// select paths call it from inside a queued operation, where re-entering the
  /// queue would wait on the operation doing the waiting.
  private func endOutstandingModePreview() async -> Bool {
    guard let outstanding = await session.previewedMode else { return true }
    // Built FROM the session, so the intent check inside `performResolve`
    // cannot see it as stale: it is by construction the preview that is
    // outstanding. `secondsRemaining: 0` and `isCountingDown: false` are the
    // honest description of an answer nobody waited for.
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
    return await performResolve(answered, keeping: false) == .reverted
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
    return await performResolve(answered, keeping: false) == .reverted
  }

  /// Reconciles both preview sessions and gives the AR12 claim back if nothing
  /// is outstanding.
  ///
  /// **THE release funnel for `.displayModes`, and the reason it is exposed.**
  /// `adopt` is the only releaser (see its comment), which is what keeps a
  /// claim from outliving the thing it protects AND what keeps a claim
  /// protecting a preview from being freed by unrelated work. A claimant that
  /// takes the gate outside a preview — `SynthesisCoordinator`'s opt-out and
  /// its reset paths — therefore gives it back HERE rather than calling
  /// `release` itself: a select granted during their multi-second disengage
  /// (granted because it names the same claimant) would otherwise have its
  /// claim freed underneath it.
  ///
  /// Enters the queue, so it must not be called from inside one of its
  /// operations.
  func releaseReconfigurationClaimIfIdle() async {
    await queue.enqueueReturning { await self.adopt(.keep, synthesis: .keep) }
  }

  /// THE only place `startFailure` is cleared, for the same reason `store` is
  /// the only place a mode is written: the standalone window RENDERS this, so
  /// clearing it and syncing the window are one operation, not two that a
  /// caller is trusted to pair.
  func dismissStartFailure() {
    startFailure = nil
    syncConfirmation()
  }

  // MARK: - Serialisation
  //
  // The queue itself is `PreviewQueue` in CandelaKit (#68): four coordinators
  // held four byte-identical copies of it, and the countdown driver beside it.

  // MARK: - Operations (always inside the queue)

  private func performSelect(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface
  ) async {
    // Recorded here rather than in `select` so they name the preview that is
    // about to become outstanding, not whichever click was most recent: two
    // queued selects from different surfaces each get their own surface as they
    // land, in the order they land. (`surface` was still DECIDED at the click —
    // the caller sampled its window's key state synchronously — this is only
    // where the decision is filed.)
    origins[displayID] = origin
    surfaces[displayID] = surface
    // Sampled here, before `begin()` moves the display, and promoted to
    // `sizeAppliedByUser` only if this preview is KEPT. Every path that reaches
    // here is an explicit choice from an offering surface (the hub's pickers,
    // the full list, the menu bar's list); reapply and restore never preview.
    // An unreadable current mode counts as a size change: this is a user's
    // choice either way, and the recommendation is the thing being answered.
    selectChangesSize[displayID] = configurator.currentMode(for: displayID).map {
      $0.logicalWidth != mode.logicalWidth || $0.logicalHeight != mode.logicalHeight
    } ?? true
    // Through `dismissStartFailure`, never a bare `startFailure = nil`: the
    // standalone window renders the failure, so clearing it without syncing
    // leaves an EMPTY floating panel on the display for the whole duration of
    // the CoreGraphics mode change below, which then pops back as the preview
    // card. Reachable by the obvious retry — fail, reopen the panel, pick again.
    dismissStartFailure()
    // The user has answered the report themselves — whatever reapply could not
    // do for this display, they are now doing by hand. Leaving the notice up
    // would have it contradict the choice they just made. A dismissal, so it
    // goes through the one dismissal path.
    if let key = identity(for: displayID)?.key { dismissReport(forKey: key) }
    // One preview at a time across both size paths (SO6's single answerable
    // surface). `ModePreviewSession.begin` ends an outstanding preview of its
    // OWN on another display; it has never heard of the synthesis session, so
    // this is where the other half is ended. Refused on a failed disengage for
    // `MirroringCoordinator`'s reason: reporting success would leave a panel
    // mirrored onto a virtual display nobody approved.
    //
    // **BEFORE the claim, and the order is the whole point.** Ending a preview
    // runs `adopt`, and `adopt` is the AR12 RELEASER: standing the other
    // preview down after claiming would hand back the claim this operation just
    // took, and the apply below would then run unguarded with nothing left to
    // re-take it. Standing down first costs nothing extra, because a select was
    // going to end the other preview either way, and the claim taken afterwards
    // is then held continuously from here through the countdown's resolution.
    //
    // The refusal is REPORTED by the synthesis coordinator, which recorded the
    // engine's own failure on the way out, rather than as a `StartFailure`
    // here: that surface renders "CoreGraphics error <n>", and the thing that
    // just went wrong was a virtual display refusing to come down.
    guard await endOutstandingSynthesisPreview() else {
      log.error("Refused a mode change on display \(displayID): an outstanding synthesized size could not be disengaged")
      await adopt(.keep)
      return
    }
    // AR12, asked BEFORE `begin()` because that is what makes a refusal cost
    // nothing: no transaction has been opened and no display has moved, so there
    // is a sentence to say and nothing to undo. Granted when WE are already the
    // holder — a select on a second display while one is previewing is a
    // supported operation, and `ModePreviewSession.begin` handles it.
    if let holder = await gate.claim(.displayModes).refusedBy {
      startFailure = StartFailure(displayID: displayID, reason: .blocked(by: holder))
      // Synced by this `adopt`, which must stay immediately after the write —
      // same adjacency rule as the failure branch below.
      await adopt(.clear)
      return
    }
    switch await session.begin(mode: mode, on: displayID) {
    case .success:
      await adopt(.clear)
      startCountdown()
    case let .failure(error):
      // One of the two writes to `startFailure` that are not a clear (the other
      // is the gate refusal above). It is synced by the `adopt` below — which
      // must therefore stay immediately after it, since this is what puts the
      // failure on screen.
      startFailure = StartFailure(displayID: displayID, reason: .failed(error))
      // A begin() that fails may or may not have left something outstanding: it
      // refuses when the previous mode is unreadable (nothing applied), and it
      // also refuses when ending a preview on ANOTHER display failed — in which
      // case that display is still outstanding and this error is about IT.
      // Either way the session decides, and the error attaches only if there is
      // something for it to attach to.
      await adopt(.set(error))
    }
    refreshCatalog(for: displayID)
  }

  /// `performSelect` for a synthesized stop (SS4/SS5): the same recording, the
  /// same gate, the same countdown, a different engine underneath.
  ///
  /// The guards are checked HERE rather than inside the engine because a
  /// refusal has to be a sentence about this display: HDR is on (SS9), the
  /// display is the built-in (SS14), the opt-in is off, or the stop is no
  /// longer one the catalog offers. Their wording is `SynthesisCopy`'s; the
  /// distinction is `SynthesisCoordinator.Refusal.Reason`.
  private func performSynthesisSelect(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID,
    from origin: PreviewOrigin, surface: PreviewSurface
  ) async {
    guard let synthesis,
          let display = configurator.displays().first(where: { $0.id == displayID })
    else { return }
    origins[displayID] = origin
    surfaces[displayID] = surface
    // Sampled BEFORE the engage, while the panel is still showing its own
    // desktop: this is the rate the mirror will preserve, and it is what the
    // confirmation surfaces name. Recorded even if the engage then fails, since
    // it describes the panel rather than the attempt.
    synthesisPreviewRefresh[displayID] = configurator.currentMode(for: displayID)?.refreshHz
    // Every synthesized pick is a size the user chose, so it answers the
    // recommendation the same way a published size does (PD8). Promoted to
    // `sizeAppliedByUser` only if the preview is KEPT.
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
    // The stop is re-found in the ladder this panel generates TODAY rather than
    // taken from the row, so a size the catalog has stopped offering is refused
    // instead of engaged. The row is the user's pointing finger; the catalog is
    // the authority on what it points at.
    guard let size = catalogs[displayID]?.syntheticStops.first(where: {
      $0.logicalWidth == mode.logicalWidth && $0.logicalHeight == mode.logicalHeight
    }) else {
      synthesis.note(.sizeNoLongerOffered, for: displayID)
      // `.keep` for the mode side: this refusal is about a synthesized size on
      // THIS display and says nothing about a preview standing on another one.
      await adopt(.keep, synthesis: .clear)
      return
    }
    // Already on the glass. Re-engaging would tear the pairing down and build a
    // fresh virtual display for the size that is already showing, which is tens
    // of seconds of reconfiguration to arrive back where it started.
    guard synthesis.engagedSize(displayID: displayID) != size else { return }

    // The mode side stands down FIRST, and a failure refuses: an engage would
    // otherwise mirror a panel whose previewed mode nobody has answered yet,
    // and the fallback that preview holds describes a display it no longer
    // owns. The synthesis session ends its OWN outstanding preview inside
    // `begin`, including a cross-display one.
    //
    // **Before the claim**, for the reason `performSelect` states at the same
    // step: ending a preview runs `adopt`, which is the AR12 releaser, so a
    // stand-down after the claim would give back the claim this operation just
    // took. The engine's engage runs for tens of seconds and the preview stands
    // for thirty more, and every second of that has to be guarded.
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
      startSynthesisCountdown()
    case .failure:
      // The refusal was recorded by `beginPreview`, which is the one place both
      // busy shapes collapse into one. Nothing is outstanding on a refusal that
      // reached the engine and failed, so `adopt` releases the gate.
      await adopt(.keep, synthesis: .keep)
    }
    refreshCatalog(for: displayID)
  }

  /// The synthesized stop as a mode a preview surface can name, with the rate
  /// the panel is keeping rather than the catalog row's `refreshHz: 0`
  /// sentinel. See `synthesisPreviewRefresh`.
  ///
  /// The rate is only ever for the label: the answer routes on
  /// `Preview.synthesized`, which carries the whole pairing, so nothing matches
  /// on this value.
  private func synthesizedPreviewRow(
    _ size: SyntheticSize, on displayID: CGDirectDisplayID
  ) -> DisplayMode {
    let row = SyntheticSizeCatalog.row(for: size)
    guard let hz = synthesisPreviewRefresh[displayID] ?? catalogs[displayID]?.current?.refreshHz,
          hz > 0
    else { return row }
    return DisplayMode(
      ioModeID: row.ioModeID,
      logicalWidth: row.logicalWidth, logicalHeight: row.logicalHeight,
      pixelWidth: row.pixelWidth, pixelHeight: row.pixelHeight,
      refreshHz: hz, isNative: false, provenance: .synthesized
    )
  }

  private func performResolve(_ answered: Preview, keeping: Bool) async -> PreviewOutcome {
    if let previewed = answered.synthesized {
      return await performSynthesisResolve(previewed, keeping: keeping)
    }
    let intent = PreviewedMode(displayID: answered.displayID, mode: answered.mode)
    let outcome = keeping ? await session.confirm(intent) : await session.revert(intent)
    switch outcome {
    case .committed:
      // Supersedes SO19/A6: while the Remember toggle is on, the stored mode
      // tracks the resolution the user KEEPS, so remembering means restoring
      // how they left it. Only this branch writes: a reverted or expired
      // preview is a mode nobody accepted and must never become the pin.
      //
      // The guarantee is the FLOW, not the type. This arm keys on the outcome,
      // and `confirm` can return a committed outcome without applying anything
      // when it replays `lastOutcome` for an answer it has already given. That
      // replay re-enters here and rewrites the SAME descriptor, which is what
      // makes keying on the outcome safe rather than merely convenient. Any
      // future path that can reach `.committed` carrying a mode the user did
      // not accept breaks this, so it has to be checked here and not assumed.
      //
      // Deliberately NOT narrowed to size changes the way the recommendation
      // below is. A kept rate-only change is still a kept resolution, and the
      // stored descriptor carries the refresh rate.
      //
      // `answered.mode`, not a live read: `confirm` commits the mode that was
      // PREVIEWED rather than whatever the display reports at confirm time,
      // and it only reaches `.committed` when that apply succeeded and its
      // achieved descriptor matched. Reading live here could store a mode the
      // session deliberately refused to make permanent.
      //
      // In-app changes only, this version. A resolution changed in System
      // Settings does not pass through here and does not move the pin.
      if let identity = identity(for: answered.displayID),
         persistence.isEnabled(for: identity) {
        store(answered.mode, on: answered.displayID, for: identity)
      }
      // The size recommendation IS answered here (PD8): a kept size is the
      // user's answer for this session, and only a kept one, since a revert or
      // an expiry leaves them on the size they were already being asked about.
      if selectChangesSize[answered.displayID] == true {
        sizeAppliedByUser.insert(answered.displayID)
      }
      await adopt(.clear)
    case .reverted:
      await adopt(.clear)
    case let .failed(error):
      await adopt(.set(error))
    case .stale:
      // Nothing was resolved: the outstanding preview is not the one this
      // answer was about. Re-read, and keep whatever failure is on screen —
      // it belongs to the preview that is still there, not to this answer.
      await adopt(.keep)
    }
    refreshCatalog(for: answered.displayID)
    return outcome
  }

  /// The synthesized half of `performResolve`.
  ///
  /// **The mapped return value is deliberately coarse.** `PreviewOutcome` is
  /// the mode session's vocabulary and its failure case carries a
  /// `DisplayConfigError`; no synthesis failure has a CGError behind it, and
  /// fabricating one would put "CoreGraphics error 0" in front of a person
  /// whose virtual display would not come down. So everything that resolved
  /// NOTHING maps to `.stale`, which is exactly what the one caller that reads
  /// this (`endOutstandingPreview`) needs: it refuses unless the panel is back.
  /// The detail lives on the preview (`synthesisFailure`) and on
  /// `SynthesisCoordinator.refusal`, where `SynthesisCopy` can render it.
  private func performSynthesisResolve(
    _ previewed: PreviewedSynthesis, keeping: Bool
  ) async -> PreviewOutcome {
    guard let synthesis else { return .stale }
    // A confirm that follows a FAILED revert can hand back the identical
    // retained pairing, because the engine keeps a pairing whose teardown did
    // not finish. That is the one path where `.committed` is not evidence of a
    // healthy set, so it is sampled BEFORE the answer rather than inferred from
    // it afterwards.
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
      // SS11's ordering: the engage landed and was verified, the user kept it,
      // and only now is anything written. A revert or an expiry persists
      // nothing, which is why only this arm stores.
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
      // Surfaced, never swallowed: `.unwindIncomplete` means a virtual display,
      // a mirror set, or both are still standing, and `revert()` is a live
      // retry for exactly as long as the preview stays outstanding.
      await adopt(.keep, synthesis: .set(failure))
      refreshCatalog(for: previewed.physicalDisplayID)
      return .stale
    case .stale, .busy:
      // Neither resolved anything. They differ in whether repeating helps, and
      // that difference is already recorded as a refusal.
      await adopt(.keep, synthesis: .keep)
      return .stale
    }
  }

  /// Ends an outstanding preview whose display has gone.
  ///
  /// Asks the SESSION which display is outstanding, and re-reads the live list
  /// inside the queue. Gating on `preview?.displayID` instead — the derived
  /// copy — leaves a hole: between `begin()` succeeding and `adopt()` finishing
  /// there are three awaits during which `preview` is still nil while the
  /// session is outstanding, so a departure landing in that window would be
  /// skipped, the countdown would expire onto a dead display, and the session
  /// would wedge. That is the exact case this exists to prevent, so it must not
  /// consult the copy.
  private func dropPreviewOnDepartedDisplay() {
    queue.enqueue {
      guard let outstanding = await self.session.previewedMode else { return }
      let stillHere = self.configurator.displays().contains { $0.id == outstanding.displayID }
      guard !stillHere else { return }
      await self.session.discard(displayID: outstanding.displayID)
      await self.adopt(.clear)
    }
  }

  /// Rebuilds the UI's picture of the preview from the session. THE only writer
  /// of `preview`, so no path can leave the two disagreeing — including a
  /// countdown tick that resumes late, which reconciles here instead of being
  /// discarded. A discarded outcome is exactly how a preview with a disarmed
  /// countdown and no driver gets created.
  private func adopt(
    _ failure: FailureUpdate, synthesis synthesisFailure: SynthesisFailureUpdate = .keep
  ) async {
    // The synthesis session is asked FIRST, and the two can never both be
    // outstanding: every path that starts one ends the other and refuses if it
    // could not. Asking in a fixed order is what makes that invariant visible
    // rather than merely true.
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
        // The row rather than the size, so every surface that draws a preview
        // keeps drawing one thing: a mode, a countdown and two buttons.
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
      // THE release (AR12), and it is here rather than at each call site on
      // purpose: this funnel already runs after every path that can end a
      // preview — a failed `begin`, a commit, a revert, an expiry, and a display
      // departing with nobody watching — so a claim cannot outlive the thing it
      // was protecting. Unconditional, because the gate refuses a release from a
      // claimant that is not holding it.
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
  /// It reads TWO pieces of state — `preview` and `startFailure` — so it has
  /// two callers, not one: `adopt` (the sole writer of `preview`) and
  /// `dismissStartFailure` (the sole writer of the CLEAR of `startFailure`).
  /// The one non-clear write to `startFailure` is the bare assignment in
  /// `performSelect`, which is synced by the `adopt(.set(error))` that must stay
  /// immediately after it — by adjacency, not by a funnel. Every write to either
  /// has to be followed by this call. An un-synced write does not merely leave
  /// the window stale — it leaves it rendering a state that no longer exists,
  /// i.e. an empty floating panel.
  ///
  /// Called on every countdown tick, so the presenter must treat a repeat
  /// present of unchanged content as a no-op.
  private func syncConfirmation() {
    // A preview outranks a start failure: it has a countdown and a screen at
    // stake, and the failure is still on the panel's own row when it reopens.
    // (They can only coexist on DIFFERENT displays — `performSelect` clears the
    // failure before it begins.)
    //
    // **The preview's own `surface` decides this window (SO6), fixed at
    // start.** The floating window is the default owner — macOS puts this
    // question in a dialog on the display it is about, and so do we for the
    // panel and every other origin. The settings banner owns the answer only
    // when the change came from a key settings window: the user is already
    // reading that window, and two button rows asking one question is the
    // two-surfaces defect #54 exists to prevent. When the banner owns, this
    // window does not show — the banner region renders the buttons and the
    // hub's other renderings are passive text.
    //
    // Known residue, accepted with SO6: nothing keeps the owning banner on
    // screen, and ownership does not migrate mid-preview. The banner region
    // renders only on the preview's own display destination, so SWITCHING THE
    // SIDEBAR — to another display, General, or the built-in — hides the
    // answerable surface with the window still open and key; closing the
    // window (⌘W) does the same. An armed countdown survives both — expiry
    // reverts unattended. A failed EXPIRY in that state leaves the answer
    // only on the owning banner until the user navigates back to that
    // display's destination (or reopens the window), which is also the
    // recovery: the banner is still there, buttons live.
    if let preview {
      switch preview.surface {
      case .floatingPanel:
        confirmation?.presentConfirmation(.preview(preview.displayID))
      case .settingsBanner:
        confirmation?.dismissConfirmation()
      }
      return
    }
    // A failed `begin()` produces no preview, so without this a panel selection
    // that fails would report nothing at all: the menu closes on selection now,
    // taking the panel's own banner with it, and the screen does not change
    // either. Silence on the quick path reads as the feature being broken.
    if let startFailure, origins[startFailure.displayID] == .panel {
      confirmation?.presentConfirmation(.startFailure(startFailure.displayID))
      return
    }
    confirmation?.dismissConfirmation()
  }

  /// The countdown driver.
  ///
  /// Detached, and its main-actor hop is fire-and-forget. Both halves matter:
  /// the tick and the revert it triggers run on the session's executor, and the
  /// loop's next `sleep`/`tick()` is never gated on the main actor having run
  /// the previous UI update. A main thread wedged by a synchronous
  /// reconfiguration callback or by blocking work in a pane must not be able to
  /// stop the expiry — the expiry is what rescues a screen nobody can read.
  private func startCountdown() {
    let session = session
    countdown.start(tick: { await session.tick() }) { [weak self] outcome in
      guard let self else { return }
      // Through the queue, never straight to `adopt`: a tick that landed
      // mid-apply would otherwise publish a picture the apply is about to
      // replace.
      if case let .failed(error) = outcome {
        queue.enqueue { await self.adopt(.set(error)) }
      } else {
        queue.enqueue { await self.adopt(.keep) }
      }
    }
  }

  /// The same clock for a synthesized size, and the same two properties that
  /// make it safe.
  ///
  /// The tick reaches the SESSION ACTOR directly rather than
  /// `SynthesisCoordinator`, which is main-actor isolated: routing it through
  /// that object would put a wedged main thread back on the expiry's critical
  /// path, and the expiry is what takes down a virtual display nobody answered
  /// for. One driver serves both preview kinds because only one preview can be
  /// outstanding at a time.
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
    // Sampled BEFORE the reconciliation, which is what resolves the preview
    // away: afterwards there is nothing left to name the display the expiry
    // was about.
    let displayID = preview?.displayID
    // The clock resolved the preview on the session's own executor, so the
    // pairing snapshot and the refusal state have to catch up before anything
    // is rebuilt from them.
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
  /// Private, with exactly two callers: `pinCurrentMode` (the explicit pin and
  /// the toggle-on seeding) and the kept-preview branch of `performResolve`.
  private func store(
    _ mode: DisplayMode, on displayID: CGDirectDisplayID, for identity: DisplayConfigIdentity
  ) {
    persistence.store(mode.descriptor, for: identity)
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
/// Two cases, not one, because the two outcomes of a panel selection are
/// genuinely different: a preview is a question with a countdown behind it, and
/// a start failure is a statement with nothing outstanding. They also arrive in
/// either order, so the presenter has to be able to tell that its content
/// CHANGED for the same display — a display ID alone cannot say that.
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
/// started it. Declared beside the coordinator, and AppKit-free, so the contract
/// belongs to the thing that needs it — the window that implements it is an
/// app-target island like every other.
@MainActor
protocol ModeConfirmationPresenting: AnyObject {
  /// Must be idempotent for unchanged content: called again on every countdown
  /// tick.
  func presentConfirmation(_ content: ModeConfirmationContent)
  func dismissConfirmation()
}

extension DisplayModeCoordinator.Catalog {
  /// The words that name one mode of THIS panel: the same logical size is
  /// native on one display and an oversized render on another.
  ///
  /// **RM11 rests on this now.** The size label used to hedge ("Looks like
  /// 2560 × 1440") because a bare size can be read as a claim that the panel
  /// really is that many pixels. The hedge is gone; these words carry the
  /// claim instead, so every surface that offers a size has to wear them, and
  /// they have to be computed in ONE place: three private copies is how the
  /// rule drifts.
  ///
  /// Words, not a formatted string: a popup item is a single label and
  /// parenthesises them, a two-column row separates them with a dot. The words
  /// are the statement; the punctuation is layout.
  ///
  /// SO14 retires "HiDPI" from copy, and this is the one place it was still
  /// said (the menu-bar list, left alone by the settings overhaul and tracked
  /// as #96 rather than blessed). The inversion is macOS's own: the sharp mode
  /// says nothing, and the 1x duplicate it used to be distinguished FROM
  /// carries "low resolution" instead.
  ///
  /// `isLowResolutionDuplicate` is asked of `DisplayModeCatalog`, once per
  /// catalog rather than once per row: the answer depends on the mode's
  /// siblings at the same logical size, and the full list renders hundreds of
  /// rows. Curated surfaces pass `false`; see `badgedSize`.
  ///
  /// "Scaled" is suppressed rather than guessed when the panel's native size is
  /// unknown, and is never said about the native mode itself.
  func tags(for mode: DisplayMode, isLowResolutionDuplicate: Bool) -> [String] {
    var tags: [String] = []
    if mode.isNative { tags.append("Native") }
    if isScaled(mode) { tags.append("Scaled") }
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
  /// `isLowResolutionDuplicate: false`, deliberately and for the same reason
  /// the Recommended list passes it (`AllModesPage.recommendedRow`): its caller
  /// renders the CURATED list, one row per logical size, and a curated row is a
  /// 1x mode with a sharp twin only when that mode is the panel's NATIVE one
  /// (`representativeRanking` rule 1 outranks rule 2). Tagging a display's own
  /// native resolution "low resolution" would be an insult rather than a
  /// distinction, and the twin is not on screen here to be distinguished from.
  ///
  /// The density model's mark rides along, in the SAME bracket as the tags.
  /// Its caller draws one string on one line, so a mark of its own would be a
  /// second pair of brackets on a 280 pt row; and the marks a settings row can
  /// afford to separate ("Added by Candela") are the ones that stayed in
  /// Settings anyway.
  func badgedSize(_ mode: DisplayMode) -> String {
    var marks = tags(for: mode, isLowResolutionDuplicate: false)
    if isRecommendedSize(mode) { marks.append(DisplayModeCopy.recommended) }
    guard !marks.isEmpty else { return DisplayModeCopy.size(mode) }
    return "\(DisplayModeCopy.size(mode)) (\(marks.joined(separator: ", ")))"
  }

  /// The mode to apply for a curated row: the chosen SIZE at the refresh rate
  /// the display is already running, when that size offers it.
  ///
  /// A size change should not silently move someone from 60 Hz to 175 Hz, and
  /// the curated row carries the size's FASTEST rate as its representative, so
  /// taking the row's own mode would do exactly that.
  ///
  /// `ModePersistence.resolve` is the tested answer to this question (geometry
  /// + desired refresh → best live mode, deterministic down to `ioModeID`), so
  /// the rule is not re-invented in a view. Its cross-size fallbacks cannot
  /// help here — the row came from the live list — so a resolved mode at a
  /// different size is rejected in favour of the row's own representative.
  ///
  /// Lives here rather than in either view because the panel and the settings
  /// pane must apply the same rule; two copies would differ the first time one
  /// was touched.
  func modeKeepingCurrentRefreshRate(for row: DisplayModeRow) -> DisplayMode {
    // A synthesized row carries the `refreshHz: 0` sentinel and has no rate to
    // keep: the mirror preserves the PANEL's refresh, whatever it is running
    // [MEASURED 2026-08-17]. Resolving it against the live list would match on
    // geometry the panel does not publish, or on nothing.
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
  /// readback is not consulted at all.** A mirrored panel reports the virtual
  /// master's geometry under a fabricated mode ID that appears in no
  /// enumeration [MEASURED 2026-08-17], so matching against it would tick a
  /// published row that is not what is on the glass. The engaged stop is the
  /// only row that can be current then, and no published row can be.
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
  /// A size match, the same rule `isCurrentSize` and the hub's
  /// `curatedSelection` follow, because a recommendation IS a logical size:
  /// `SizeRecommendation` carries no `ioModeID` precisely so that mode-id
  /// instability can never reach it, and a curated row's representative mode is
  /// its size's fastest rate.
  ///
  /// Reads `bestInBand` rather than `recommendation`, so the mark persists
  /// while the display is already running the recommended size: a mark is an
  /// endorsement, and the endorsement is still true once the suggestion has
  /// nothing left to suggest. The callout keys to `recommendation` and so still
  /// hides on every abstention. False whenever there is no verdict or nothing
  /// applicable reached the band. Three offering surfaces ask this question,
  /// and one helper is the only way they keep answering it the same way.
  func isRecommendedSize(_ mode: DisplayMode) -> Bool {
    guard let recommendation = density?.bestInBand else { return false }
    return recommendation.logicalWidth == mode.logicalWidth
      && recommendation.logicalHeight == mode.logicalHeight
  }
}
