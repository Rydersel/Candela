import Foundation
import Testing
@testable import CandelaKit

/// Engage on launch and on arrival runs with nobody watching, and engaging is
/// far more disruptive than reapplying a mode: it creates a virtual display and
/// mirrors the panel onto it. Every refusal, and the order they are checked in,
/// is pinned here rather than left to the coordinator.
@Suite("Synthesis reapply policy")
struct SynthesisReapplyPolicyTests {
  private let stored = SyntheticSizeDescriptor(logicalWidth: 3268, logicalHeight: 1368)
  private var resolved: SyntheticSize {
    SyntheticSize(logicalWidth: 3268, logicalHeight: 1368, percentOfNative: 95)
  }

  /// Every argument set to the value that lets an engage through, so each test
  /// below spoils exactly one of them and nothing else can explain the result.
  private func decide(
    optedIn: Bool = true,
    stored: SyntheticSizeDescriptor? = nil,
    resolved: SyntheticSize? = nil,
    isBuiltIn: Bool = false,
    hdrEngaged: Bool = false,
    alreadyEngaged: Bool = false,
    freeSlots: Int = 2
  ) -> SynthesisReapplyDecision {
    SynthesisReapplyPolicy.decide(
      optedIn: optedIn,
      stored: stored ?? self.stored,
      resolved: resolved ?? self.resolved,
      isBuiltIn: isBuiltIn,
      hdrEngaged: hdrEngaged,
      alreadyEngaged: alreadyEngaged,
      freeSlots: freeSlots
    )
  }

  @Test func aResolvedStoredSizeOnAnOptedInDisplayEngages() {
    #expect(decide() == .engage(resolved))
  }

  /// SS14. The built-in panel is not a synthesis target in v1, and a stored
  /// size cannot arrive on one by any supported route, so this is the refusal
  /// that runs before the ones that would look at what was stored.
  @Test func theBuiltInPanelIsNeverATarget() {
    #expect(decide(isBuiltIn: true) == .skip(.builtIn))
  }

  @Test func aDisplayNobodyOptedInForIsNeverEngaged() {
    #expect(decide(optedIn: false) == .skip(.optedOut))
  }

  @Test func nothingStoredIsNothingToEngage() {
    let decision = SynthesisReapplyPolicy.decide(
      optedIn: true, stored: nil, resolved: nil,
      isBuiltIn: false, hdrEngaged: false, alreadyEngaged: false, freeSlots: 2
    )
    #expect(decision == .skip(.nothingStored))
  }

  /// A stored size the catalog no longer produces: the panel changed, or an
  /// existing HiDPI row has since taken the stop over under SS2. Distinct from
  /// `nothingStored` because a size the user chose has stopped being on offer,
  /// which is worth saying out loud.
  @Test func aStoredSizeTheLadderNoLongerOffersIsStale() {
    let decision = SynthesisReapplyPolicy.decide(
      optedIn: true, stored: stored, resolved: nil,
      isBuiltIn: false, hdrEngaged: false, alreadyEngaged: false, freeSlots: 2
    )
    #expect(decision == .skip(.staleDescriptor))
  }

  /// The stored size is already on the display, so engaging again would tear a
  /// working synthesis set down and rebuild it for nothing.
  @Test func aDisplayAlreadyCarryingItsStoredSizeIsLeftAlone() {
    #expect(decide(alreadyEngaged: true) == .skip(.alreadyEngaged))
  }

  /// SS9. Mode changes were measured silently dropping HDR, so synthesis
  /// refuses rather than engaging and finding out.
  @Test func hdrRefusesTheEngage() {
    #expect(decide(hdrEngaged: true) == .skip(.hdrEngaged))
  }

  /// SS6 reserves exactly two slots for synthesis, so a third opted-in display
  /// has nowhere to put a virtual display.
  @Test func noFreeSlotRefusesTheEngage() {
    #expect(decide(freeSlots: 0) == .skip(.noFreeSlot))
  }

  /// A slot pool that has somehow gone negative is still a pool with nothing in
  /// it. Guarding on "at least one" rather than "not zero" keeps a bookkeeping
  /// error from reading as capacity.
  @Test func aNegativeSlotCountIsAlsoNoFreeSlot() {
    #expect(decide(freeSlots: -1) == .skip(.noFreeSlot))
  }

  /// The precedence itself, peeled one refusal at a time. Every flag is set
  /// against an engage at the start; each step fixes the reason the previous
  /// step reported and expects the next one down the order, ending on the
  /// engage. This is the test that fails if a guard is ever reordered, which no
  /// single-refusal test above can catch.
  @Test func refusalsAreReportedInAFixedOrder() {
    var optedIn = false
    var storedDescriptor: SyntheticSizeDescriptor? = nil
    var resolvedSize: SyntheticSize? = nil
    var isBuiltIn = true
    var hdrEngaged = true
    var alreadyEngaged = true
    var freeSlots = 0

    func current() -> SynthesisReapplyDecision {
      SynthesisReapplyPolicy.decide(
        optedIn: optedIn, stored: storedDescriptor, resolved: resolvedSize,
        isBuiltIn: isBuiltIn, hdrEngaged: hdrEngaged,
        alreadyEngaged: alreadyEngaged, freeSlots: freeSlots
      )
    }

    #expect(current() == .skip(.builtIn))
    isBuiltIn = false
    #expect(current() == .skip(.optedOut))
    optedIn = true
    #expect(current() == .skip(.nothingStored))
    storedDescriptor = stored
    #expect(current() == .skip(.staleDescriptor))
    resolvedSize = resolved
    #expect(current() == .skip(.alreadyEngaged))
    alreadyEngaged = false
    #expect(current() == .skip(.hdrEngaged))
    hdrEngaged = false
    #expect(current() == .skip(.noFreeSlot))
    freeSlots = 1
    #expect(current() == .engage(resolved))
  }
}
