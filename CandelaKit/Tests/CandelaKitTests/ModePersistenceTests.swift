import Foundation
import Testing
@testable import CandelaKit

@Suite("Mode persistence")
struct ModePersistenceTests {
  private let identity = DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)

  @Test func persistenceIsOffUntilExplicitlyEnabled() {
    let store = ModePersistence(defaults: InMemoryDefaults())
    #expect(!store.isEnabled(for: identity))
    store.setEnabled(true, for: identity)
    #expect(store.isEnabled(for: identity))
  }

  @Test func aStoredDescriptorRoundTrips() {
    let store = ModePersistence(defaults: InMemoryDefaults())
    let descriptor = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 120).descriptor
    store.store(descriptor, for: identity)
    #expect(store.storedMode(for: identity) == descriptor)
    store.clear(for: identity)
    #expect(store.storedMode(for: identity) == nil)
  }

  @Test func twoDisplaysDoNotShareStoredModes() {
    let store = ModePersistence(defaults: InMemoryDefaults())
    let other = DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    store.store(DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880)).descriptor, for: identity)
    #expect(store.storedMode(for: other) == nil)
  }

  /// The opt-in flag is per display too. One display's toggle enabling every
  /// other display's reapply would move screens nobody opted in for.
  @Test func twoDisplaysDoNotShareTheOptInFlag() {
    let store = ModePersistence(defaults: InMemoryDefaults())
    let other = DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    store.setEnabled(true, for: identity)
    #expect(!store.isEnabled(for: other))
    store.setEnabled(false, for: identity)
    #expect(!store.isEnabled(for: identity))
  }

  /// Both keys are UserDefaults key components and are frozen once shipped —
  /// the same contract `DisplayConfigIdentity.key` and `DisplayPrefs` carry.
  /// Pinned by exact literal, so a rename cannot orphan stored preferences
  /// without failing here first.
  @Test func keysAreTheFrozenOnDiskSpelling() {
    let defaults = InMemoryDefaults()
    let store = ModePersistence(defaults: defaults)
    store.setEnabled(true, for: identity)
    store.store(DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880)).descriptor, for: identity)
    #expect(defaults.bool(forKey: "rememberDisplayMode.10ac-436a-4433334c"))
    #expect(defaults.data(forKey: "storedDisplayMode.10ac-436a-4433334c") != nil)
  }

  // MARK: - Resolution order (spec §8)

  @Test func anExactMatchWinsOutright() {
    let target = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 120)
    let modes = [DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (5120, 2880), hz: 60), target]
    #expect(ModePersistence.resolve(target.descriptor, in: modes) == .exact(target))
  }

  @Test func sameGeometryWithADifferentRefreshRateIsSecond() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 120).descriptor
    let available = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (5120, 2880), hz: 60)
    #expect(ModePersistence.resolve(stored, in: [available]) == .refreshRateDiffers(available))
  }

  /// Degrading a stored HiDPI choice to 1x is the worst outcome here — it
  /// looks like the feature silently stopped working.
  @Test func sameLogicalSizePrefersHiDPIOverOneX() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880)).descriptor
    let oneX = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (2560, 1440))
    let hiDPI = DisplayModeFixtures.mode(3, logical: (2560, 1440), pixels: (5120, 2880), hz: 30)
    #expect(ModePersistence.resolve(stored, in: [oneX, hiDPI]) == .refreshRateDiffers(hiDPI))
    #expect(ModePersistence.resolve(stored, in: [oneX]) == .scaleDiffers(oneX))
  }

  /// The test above cannot actually fail for its stated reason: its HiDPI
  /// candidate has the SAME framebuffer as the stored descriptor, so step 2
  /// (same geometry, nearest refresh) answers it and the HiDPI preference in
  /// step 3 is never reached. Here the stored framebuffer is absent entirely,
  /// so step 3 is the only branch that can answer and it has a real choice to
  /// get wrong.
  ///
  /// The stored 1.5x framebuffer is deliberate: `isHiDPI` is a hard `>= 2x`
  /// threshold, so a 3840x2160-backed 2560x1440 is NOT a HiDPI candidate. Real
  /// macOS lists offer only 1x and 2x per logical size, which is exactly why
  /// step 3's preference needs a test that constructs the choice rather than
  /// hoping the enumeration supplies one.
  @Test func aDifferentFramebufferStillPrefersHiDPIOverOneX() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (3840, 2160)).descriptor
    let oneX = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (2560, 1440))
    let hiDPI = DisplayModeFixtures.mode(3, logical: (2560, 1440), pixels: (5120, 2880))
    #expect(ModePersistence.resolve(stored, in: [oneX, hiDPI]) == .scaleDiffers(hiDPI))
    // Order must not decide it.
    #expect(ModePersistence.resolve(stored, in: [hiDPI, oneX]) == .scaleDiffers(hiDPI))
  }

  /// A substitute at a different framebuffer is a SCALE change, whatever its
  /// refresh rate. Labelling it `.refreshRateDiffers` would tell the user
  /// their refresh rate moved while their scaling silently changed instead —
  /// step 3 is only ever reached when no same-geometry candidate exists.
  @Test func aScaleSubstituteIsNeverReportedAsARefreshChange() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (3840, 2160), hz: 60).descriptor
    let sameRateOtherScale = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (5120, 2880), hz: 60)
    #expect(ModePersistence.resolve(stored, in: [sameRateOtherScale])
      == .scaleDiffers(sameRateOtherScale))
  }

  /// Step 2 honours the stored rate by picking the NEAREST; step 3 must not
  /// quietly switch to "fastest wins" and bump a deliberate 60 Hz choice to
  /// 144 Hz on the way through.
  @Test func aScaleSubstituteKeepsTheNearestRefreshRate() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 60).descriptor
    let fast = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (3840, 2160), hz: 144)
    let near = DisplayModeFixtures.mode(3, logical: (2560, 1440), pixels: (3840, 2160), hz: 60)
    #expect(ModePersistence.resolve(stored, in: [fast, near]) == .scaleDiffers(near))
  }

  @Test func nearestSizeIsUsedWhenNothingMatchesExactly() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880)).descriptor
    let near = DisplayModeFixtures.mode(2, logical: (2400, 1350), pixels: (4800, 2700))
    let far = DisplayModeFixtures.mode(3, logical: (1280, 720), pixels: (2560, 1440))
    #expect(ModePersistence.resolve(stored, in: [far, near]) == .sizeDiffers(near))
  }

  /// A real panel offers the nearest size at several framebuffers and half a
  /// dozen refresh rates. Picking whichever CoreGraphics happened to enumerate
  /// first would hand the user a 1x 24 Hz desktop and call it the nearest
  /// match — the same HiDPI and refresh preferences apply here.
  @Test func theNearestSizeIsDisambiguatedNotLeftToEnumerationOrder() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 60).descriptor
    let oneXSlow = DisplayModeFixtures.mode(2, logical: (2400, 1350), pixels: (2400, 1350), hz: 24)
    let hiDPISlow = DisplayModeFixtures.mode(3, logical: (2400, 1350), pixels: (4800, 2700), hz: 24)
    let hiDPIRight = DisplayModeFixtures.mode(4, logical: (2400, 1350), pixels: (4800, 2700), hz: 60)
    #expect(ModePersistence.resolve(stored, in: [oneXSlow, hiDPISlow, hiDPIRight])
      == .sizeDiffers(hiDPIRight))
    #expect(ModePersistence.resolve(stored, in: [hiDPIRight, hiDPISlow, oneXSlow])
      == .sizeDiffers(hiDPIRight))
  }

  /// A 16:9 substitute on a 21:9 panel is worse than doing nothing — it
  /// letterboxes or stretches, and the user did not ask for it.
  @Test func aDifferentAspectRatioIsNeverSubstituted() {
    let stored = DisplayModeFixtures.mode(1, logical: (2580, 1080), pixels: (5160, 2160)).descriptor // 21:9
    let wrongShape = DisplayModeFixtures.mode(2, logical: (1920, 1080), pixels: (3840, 2160))        // 16:9
    #expect(ModePersistence.resolve(stored, in: [wrongShape]) == .none)
  }

  @Test func anEmptyModeListResolvesToNone() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880)).descriptor
    #expect(ModePersistence.resolve(stored, in: []) == .none)
  }

  /// CoreGraphics reports 59.997 where the user picked "60". Comparing Doubles
  /// with == means a stored mode NEVER matches on real hardware and every
  /// reconnect silently takes a fallback branch.
  @Test func refreshRatesMatchWithinATolerance() {
    let stored = DisplayModeFixtures.mode(1, logical: (2560, 1440), pixels: (5120, 2880), hz: 60).descriptor
    let real = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (5120, 2880), hz: 59.997)
    #expect(ModePersistence.resolve(stored, in: [real]) == .exact(real))
    #expect(ModePersistence.refreshMatches(59.997, 60))
    #expect(!ModePersistence.refreshMatches(59.997, 120))
  }

  /// The tolerance must stay narrower than the gap between any two rates a
  /// picker actually offers. It is NOT narrow enough to separate 59.94 from
  /// 60 — see the note on `refreshMatches`; those two collapse deliberately.
  @Test func theToleranceDoesNotSwallowAdjacentRealRates() {
    #expect(!ModePersistence.refreshMatches(50, 60))
    #expect(!ModePersistence.refreshMatches(24, 25))
    #expect(ModePersistence.refreshMatches(120, 120))
  }

  /// 59.9 and 60 BOTH sit inside the 0.5 Hz window, so step 1 has to pick the
  /// NEARER one rather than the first one CoreGraphics happened to list.
  ///
  /// A user-visible rule, not a tidiness one. `quantizedRefresh` keeps 59.9 and
  /// 60 apart and the picker draws them as separate rows, so a picked 59.9
  /// resolving to the 60 mode hands back a mode whose `ioModeID` is the one
  /// already current — which `DisplayModeSection.apply` early-returns on. The
  /// picker snapped back and nothing happened.
  ///
  /// Asserted in both list orders: passing in one ordering only is exactly what
  /// an enumeration-order-dependent implementation looks like.
  @Test func theNearerOfTwoRatesInsideTheToleranceWins() {
    let ntsc = DisplayModeFixtures.mode(3, logical: (2560, 1440), pixels: (5120, 2880), hz: 59.9)
    let sixty = DisplayModeFixtures.mode(2, logical: (2560, 1440), pixels: (5120, 2880), hz: 60)
    // The premise: without both inside the window there is nothing to choose.
    #expect(ModePersistence.refreshMatches(59.9, 60))

    #expect(ModePersistence.resolve(ntsc.descriptor, in: [sixty, ntsc]) == .exact(ntsc))
    #expect(ModePersistence.resolve(ntsc.descriptor, in: [ntsc, sixty]) == .exact(ntsc))
    #expect(ModePersistence.resolve(sixty.descriptor, in: [ntsc, sixty]) == .exact(sixty))
    #expect(ModePersistence.resolve(sixty.descriptor, in: [sixty, ntsc]) == .exact(sixty))
  }
}
