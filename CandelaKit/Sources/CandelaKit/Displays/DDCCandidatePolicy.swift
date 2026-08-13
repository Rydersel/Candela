import CoreGraphics

/// Which online displays may be offered to DDC service matching.
///
/// Pure and separate from `DisplayDiscovery.discover` because the property
/// worth testing, "a display Candela created NEVER enters the pool", has to
/// hold whoever calls, and on hardware nobody has attached.
///
/// Filtering happens BEFORE `Arm64DDC.getServiceMatches`, never after.
/// `getServiceMatches` claims candidates greedily by descending score with
/// first-come `takenServiceLocations` and accepts any `matchScore >= 1`, and
/// `ioregMatchScore` awards +1 for a `DisplayProductName` match and +1 for an
/// EDID-substring hit, neither of which requires a genuine association; the
/// one strong signal, +10 for `kIODisplayLocationKey`, is exactly what fails
/// behind a hub. So a display that merely ENTERED the pool can be handed a
/// physical panel's `IOAVService`: DDC writes on the physical bus attributed
/// to a synthetic display, and `persistenceKey(from:)` would give both the
/// physical monitor's EDID UUID, so the two would share stored brightness
/// (VD3).
///
/// NOT implemented by extending `Arm64DDC.checkIfDummy`, which hardcodes one
/// AOC model. It is not a general "not a real panel" filter and must not
/// become one: that would put this safety property behind a growing
/// vendor-string list, failing open and silently for every model nobody
/// thought of.
public enum DDCCandidatePolicy {
  /// - Parameters:
  ///   - ownedVirtualIDs: displays Candela created. The ONLY authority that
  ///     cannot answer "don't know": we either made it or we did not.
  ///   - isForeignVirtual: `VirtualDisplayDetection.isVirtual`. nil means the
  ///     private key was unavailable, which reads as ORDINARY.
  public static func candidates(
    online: [CGDirectDisplayID],
    isBuiltIn: (CGDirectDisplayID) -> Bool,
    ownedVirtualIDs: Set<CGDirectDisplayID>,
    isForeignVirtual: (CGDirectDisplayID) -> Bool?
  ) -> [CGDirectDisplayID] {
    // `filter`, not Set arithmetic: within one score bucket the matcher
    // breaks ties by ENUMERATION ORDER, so the online list's order is part
    // of the answer and must survive.
    online.filter { id in
      guard !isBuiltIn(id) else { return false }
      guard !ownedVirtualIDs.contains(id) else { return false }
      return isForeignVirtual(id) != true
    }
  }
}
