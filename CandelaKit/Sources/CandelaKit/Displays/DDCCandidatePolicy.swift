import CoreGraphics

/// Which online displays may be offered to DDC service matching.
///
/// Pure and separate from `DisplayDiscovery.discover` because the property worth
/// testing, "a display Candela created NEVER enters the pool", has to hold
/// whoever calls, on hardware nobody has attached.
///
/// Filtering happens BEFORE `Arm64DDC.getServiceMatches`, never after. That
/// matcher claims candidates greedily by descending score and accepts any
/// `matchScore >= 1`, where `ioregMatchScore` awards +1 for a
/// `DisplayProductName` match and +1 for an EDID-substring hit, neither of which
/// needs a genuine association; the one strong signal, +10 for
/// `kIODisplayLocationKey`, is exactly what fails behind a hub. So a display
/// that merely ENTERED the pool can be handed a physical panel's `IOAVService`:
/// DDC writes on the physical bus attributed to a synthetic display, and
/// `persistenceKey(from:)` would give both the physical monitor's EDID UUID, so
/// the two would share stored brightness.
///
/// NOT implemented by extending `Arm64DDC.checkIfDummy`, which hardcodes one AOC
/// model. It is not a general "not a real panel" filter and must not become one:
/// that would put this safety property behind a growing vendor-string list,
/// failing open and silently for every model nobody thought of.
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
    classify(
      online: online, isBuiltIn: isBuiltIn, ownedVirtualIDs: ownedVirtualIDs,
      isForeignVirtual: isForeignVirtual
    ).candidates
  }

  /// `candidates`, plus which guard took each display the pool does not carry.
  /// The reasons feed the diagnostics report: the commonest bug report is about a
  /// display that is NOT in the pool, and the pool alone cannot answer it.
  ///
  /// Guard order is the one `candidates` always applied, so a display tripping two
  /// guards is named by the first and the survivors cannot shift.
  public static func classify(
    online: [CGDirectDisplayID],
    isBuiltIn: (CGDirectDisplayID) -> Bool,
    ownedVirtualIDs: Set<CGDirectDisplayID>,
    isForeignVirtual: (CGDirectDisplayID) -> Bool?
  ) -> (candidates: [CGDirectDisplayID], excluded: [(CGDirectDisplayID, DisplayExclusionReason)]) {
    var candidates: [CGDirectDisplayID] = []
    var excluded: [(CGDirectDisplayID, DisplayExclusionReason)] = []
    // A loop over the online list, not Set arithmetic: within one score bucket the
    // matcher breaks ties by ENUMERATION ORDER, so the online list's order is part
    // of the answer and must survive into both lists.
    for id in online {
      if isBuiltIn(id) {
        excluded.append((id, .builtIn))
      } else if ownedVirtualIDs.contains(id) {
        excluded.append((id, .ownedVirtual))
      } else if isForeignVirtual(id) == true {
        excluded.append((id, .foreignVirtual))
      } else {
        candidates.append(id)
      }
    }
    return (candidates, excluded)
  }
}
