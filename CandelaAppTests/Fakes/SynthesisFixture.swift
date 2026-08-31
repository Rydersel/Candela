import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The shared world every synthesis suite drives: a real `DisplayModeCoordinator`
/// over a real `SynthesisCoordinator`, a real preview session, a real engine and
/// a real gate, with only the two hardware backends faked (AT3).
///
/// Shared rather than copied per suite: this fixture writes REAL prefs, and a
/// drifted copy is a test that passes for the wrong reason.
@MainActor
struct SynthesisFixture {
  static let panelID: CGDirectDisplayID = 2
  static let secondPanelID: CGDirectDisplayID = 7
  static let nativeWidth = 3440
  static let nativeHeight = 1440
  static let nativeHz: Double = 175

  /// Zero, so a suite driving several engages does not pay the engage tail's
  /// real settle times: the bounce's failure path is about seventeen seconds of
  /// wall clock per case, which is the difference between a test and no test.
  static let instantDurations = BouncingSynthesisDriver.Durations(
    beforeRetime: .zero, beforeBounce: .zero, hdrSettle: .zero,
    betweenAttempts: .zero, hdrHeld: .zero
  )

  let modes: DisplayModeCoordinator
  let synthesis: SynthesisCoordinator
  let gate: DisplayReconfigurationGate
  let host: FakeSynthesisVirtualDisplayHost
  let world: FakeDisplayWorld
  let configurator: FakeSynthesisDisplayConfigurator
  let hdr: FakeSynthesisHDR
  let persistenceKey: String

  /// One ultrawide, its ladder generated from a native-flagged mode.
  ///
  /// The opt-in is a real pref write because `SynthesisCoordinator` reads
  /// `DisplayPrefs` directly; the key is unique per call and removed at the end
  /// of the test, so nothing survives the process or collides with a sibling.
  ///
  /// `secondPanel` attaches an identical ultrawide under a second id: it takes
  /// a SECOND engage to reach the sweep that catches the first one's departure.
  /// `mirroring` gives the first panel a master, CoreGraphics' shape for a
  /// mirror slave. `mirrorMaster` is the other end of that set: the flag with no
  /// master id, which is all a master reports about its own mirroring.
  ///
  /// `nativeRidesTheHiDPITwin` reproduces the enumeration order behind the
  /// stale-descriptor regression: a panel flags BOTH the 1x row at its pixel
  /// size and the HiDPI twin whose framebuffer is that size, so taking the first
  /// native-flagged entry out of the RAW list picks whichever came back first.
  /// `enumerateOnInit: false` leaves the panel baseline EMPTY, as it is for a
  /// display first seen inside a mirror window.
  init(
    optedIn: Bool = true, secondPanel: Bool = false, mirroring: CGDirectDisplayID? = nil,
    mirrorMaster: Bool = false, nativeRidesTheHiDPITwin: Bool = false,
    enumerateOnInit: Bool = true,
    hdr: FakeSynthesisHDR = FakeSynthesisHDR(supports: false)
  ) {
    let world = FakeDisplayWorld()
    let native = DisplayMode(
      ioModeID: 1, logicalWidth: Self.nativeWidth, logicalHeight: Self.nativeHeight,
      pixelWidth: Self.nativeWidth, pixelHeight: Self.nativeHeight,
      refreshHz: Self.nativeHz, isNative: true
    )
    let smaller = DisplayMode(
      ioModeID: 2, logicalWidth: 2560, logicalHeight: 1080,
      pixelWidth: 2560, pixelHeight: 1080, refreshHz: Self.nativeHz, isNative: false
    )
    let hiDPITwin = DisplayMode(
      ioModeID: 3, logicalWidth: Self.nativeWidth / 2, logicalHeight: Self.nativeHeight / 2,
      pixelWidth: Self.nativeWidth, pixelHeight: Self.nativeHeight,
      refreshHz: Self.nativeHz, isNative: true
    )
    let modeList = nativeRidesTheHiDPITwin ? [hiDPITwin, native, smaller] : [native, smaller]
    world.attach(
      ConfiguredDisplay(
        id: Self.panelID,
        identity: DisplayConfigIdentity(vendor: 0x3669, model: 1, serial: 1, isBuiltIn: false),
        name: "MAG341C", isBuiltIn: false,
        mirrorsDisplay: mirroring ?? kCGNullDirectDisplay,
        isInMirrorSet: mirroring != nil || mirrorMaster
      ),
      modes: modeList, current: native,
      nativePixels: (width: Self.nativeWidth, height: Self.nativeHeight)
    )
    if secondPanel {
      world.attach(
        ConfiguredDisplay(
          id: Self.secondPanelID,
          identity: DisplayConfigIdentity(vendor: 0x3669, model: 2, serial: 2, isBuiltIn: false),
          name: "MAG341C 2", isBuiltIn: false
        ),
        modes: [native, smaller], current: native,
        nativePixels: (width: Self.nativeWidth, height: Self.nativeHeight)
      )
    }

    let gate = DisplayReconfigurationGate()
    let configurator = FakeSynthesisDisplayConfigurator(world)
    let host = FakeSynthesisVirtualDisplayHost(world)
    let synthesis = SynthesisCoordinator(
      virtualDisplays: host, configurator: configurator, gate: gate,
      topologyStore: MirrorTopologyStore(), hdr: hdr.seam,
      bounceDurations: Self.instantDurations
    )
    let key = "app-tests-synthesis-\(UUID().uuidString)"
    synthesis.persistenceKey = { _ in key }
    DisplayPrefs(persistenceKey: key).setOfferSyntheticSizes(optedIn)

    let modes = DisplayModeCoordinator(gate: gate, configurator: configurator)
    modes.synthesis = synthesis
    if enumerateOnInit {
      modes.refreshCatalog(for: Self.panelID)
      if secondPanel { modes.refreshCatalog(for: Self.secondPanelID) }
    }

    self.modes = modes
    self.synthesis = synthesis
    self.gate = gate
    self.host = host
    self.world = world
    self.configurator = configurator
    self.hdr = hdr
    persistenceKey = key
  }

  /// The display as the world reports it right now, which is what every guard
  /// under test is handed.
  func configured(_ displayID: CGDirectDisplayID) throws -> ConfiguredDisplay {
    try #require(configurator.displays().first { $0.id == displayID })
  }

  var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  /// Takes this fixture's pref keys back out of the process's defaults.
  ///
  /// Synchronous and separate from the revert below so a test can `defer` it at
  /// the top: a throwing `#require` skips the rest of the body, and a cleanup on
  /// the happy path only leaks a key on exactly the runs that failed.
  func forgetPrefs() {
    UserDefaults.standard.removeObject(forKey: "offerSyntheticSizes.\(persistenceKey)")
    UserDefaults.standard.removeObject(forKey: "storedSyntheticSize.\(persistenceKey)")
  }

  /// Reverts whatever preview stands, so no countdown outlives the test. Stays
  /// at the end of a body rather than in a `defer`: it is async, and a `defer`
  /// cannot await.
  func revertAnyPreview() async {
    if let preview = modes.preview { _ = await modes.revert(preview) }
  }

  /// The select is fire-and-forget onto the coordinator's queue; nothing in a
  /// suite may end while it is still reconfiguring a fake world.
  ///
  /// **It GIVES UP after about two seconds and says nothing**, deliberately. A
  /// hang here cannot be cancelled cleanly and would take the whole suite with
  /// it, while an operation still running at the deadline fails the very next
  /// assertion, with a message about the state rather than about the wait. The
  /// bound is far past what the fakes need, so only a regression reaches it.
  func settle() async {
    for _ in 0 ..< 2000 where modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}
