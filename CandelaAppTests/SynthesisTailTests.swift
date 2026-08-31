import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The engage tail and the coordinator decisions around a synthesized size,
/// host-free, over `SynthesisFixture`'s real coordinators and real engine.
///
/// The seams that make these paths reachable are the injected bounce durations,
/// the recorded mode applies, and the scriptable HDR seam.
@Suite("Synthesized sizes: the engage tail and its fallout") @MainActor
struct SynthesisTailTests {
  private typealias Fixture = SynthesisFixture
  private static let panelID = SynthesisFixture.panelID

  private func firstStop(_ fixture: Fixture) throws -> SyntheticSize {
    try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)
  }

  private func nativeRow(_ fixture: Fixture) throws -> DisplayMode {
    try #require(fixture.modes.catalogs[Self.panelID]?.all.first { $0.isNative })
  }

  // MARK: - The engage tail

  /// The re-time is what keeps the display on its own timing, so it runs once,
  /// after the mirror stood.
  @Test func aLandedEngageRetimesTheDisplayOntoItsOwnMode() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let ownMode = try nativeRow(fixture)

    _ = await fixture.synthesis.engage(stop, on: display)

    let applies = fixture.configurator.applies
    #expect(applies.count == 1, "one re-time per engage, and only after it landed")
    #expect(applies.first?.displayID == Self.panelID)
    #expect(applies.first?.mode.logicalWidth == ownMode.logicalWidth)
    #expect(applies.first?.mode.refreshHz == ownMode.refreshHz)
  }

  /// A refused mirror must not leave a mode apply behind on a display it never moved.
  @Test func aFailedEngageAppliesNoMode() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesMirroring = true

    let result = await fixture.synthesis.engage(stop, on: display)

    #expect(result.isFailure)
    #expect(fixture.configurator.applies.isEmpty)
  }

  /// The bounce is the fallback, so it runs exactly when the re-time did not.
  @Test func aRefusedRetimeFallsThroughToTheHDRRoundTrip() async throws {
    let hdr = FakeSynthesisHDR()
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.map(\.enabled) == [true, false])
    #expect(hdr.leftStanding.isEmpty)
  }

  /// Nothing to renegotiate through, and an HDR write to a display that has none
  /// is a write nobody can predict.
  @Test func aDisplayWithoutHDRIsNeverBounced() async throws {
    let hdr = FakeSynthesisHDR(supports: false)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.isEmpty)
  }

  /// The guard is read AFTER the settle, so a state that changed while the engage
  /// was landing is the one this decides from.
  @Test func aBounceStandsDownWhenHDRIsAlreadyLive() async throws {
    let hdr = FakeSynthesisHDR(live: true)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.isEmpty, "an HDR state somebody else set is not this feature's to end")
  }

  /// `.unknown` means a transition raced the read, and deciding from it is the
  /// mistake the measured-read rule exists to stop.
  @Test func aBounceStandsDownWhenNobodyVouchesForTheHDRState() async throws {
    let hdr = FakeSynthesisHDR(live: nil)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.isEmpty)
  }

  /// The on leg reports ACHIEVED, not issued. A false from the seam means either
  /// the display measured the other way or a newer transition superseded the call,
  /// so reading it as "HDR never came on" can leave HDR standing, and the only
  /// symptom is brightness and volume quietly not working.
  @Test func anAbandonedOnLegStillStandsTheOffLegDown() async throws {
    let hdr = FakeSynthesisHDR(achievesOn: false)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.map(\.enabled) == [true, true, true, false], "three tries, then it makes sure")
    #expect(hdr.leftStanding.isEmpty, "and the off leg took, so nothing is standing")
  }

  /// HDR left standing kills DDC, so it has to reach a person whichever leg failed.
  @Test func anAbandonedOnLegThatCannotBeStoodDownIsReported() async throws {
    let hdr = FakeSynthesisHDR(achievesOn: false, achievesOff: false)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.filter { $0.enabled == false }.count == 3)
    #expect(hdr.leftStanding == [Self.panelID])
  }

  /// The display measured out of HDR, so there is nothing to stand down. The fresh
  /// read before the off leg is the last chance not to reach into a state this
  /// feature did not create.
  @Test func anOnLegThatWasNeverIssuedSkipsTheOffWriteEntirely() async throws {
    let hdr = FakeSynthesisHDR(achievesOn: false, stateAfterFailedOn: false)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.map(\.enabled) == [true, true, true], "no off write over a display already out")
    #expect(hdr.leftStanding.isEmpty)
  }

  /// HDR left standing kills DDC to the display, so the off leg is retried and then
  /// reported where a person can read it. A log line is not a recovery path.
  @Test func anOffLegThatNeverTakesIsReportedAndNotSwallowed() async throws {
    let hdr = FakeSynthesisHDR(achievesOff: false)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.filter { $0.enabled == false }.count == 3)
    // Asserted at the seam because the seam is built before the coordinator it
    // reports to, so a fixture cannot hold both ends of that join.
    #expect(hdr.leftStanding == [Self.panelID])
  }

  // MARK: - What the surfaces read

  /// SS1 over the readback. The re-time leaves `current` naming a real published
  /// row, so every "what is running" reader goes through `onScreen` and every no-op
  /// guard sees nil.
  @Test func theOnScreenSizeIsTheStopRatherThanTheReadback() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)

    let before = try #require(fixture.modes.catalogs[Self.panelID])
    #expect(before.onScreen?.logicalWidth == Fixture.nativeWidth)
    #expect(before.alreadyOnScreenModeID == before.current?.ioModeID)

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.modes.refreshCatalog(for: Self.panelID)

    let after = try #require(fixture.modes.catalogs[Self.panelID])
    #expect(after.engagedSyntheticSize == stop)
    #expect(after.onScreen?.logicalWidth == stop.logicalWidth)
    #expect(after.onScreen?.logicalHeight == stop.logicalHeight)
    #expect(after.onScreen?.isSynthesized == true)
    // A label with no rate on it would read as the feature having taken the rate away.
    #expect(after.onScreen?.refreshHz == Fixture.nativeHz)
    // nil, so picking the native size is a real change rather than a silent no-op.
    #expect(after.alreadyOnScreenModeID == nil)
  }

  /// A catalog pass at the one instant that poisons the ladder: the mirror stands,
  /// the pairing snapshot is still empty (so `isEngaged` reads FALSE and the
  /// baseline lookup skips its cache shortcut), and the world is already publishing
  /// the master's twins. A pass after the engage returns cannot reach that guard.
  ///
  /// Drop `!unstable` from the guard and the poisoned baseline replaces the good
  /// one, taking the ladder, the native pixels and the engaged row with it.
  @Test func aCatalogRefreshInsideTheEngageWindowKeepsTheLadder() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    fixture.world.publishesMasterTwinsWhileMirrored = true
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let stopsBefore = fixture.modes.catalogs[Self.panelID]?.syntheticStops ?? []
    #expect(!stopsBefore.isEmpty, "the fixture's own control")

    // Runs on the engine's executor with the mirror standing. Hopping to the main
    // actor and BLOCKING there is what lands the pass inside the window.
    let refreshed = DispatchSemaphore(value: 0)
    fixture.configurator.onMirrorApplied = { [modes = fixture.modes, synthesis = fixture.synthesis] in
      Task { @MainActor in
        // The state under test, asserted rather than assumed.
        #expect(synthesis.pairings.isEmpty, "the snapshot is empty for the whole engage")
        #expect(synthesis.baselineUnstable(displayID: Self.panelID))
        modes.refreshCatalog(for: Self.panelID)
        refreshed.signal()
      }
      _ = refreshed.wait(timeout: .now() + 5)
    }

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.modes.refreshCatalog(for: Self.panelID)

    let catalog = try #require(fixture.modes.catalogs[Self.panelID])
    #expect(catalog.syntheticStops == stopsBefore, "the ladder is the panel's, not the master's")
    #expect(catalog.nativePixels?.width == Fixture.nativeWidth)
    #expect(
      catalog.rows.contains { catalog.isCurrentSize($0.mode) },
      "the engaged stop must still be a row somebody can see it ticked in"
    )
  }

  /// A pass that runs while the baseline is untrustworthy stores NOTHING, even when
  /// nothing is cached yet. A `|| baselines[key] == nil` escape would make the
  /// poison PERMANENT: it becomes the cached answer, `isEngaged` short-circuits to
  /// it for the rest of the set's life, and nothing recovers once the world stops
  /// lying. Driven here as first sight inside the mirror window, the OS list
  /// settling back, then a second pass.
  @Test func anUnstableFirstPassCachesNothing() async throws {
    let fixture = Fixture(enumerateOnInit: false)
    defer { fixture.forgetPrefs() }
    fixture.world.publishesMasterTwinsWhileMirrored = true
    let display = try fixture.configured(Self.panelID)
    let stop = try #require(SyntheticSizeCatalog.stops(
      nativeLogicalWidth: Fixture.nativeWidth, nativeLogicalHeight: Fixture.nativeHeight,
      existingRows: fixture.world.modes(for: Self.panelID),
      ceilingPixelWidth: VirtualDisplayIdentity.maxPixels.wide,
      ceilingPixelHeight: VirtualDisplayIdentity.maxPixels.high
    ).first)

    let refreshed = DispatchSemaphore(value: 0)
    fixture.configurator.onMirrorApplied = { [modes = fixture.modes] in
      Task { @MainActor in
        // FIRST sight for this identity, inside the window.
        modes.refreshCatalog(for: Self.panelID)
        refreshed.signal()
      }
      _ = refreshed.wait(timeout: .now() + 5)
    }

    _ = await fixture.synthesis.engage(stop, on: display)
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))

    // The OS list settles back to the panel's own while the set still stands.
    fixture.world.publishesMasterTwinsWhileMirrored = false
    fixture.modes.refreshCatalog(for: Self.panelID)

    let catalog = try #require(fixture.modes.catalogs[Self.panelID])
    #expect(catalog.nativePixels?.width == Fixture.nativeWidth)
    #expect(!catalog.syntheticStops.isEmpty)
    #expect(catalog.rows.contains { catalog.isCurrentSize($0.mode) })
  }

  /// The native flag rides the HiDPI twin, so a ladder taken from the RAW list
  /// computes from half the real logical size and every stop falls under the
  /// minor-axis floor. The catalog is sorted first.
  @Test func aNativeFlaggedHiDPITwinDoesNotSuppressTheLadder() {
    let fixture = Fixture(nativeRidesTheHiDPITwin: true)
    defer { fixture.forgetPrefs() }

    let catalog = fixture.modes.catalogs[Self.panelID]
    #expect(catalog?.syntheticStops.isEmpty == false)
  }

  // MARK: - An ordinary size over a committed set

  /// SS10 through the picker: the set comes down through the engine before any mode
  /// touches the display, and the gate comes back afterwards.
  @Test func anOrdinaryPickOverACommittedSetTakesTheSetDown() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let smaller = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.logicalWidth == 2560 })

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.synthesis.persist(
      SynthesisPairing(
        physicalDisplayID: Self.panelID, physicalIdentityKey: display.identity.key,
        virtualDisplayID: 91, slot: 4, size: stop
      ),
      unwindWasIncomplete: false
    )
    #expect(fixture.prefs.storedSyntheticSize != nil, "the fixture's own control")
    fixture.modes.refreshCatalog(for: Self.panelID)

    fixture.modes.select(smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()

    #expect(fixture.synthesis.pairings.isEmpty, "the set comes down before the mode is applied")
    // A null-master change is the break.
    #expect(
      fixture.world.mirrorChanges.contains { changes in
        changes.contains { $0.display == Self.panelID && $0.master == kCGNullDirectDisplay }
      })

    // Cleared with Remember OFF, the shipped default: the two prefs are unrelated
    // and neither may gate the other. Left standing, the next launch would re-engage
    // the stop over the size the person just confirmed.
    #expect(!fixture.modes.isRemembering(Self.panelID), "the fixture's own control")
    if let preview = fixture.modes.preview { _ = await fixture.modes.confirm(preview) }
    await fixture.settle()
    #expect(fixture.prefs.storedSyntheticSize == nil)
  }

  /// The teardown is irreversible and happens BEFORE the reversible preview, so
  /// Revert returns the person to the synthesized size they were looking at when
  /// they picked, not the desktop the display had before it was ever engaged.
  @Test func revertingAnOrdinaryPickPutsTheSynthesizedSizeBack() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let smaller = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.logicalWidth == 2560 })

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.modes.refreshCatalog(for: Self.panelID)

    fixture.modes.select(smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()
    #expect(fixture.synthesis.pairings.isEmpty, "the pick really did take the set down")

    let preview = try #require(fixture.modes.preview)
    _ = await fixture.modes.revert(preview)
    await fixture.settle()

    #expect(fixture.synthesis.engagedSize(displayID: Self.panelID) == stop)
    let gate = await fixture.gate.claim(.mirroring)
    #expect(gate.isGranted, "and the claim is not left held by the restore")
    await fixture.gate.release(.mirroring)
    await fixture.revertAnyPreview()
  }

  /// A STAND-DOWN is not an answer, and it must not restore.
  ///
  /// `endOutstandingPreview` yields the same `.reverted` outcome a person's Revert
  /// does, but every caller of it is about to reconfigure these displays itself, and
  /// `SynthesisCoordinator.engage` takes no claim of its own. Restoring there is
  /// tens of seconds of reconfiguration inside somebody else's operation, and on the
  /// mirror path it mirrors the user's topology onto a display this app just made a
  /// synthesis slave.
  ///
  /// The stash is CONSUMED rather than dropped, so the stored stop cannot re-engage
  /// at the next launch behind a person looking at something else.
  @Test func aStandDownConsumesTheRestoreWithoutPerformingIt() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let smaller = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.logicalWidth == 2560 })

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.synthesis.persist(
      SynthesisPairing(
        physicalDisplayID: Self.panelID, physicalIdentityKey: display.identity.key,
        virtualDisplayID: 91, slot: 4, size: stop
      ),
      unwindWasIncomplete: false
    )
    fixture.modes.refreshCatalog(for: Self.panelID)
    fixture.modes.select(smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()
    #expect(fixture.synthesis.pairings.isEmpty, "the pick took the set down")
    #expect(fixture.modes.preview != nil, "and a countdown is standing over it")

    // Exactly what `MirroringCoordinator` awaits before its own apply.
    let stoodDown = await fixture.modes.endOutstandingPreview()

    #expect(stoodDown)
    #expect(fixture.synthesis.pairings.isEmpty, "no virtual display stood up inside the stand-down")
    #expect(fixture.host.live().isEmpty)
    #expect(fixture.prefs.storedSyntheticSize == nil, "the stash was consumed, not merely dropped")
    #expect(fixture.synthesis.refusal?.reason == .restoreSuperseded)
  }

  /// Pick A's preview resolves inside `ModePreviewSession.begin`'s revert-first,
  /// which reaches no arm here, so a bare drop leaves the pref naming a size that
  /// will not be on the glass under either outcome.
  @Test func aSupersedingPickConsumesTheStashSoNothingReEngagesLater() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let catalog = try #require(fixture.modes.catalogs[Self.panelID])
    let pickA = try #require(catalog.all.first { $0.logicalWidth == 2560 })

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.synthesis.persist(
      SynthesisPairing(
        physicalDisplayID: Self.panelID, physicalIdentityKey: display.identity.key,
        virtualDisplayID: 91, slot: 4, size: stop
      ),
      unwindWasIncomplete: false
    )
    fixture.modes.refreshCatalog(for: Self.panelID)
    fixture.modes.select(pickA, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()
    #expect(fixture.prefs.storedSyntheticSize != nil, "the control: the pref still names the stop")

    let pickB = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.isNative })
    fixture.modes.select(pickB, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()

    #expect(fixture.prefs.storedSyntheticSize == nil)
    await fixture.revertAnyPreview()
    await fixture.settle()
    #expect(fixture.synthesis.pairings.isEmpty, "and nothing re-engages behind the second pick")
  }

  /// The restore re-validates against the ladder this display generates NOW. The
  /// refusal guard has no `sizeNoLongerOffered` arm because that answer belongs to
  /// the catalog lookup the restore would otherwise bypass, and a countdown is long
  /// enough for a rotation to regenerate the ladder under a captured stop.
  @Test func aRestoreRefusesAStopTheLadderNoLongerOffers() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let smaller = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.logicalWidth == 2560 })

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.modes.refreshCatalog(for: Self.panelID)
    fixture.modes.select(smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()

    // The ladder regenerates from a different native geometry, the way a rotation
    // makes it.
    let rotated = DisplayMode(
      ioModeID: 11, logicalWidth: 1920, logicalHeight: 1080,
      pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60, isNative: true
    )
    fixture.world.attach(
      display, modes: [rotated], current: rotated,
      nativePixels: (width: 1920, height: 1080)
    )
    fixture.modes.refreshCatalog(for: Self.panelID)
    #expect(
      fixture.modes.catalogs[Self.panelID]?.syntheticStops.contains(stop) == false,
      "the control: the captured stop is not in the ladder any more")

    let preview = try #require(fixture.modes.preview)
    _ = await fixture.modes.revert(preview)
    await fixture.settle()

    #expect(fixture.synthesis.pairings.isEmpty, "nothing was engaged")
    #expect(fixture.synthesis.refusal?.reason == .sizeNoLongerOffered)
    #expect(fixture.prefs.storedSyntheticSize == nil, "and the pref cannot outlive the ladder")
  }

  /// A hang can only be asserted as its absence: the select RETURNS and the gate is
  /// free afterwards. Both entry points the teardown needs re-enter the coordinator's
  /// queue, so a teardown that took them from inside it waited on itself and every
  /// later pick enqueued forever.
  @Test func anOrdinaryPickOverACommittedSetDoesNotWedgeTheQueue() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let smaller = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.logicalWidth == 2560 })
    // The app's wiring, and the half that would hang: both closures enter this
    // coordinator's queue.
    fixture.synthesis.endOutstandingPreview = { [modes = fixture.modes] in
      await modes.endOutstandingPreview()
    }
    fixture.synthesis.releaseClaimIfIdle = { [modes = fixture.modes] in
      await modes.releaseReconfigurationClaimIfIdle()
    }

    _ = await fixture.synthesis.engage(stop, on: display)
    fixture.modes.refreshCatalog(for: Self.panelID)

    fixture.modes.select(smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    await fixture.settle()

    #expect(!fixture.modes.isApplying, "the select returned rather than parking on itself")
    await fixture.revertAnyPreview()
    await fixture.settle()
    let afterwards = await fixture.gate.claim(.mirroring)
    #expect(afterwards.isGranted, "and a second claimant is granted the gate")
    await fixture.gate.release(.mirroring)
  }
}

