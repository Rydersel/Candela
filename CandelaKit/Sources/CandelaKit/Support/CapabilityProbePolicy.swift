/// Should we spend a DDC round-trip asking this display for its capabilities?
///
/// Three conditions, all of them "no" for a reason worth keeping honest:
/// - a cached verdict (INCLUDING `.unknown`) ends probing for the session, so
///   a write-only panel is asked once per plug rather than once per menu open;
/// - an in-flight probe is not repeated;
/// - HDR is skipped WITHOUT caching, because DDC is dead while HDR is engaged
///   and a `.unknown` cached now would outlive the condition that caused it.
///   Leaving the entry absent is what lets the post-HDR reconfiguration
///   re-probe.
public enum CapabilityProbePolicy {
  public static func shouldProbe(cached: VCPSupport?, inFlight: Bool, hdrEngaged: Bool) -> Bool {
    cached == nil && !inFlight && !hdrEngaged
  }
}
