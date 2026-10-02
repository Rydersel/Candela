import Testing
@testable import CandelaKit

/// The probe-eligibility rule is branching logic, so it lives in the Kit with
/// tests rather than inside `AppModel`, which has no test target.
@Suite("Capability probe eligibility")
struct CapabilityProbePolicyTests {
  @Test func probesOnlyWhenNothingIsCachedAndNothingIsInFlight() {
    #expect(CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: false, hdrEngaged: false))
    #expect(!CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: true, hdrEngaged: false))
  }

  @Test func anyCachedVerdictEndsProbingForTheSession() {
    // Cache `.unknown` too, so every menu close does not repeat an unanswered
    // capabilities probe. Reconnection clears the cache for another attempt.
    for cached in [VCPSupport.supported, .unsupported, .unknown] {
      #expect(!CapabilityProbePolicy.shouldProbe(cached: cached, inFlight: false, hdrEngaged: false),
              "\(cached)")
    }
  }

  @Test func hdrSuppressesTheProbeWithoutCachingAnything() {
    // DDC is dead while HDR is engaged, so probing now caches a false `.unknown` for the
    // session. The entry stays absent and the post-HDR reconfiguration re-probes.
    #expect(!CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: false, hdrEngaged: true))
    #expect(!CapabilityProbePolicy.shouldProbe(cached: nil, inFlight: true, hdrEngaged: true))
  }
}
