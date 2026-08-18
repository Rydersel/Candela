import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The call log as it stood when the hook fired, captured from the hook itself.
///
/// A snapshot rather than a marker appended to the shared log: the log's cases
/// are things the engine did to a BACKEND, and the hook is not one of those. A
/// snapshot answers the ordering question directly ("what had already happened
/// when this fired") without teaching the fakes about a call they never receive.
private final class HookWitness: @unchecked Sendable {
  private let lock = NSLock()
  private var _callsAtFire: [[SynthesisCall]] = []
  private var _ids: [CGDirectDisplayID] = []

  func fired(_ id: CGDirectDisplayID, calls: [SynthesisCall]) {
    lock.withLock {
      _ids.append(id)
      _callsAtFire.append(calls)
    }
  }

  var ids: [CGDirectDisplayID] { lock.withLock { _ids } }
  var callsAtFire: [[SynthesisCall]] { lock.withLock { _callsAtFire } }
}

private func isApplyMirroring(_ call: SynthesisCall) -> Bool {
  if case .applyMirroring = call { return true }
  return false
}

private func isCreate(_ call: SynthesisCall) -> Bool {
  if case .createVirtualDisplay = call { return true }
  return false
}

/// The early-stamp window (wave-level finding from Task 11's review).
///
/// `MirrorTopologySampler` writes the topology store synchronously at
/// `didChangeScreenParameters`, un-debounced. The mirror engages in the middle
/// of the engine's multi-second engage, so a consumer that learned about the
/// pairing only when engage RETURNED would answer `isInMirrorSet` true and
/// `isSynthesisSet` false for the engaging panel for the rest of the sequence.
/// OLED care's forget edge wipes static-region history irreversibly on that
/// answer.
@Suite struct ModeSynthesisEngineHookTests {
  private static let physical: CGDirectDisplayID = 2

  private static func world() -> FakeSynthesisWorld {
    let world = FakeSynthesisWorld()
    world.addPhysical(id: physical, logicalWidth: 3440, logicalHeight: 1440, refreshHz: 100)
    return world
  }

  private static func engine(
    _ world: FakeSynthesisWorld, witness: HookWitness
  ) -> ModeSynthesisEngine {
    ModeSynthesisEngine(
      virtualDisplays: FakeSynthesisVirtualDisplays(world),
      configurator: FakeSynthesisConfigurator(world),
      willMirrorOntoVirtualDisplay: { [world] id in witness.fired(id, calls: world.calls) }
    )
  }

  private static let size = SyntheticSize(
    logicalWidth: 2580, logicalHeight: 1080, percentOfNative: 75
  )

  /// THE ordering this exists for: the hook fires after the virtual display has
  /// been created and BEFORE the mirror that makes it a master, so the stamp is
  /// in the store before any notification the mirror produces.
  @Test func theHookFiresAfterTheCreateAndBeforeTheMirror() async throws {
    let world = Self.world()
    let witness = HookWitness()
    let engine = Self.engine(world, witness: witness)

    let result = await engine.engage(
      Self.size, onPhysical: Self.physical, identityKey: world.identityKey(of: Self.physical)
    )

    #expect(result.isSuccess)
    #expect(witness.ids.count == 1)
    #expect(witness.ids.first == FakeSynthesisWorld.virtualDisplayID(slot: 4))
    let seen = try #require(witness.callsAtFire.first)
    #expect(seen.contains(where: isCreate))
    #expect(!seen.contains(where: isApplyMirroring))
    // And the mirror really did happen afterwards, so the assertion above is
    // about ordering rather than about a sequence that never got that far.
    #expect(world.calls.contains(where: isApplyMirroring))
  }

  /// The failure the stamp is most exposed to: the mirror is refused, so the
  /// engine unwinds and reports it. The announcement still went out, which is
  /// deliberate (over-stamping a display nobody mirrors changes no predicate);
  /// taking it back is the consumer's post-sequence refresh from the pairing
  /// table, which is empty here.
  @Test func theHookStillFiresWhenTheMirrorIsRefusedAndTheEngineKeepsNoPairing() async {
    let world = Self.world()
    world.mirrorFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    let witness = HookWitness()
    let engine = Self.engine(world, witness: witness)

    let result = await engine.engage(
      Self.size, onPhysical: Self.physical, identityKey: world.identityKey(of: Self.physical)
    )

    #expect(result.isSuccess == false)
    #expect(witness.ids == [FakeSynthesisWorld.virtualDisplayID(slot: 4)])
    #expect(await engine.pairings().isEmpty)
  }

  /// A virtual display that never reached 2x is destroyed without ever being
  /// mirrored, so it is never announced: the hook sits after that check, and
  /// announcing less is the reason it does.
  @Test func aVirtualDisplayThatNeverReached2xIsNeverAnnounced() async {
    let world = Self.world()
    world.hiDPIEngageVerdict = false
    let witness = HookWitness()
    let engine = Self.engine(world, witness: witness)

    let result = await engine.engage(
      Self.size, onPhysical: Self.physical, identityKey: world.identityKey(of: Self.physical)
    )

    #expect(result.isSuccess == false)
    #expect(witness.ids.isEmpty)
    #expect(!world.calls.contains(where: isApplyMirroring))
  }
}

private extension Result where Success == SynthesisPairing, Failure == SynthesisFailure {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}
