import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The engage tail and the coordinator decisions around a synthesized size,
/// host-free, over `SynthesisFixture`'s real coordinators and real engine.
///
/// Everything here was product-only until 2026-08-18: nine fixes had landed on
/// these paths with no test between them, and the two that were wrong
/// (a stored stop that survived a kept ordinary size, a link bounce whose
/// completion log outran what it had measured) were both invisible to every
/// suite. The three seams that made them reachable are the injected bounce
/// durations, the recorded mode applies, and the scriptable HDR seam.
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

  /// The re-time is what keeps the display on its own timing, so a landed
  /// engage has to have applied the display's OWN mode to it, once, after the
  /// mirror stood.
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

  /// And a FAILED engage re-times nothing: the tail runs only on success, so a
  /// refused mirror must not leave a mode apply behind on a display it never
  /// moved.
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

  /// The bounce is the fallback, so it runs exactly when the re-time did not:
  /// here the apply throws, and the HDR seam sees a full round trip.
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

  /// A display with no HDR gets no bounce at all, however the re-time went.
  /// There is nothing to renegotiate through, and an HDR write to a display
  /// that has none is a write nobody can predict.
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

  /// The user's own HDR is never ended by a bounce. The guard is read AFTER the
  /// settle rather than before it, so a state that changed while the engage was
  /// landing is the one this decides from.
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

  /// A state nobody will vouch for fails the same guard. `.unknown` from the
  /// controller means a transition raced the read, and deciding from it is
  /// exactly the mistake the measured-read rule exists to stop.
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

  /// The on leg reports ACHIEVED, not issued, and abandoning it still runs the
  /// off discipline.
  ///
  /// A false from the seam is TWO facts: the display measured the other way, or
  /// a newer transition superseded the call, which established nothing and left
  /// the register assumed locked. Reading it as "HDR never came on" and walking
  /// away is a best-effort path leaving the disabling state standing, on a
  /// display whose only symptom is brightness and volume quietly not working.
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

  /// The same shape with the off leg refusing too: this is the state that kills
  /// DDC, and it has to reach a person whichever leg failed first.
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

  /// And the one case that does NOT write: the on leg was never issued, so the
  /// display is measured out of HDR and there is nothing to stand down. The
  /// fresh read before the off leg is the last chance not to reach into a state
  /// this feature did not create.
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

  /// The one hard rule. HDR left standing kills DDC to the display, so the off
  /// leg is tried three times and then reported where a person can read it: a
  /// log line is not a recovery path.
  @Test func anOffLegThatNeverTakesIsReportedAndNotSwallowed() async throws {
    let hdr = FakeSynthesisHDR(achievesOff: false)
    let fixture = Fixture(hdr: hdr)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    fixture.configurator.refusesModeApplies = true

    _ = await fixture.synthesis.engage(stop, on: display)

    #expect(hdr.legs.filter { $0.enabled == false }.count == 3)
    // The seam is what carries it to a surface: `AppModel` wires this to
    // `SynthesisCoordinator.note(.hdrLeftStanding,)`, which `SynthesisCopy`
    // renders in the banner region. Asserted at the seam because the seam is
    // built before the coordinator it reports to, so a fixture cannot hold both
    // ends of that join.
    #expect(hdr.leftStanding == [Self.panelID])
  }

  // MARK: - What the surfaces read

  /// SS1 over the readback. The engage tail re-times the display onto its own
  /// mode, so `current` names a real published row: every "what is running"
  /// reader has to go through `onScreen`, and every no-op guard has to see nil.
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
    // The rate rides along from the readback, which the re-time put back on the
    // display: a label with no rate on it would read as the feature having
    // taken the rate away.
    #expect(after.onScreen?.refreshHz == Fixture.nativeHz)
    // The guard the pick paths consult. nil, so picking the native size is a
    // real change rather than a silent no-op against a descriptor that happens
    // to match it.
    #expect(after.alreadyOnScreenModeID == nil)
  }

  /// The mid-engage catalog pass that poisoned the ladder, driven at the one
  /// instant it can happen: the mirror stands, the pairing snapshot is still
  /// empty (so `isEngaged` reads FALSE and the baseline lookup does not take
  /// its cached-value shortcut), the work depth is still raised, and the world
  /// is already publishing the master's twins.
  ///
  /// That combination is what reaches the guard the fix changed. A pass run
  /// after the engage returns cannot: `isEngaged` is true by then and
  /// `baseline` answers from the cache before the guard is evaluated at all.
  ///
  /// Fails under the mutation this pins, which is dropping `!unstable` from the
  /// guard: the poisoned baseline replaces the good one and the ladder, the
  /// native pixels and the engaged row all go with it.
  @Test func aCatalogRefreshInsideTheEngageWindowKeepsTheLadder() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    fixture.world.publishesMasterTwinsWhileMirrored = true
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let stopsBefore = fixture.modes.catalogs[Self.panelID]?.syntheticStops ?? []
    #expect(!stopsBefore.isEmpty, "the fixture's own control")

    // Runs on the engine's executor with the mirror standing. Hopping to the
    // main actor and BLOCKING there is what makes the pass land inside the
    // window rather than after it.
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

  /// The first-sight escape hatch, closed: a pass that runs while the baseline
  /// is untrustworthy stores NOTHING, even when nothing is cached yet.
  ///
  /// The scope of that is narrow and worth stating, because the test has to
  /// model it exactly. While the set stands, a pass computes from a world that
  /// is publishing the master's twins, so it is poisoned whether or not the
  /// cache is consulted. What the old `|| baselines[key] == nil` escape added
  /// was PERMANENCE: the poison became the cached answer, and `isEngaged` then
  /// short-circuits to it for the rest of the set's life, so nothing can
  /// recover even once the world stops lying. That is what this drives: first
  /// sight inside the mirror window, then the OS list settling back, then a
  /// second pass.
  ///
  /// Fails under the mutation: the cached first-sight poison is returned by the
  /// `isEngaged` shortcut and the second pass never gets to look.
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
        // FIRST sight for this identity, and it happens inside the window.
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

  /// The enumeration order that made the launch restore report a stale
  /// descriptor forever: the native flag rides the HiDPI twin, so a ladder
  /// taken from the RAW list computes from half the real logical size and every
  /// stop falls under the minor-axis floor. The catalog is sorted first.
  @Test func aNativeFlaggedHiDPITwinDoesNotSuppressTheLadder() {
    let fixture = Fixture(nativeRidesTheHiDPITwin: true)
    defer { fixture.forgetPrefs() }

    let catalog = fixture.modes.catalogs[Self.panelID]
    #expect(catalog?.syntheticStops.isEmpty == false)
  }

  // MARK: - An ordinary size over a committed set

  /// SS10 through the picker: an ordinary pick over a COMMITTED set takes the
  /// set down through the engine before any mode touches the display, and the
  /// gate comes back afterwards.
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
    // A null-master change is the break, and the fake world records every batch.
    #expect(
      fixture.world.mirrorChanges.contains { changes in
        changes.contains { $0.display == Self.panelID && $0.master == kCGNullDirectDisplay }
      })

    // Keeping the ordinary size clears the stored stop, and it does so with
    // Remember OFF, which is the shipped default: the two prefs are unrelated
    // and neither may gate the other. Left standing, the next launch would
    // re-engage the stop over the size the person just confirmed.
    #expect(!fixture.modes.isRemembering(Self.panelID), "the fixture's own control")
    if let preview = fixture.modes.preview { _ = await fixture.modes.confirm(preview) }
    await fixture.settle()
    #expect(fixture.prefs.storedSyntheticSize == nil)
  }

  /// RULING 2026-08-18. The teardown above is irreversible and it happens
  /// BEFORE the reversible preview, so Revert has to return the person to the
  /// screen they were looking at when they picked: the synthesized size, not
  /// the desktop the display had before it was ever engaged.
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
  /// `endOutstandingPreview` produces the same `.reverted` outcome a person's
  /// own Revert does, and every caller of it is about to reconfigure these
  /// displays for itself: the mirror path claims the gate and then stands
  /// previews down, the opt-out and the whole-app reset stand them down before
  /// claiming. `SynthesisCoordinator.engage` takes no claim of its own, so a
  /// restore from any of those is tens of seconds of display reconfiguration
  /// performed inside somebody else's operation, and in the mirror case it
  /// mirrors the user's own topology on top of a display this app has just
  /// made a synthesis slave.
  ///
  /// The stash is CONSUMED rather than dropped, so the stored stop cannot
  /// re-engage at the next launch behind a person who is looking at something
  /// else, and the disappearance gets a sentence.
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

  /// A superseding pick consumes the stash too, and the stored stop goes with
  /// it. Pick A's preview is resolved inside `ModePreviewSession.begin`'s
  /// revert-first, which reaches no arm here, so a bare drop left the pref
  /// naming a size that will not be on the glass under either outcome: the
  /// machine-versus-pref divergence one gesture further along.
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

  /// The restore re-validates against the ladder this display generates NOW.
  ///
  /// The refusal guard it already asks covers the opt-in, HDR, the built-in and
  /// user mirroring; it has no `sizeNoLongerOffered` arm, because that answer
  /// belongs to the catalog lookup the restore would otherwise bypass. Thirty
  /// seconds is long enough for a rotation or a native-geometry change to
  /// regenerate the ladder underneath a captured stop.
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

    // The ladder regenerates from a different native geometry, the way a
    // rotation makes it.
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

  /// The queue-context flags, asserted the only way a hang can be: the select
  /// RETURNS, and the gate is free afterwards. Both entry points the teardown
  /// needs (`endOutstandingPreview` and `releaseClaimIfIdle`) re-enter the
  /// coordinator's queue, so a teardown that took them from inside it waited on
  /// the operation doing the waiting and every later pick enqueued forever.
  @Test func anOrdinaryPickOverACommittedSetDoesNotWedgeTheQueue() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)
    let smaller = try #require(
      fixture.modes.catalogs[Self.panelID]?.all.first { $0.logicalWidth == 2560 })
    // The wiring the app makes, and the half that would hang: both closures
    // enter this coordinator's queue.
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

