import Testing
@testable import CandelaKit

/// D21: the probe-eligibility rule is branching logic, so it lives in the Kit
/// with tests rather than inside `AppModel` (app target, no test target). The
/// subtle case — "HDR means leave the entry ABSENT, do not cache `.unknown`" —
/// is pinned here instead of surviving as a comment.
@Suite("Capability probe eligibility (D24/D21)")
struct CapabilityProbePolicyTests {
  @Test func probesOnlyWhenNothingIsCachedAndNothingIsInFlight() {
    #expect(CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: false, hdrEngaged: false))
    #expect(!CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: true, hdrEngaged: false))
  }

  @Test func anyCachedVerdictEndsProbingForTheSession() {
    // Including a cached `.unknown`: the MAG answers nothing, and re-asking on
    // every menu close would be a DDC storm for a verdict that cannot change.
    for cached in [VCPSupport.supported, .unsupported, .unknown] {
      #expect(!CapabilityProbePolicy.shouldProbe(cached: cached, inFlight: false, hdrEngaged: false),
              "\(cached)")
    }
  }

  @Test func hdrSuppressesTheProbeWithoutCachingAnything() {
    // DDC is dead while HDR is engaged. Probing now would cache a false
    // `.unknown` for the rest of the session; the caller must skip and leave
    // the entry absent so the post-HDR reconfiguration re-probes.
    #expect(!CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: false, hdrEngaged: true))
    #expect(!CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: true, hdrEngaged: true))
  }
}