/// The launch-ordering join the synthesis prefs hang off, in `AppModel`'s
/// `persistenceKey` closure.
///
/// The unattended reapply pass can run before the first controller build populates
/// `allControlledStates`. A nil answer there reads as "not opted in" and silently
/// drops the relaunch restore, so the closure falls back to discovery and MEMOIZES
/// it: the walk is a full IOKit service iteration on the main actor, reached from
/// every catalog refresh and every Diagnostics render.
@Suite("The persistence-key join at launch") @MainActor
struct SynthesisPersistenceKeyTests {
  /// Counts its own calls, so the memo is observable behaviour rather than an
  /// implementation detail.
  private final class CountingDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func discover(_: Set<CGDirectDisplayID>) -> AppModel.DiscoveredDisplays {
      lock.withLock { _calls += 1 }
      return [(
        display: ExternalDisplay(id: 2, name: "MAG341C", persistenceKey: "3669-key"),
        writer: FakeDDCWriter(),
        // Nothing here reads the facts: the join under test is the key alone.
        facts: DisplayHardwareFacts(
          transportUpstream: nil, transportDownstream: nil, manufacturerID: nil,
          alphanumericSerialNumber: nil, numericSerialNumber: nil,
          physicalWidthCm: nil, physicalHeightCm: nil, ioDisplayLocation: nil,
          ioregMatchScore: 0)
      )]
    }
  }

  @Test func theKeyResolvesBeforeAnyControllerIsBuilt() {
    let discovery = CountingDiscovery()
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      discoverDisplays: { [discovery] in discovery.discover($0) })

    // The state the launch race puts this in.
    #expect(model.allControlledStates.isEmpty)
    #expect(model.synthesis.persistenceKey(2) == "3669-key")
  }

  /// Displays discovery does not know miss the controller table PERMANENTLY, so an
  /// unmemoized fallback retries an already-answered question forever.
  @Test func aMissIsRememberedRatherThanRewalked() {
    let discovery = CountingDiscovery()
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      discoverDisplays: { [discovery] in discovery.discover($0) })

    for _ in 0 ..< 5 { _ = model.synthesis.persistenceKey(99) }

    #expect(model.synthesis.persistenceKey(99) == nil)
    #expect(discovery.calls == 1)
  }
}

private extension Result {
  var isFailure: Bool {
    if case .failure = self { return true }
    return false
  }
}