/// The launch-ordering join the synthesis prefs hang off, asserted where it
/// actually lives: `AppModel`'s `persistenceKey` closure.
///
/// The unattended reapply pass can run before the first controller build has
/// populated `allControlledStates`. A nil answer there reads as "not opted in"
/// and silently drops the relaunch restore, so the closure falls back to
/// discovery and MEMOIZES what it learned: the walk is a full IOKit service
/// iteration on the main actor, and the closure is reached from a catalog
/// refresh on every reconfiguration and from a Diagnostics body on every
/// render.
@Suite("The persistence-key join at launch") @MainActor
struct SynthesisPersistenceKeyTests {
  /// Counts its own calls, so the memo is a fact about behaviour rather than
  /// an implementation detail nobody can see.
  private final class CountingDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func discover(_: Set<CGDirectDisplayID>) -> AppModel.DiscoveredDisplays {
      lock.withLock { _calls += 1 }
      return [(
        display: ExternalDisplay(id: 2, name: "MAG341C", persistenceKey: "3669-key"),
        writer: FakeDDCWriter(),
        // Nothing here reads the facts: the join under test is the persistence
        // key alone.
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

    // The state the launch race puts this in: nothing has been built yet.
    #expect(model.allControlledStates.isEmpty)
    #expect(model.synthesis.persistenceKey(2) == "3669-key")
  }

  /// And the walk is asked once per display per configuration, including for
  /// the displays discovery does not know: those miss the controller table
  /// PERMANENTLY, so an unmemoized fallback is an unbounded retry of a question
  /// that has already been answered.
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
