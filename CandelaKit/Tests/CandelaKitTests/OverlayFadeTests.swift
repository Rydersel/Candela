import Foundation
import Testing
@testable import CandelaKit

/// The entry fade's two decisions that live in the Kit: which states fade in,
/// and for how long. Neither can be checked by looking at a panel: too short is
/// indistinguishable from a step, too long from a working fade with a reconcile
/// stalled behind it.
@Suite("Overlay entry fade")
struct OverlayFadeTests {
  /// Asserted over the whole state space so a state added later has to be ruled
  /// on rather than defaulting into the set. `.lockDim` raises no overlay at all,
  /// since it is delivered on the wire.
  @Test func onlyIdleDimAndBlackoutFadeOnEntry() {
    #expect(OledDimState.allCases.filter(OverlayFade.fadesInOnEntry) == [.idleDim, .blackout])
  }

  /// Below one fast care tick the fade is indistinguishable from a step; at or
  /// beyond the lock ramp it outlives the reconcile budget the declined-nudge
  /// rule protects.
  @Test func theEntryFadeOutlastsATickAndUndercutsTheLockRamp() {
    #expect(OverlayFade.entrySeconds == 0.4)
    #expect(Duration.seconds(OverlayFade.entrySeconds) > OledCareCadence.fast)
    #expect(Duration.seconds(OverlayFade.entrySeconds) < LockDimRamp.duration)
  }
}
