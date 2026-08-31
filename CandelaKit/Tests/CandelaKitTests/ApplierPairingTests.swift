import CoreGraphics
import os
import Testing
@testable import CandelaKit

/// Collects the lines an applier's wiring-bug guard would otherwise write to
/// the unified log. Injected by every test that trips a guard, so the suite
/// never puts a production-shaped assertion line into the app's own `applier`
/// category, and so "it reported the mismatch" is something a test asserts.
struct MismatchRecorder: Sendable {
  private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

  var report: ApplierMismatchReporting {
    let lines = self.lines
    return { line in lines.withLock { $0.append(line) } }
  }

  func recorded() -> [String] { lines.withLock { $0 } }
}

/// Submits whose applier does not accept the kind of target it was handed.
///
/// The pairing is chosen in `applyPaths`, one branch at a time, and nothing
/// used to check it: a swapped branch produced a rejected write, a log line
/// nobody greps, and a display that silently did not move. Every test here
/// asserts this list is empty, so the check travels with the branch table.
@MainActor
private func mispairedSubmits(_ h: Harness) -> [String] {
  h.submittedPairs
    .filter { $0.applier.accepts != $0.target.kind }
    .map { "\($0.target) carried by \(type(of: $0.applier))" }
}

@MainActor
@Suite("Applier pairing")
struct ApplierPairingTests {
  /// The register leg is carried by the DDC applier and nothing else, on both
  /// branches that write it: combined's hardware half, and pure DDC.
  @Test func theRegisterLegIsAlwaysCarriedByTheDDCApplier() {
    let combined = Harness()
    combined.controller.setBrightness(0.75)
    #expect(combined.submitted == [.ddc(raw: 50)])
    #expect(mispairedSubmits(combined).isEmpty)
    #expect(combined.submittedPairs.allSatisfy { $0.applier is DDCCommandApplier })

    let pureDDC = Harness { prefs, _ in prefs.disableCombinedBrightness = true }
    pureDDC.controller.setBrightness(0.75)
    #expect(pureDDC.submitted == [.ddc(raw: 75)])
    #expect(mispairedSubmits(pureDDC).isEmpty)
    #expect(pureDDC.submittedPairs.allSatisfy { $0.applier is DDCCommandApplier })
  }

  /// The native leg is carried by the injected native applier, never by the DDC
  /// one. `FakeNativeApplier` stands in for `NativeBrightnessApplier` and
  /// declares the same `accepts`, so the pairing assertion is the real one.
  @Test func theNativeLegIsCarriedByTheNativeApplier() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    h.controller.setBrightness(0.75)
    #expect(h.submitted == [.native(1.0), .native(0.75)])
    #expect(mispairedSubmits(h).isEmpty)
    #expect(h.submittedPairs.allSatisfy { !($0.applier is DDCCommandApplier) })
  }

  /// The built-in's constitutively native path (role `.builtIn`) pairs natively
  /// too. Its own row because it reaches `applyPaths` through a different
  /// predicate than HDR does, and the mispairing was reported on a rig whose
  /// built-in is the one native display.
  @Test func theBuiltInRolePairsNatively() {
    let h = Harness(withHDR: false, role: .builtIn, readNative: { _ in 0.5 })
    h.controller.setBrightness(0.75)
    #expect(h.submitted == [.native(0.75)])
    #expect(mispairedSubmits(h).isEmpty)
  }

  /// One controller crossing between paths: HDR live (native), then off
  /// (combined DDC). Both kinds go through the SAME controller and each still
  /// meets an applier that accepts it. This is the suspected shape: an applier
  /// chosen once and reused after the path changed under it.
  @Test func crossingBetweenPathsRepairsTheApplierWithTheTarget() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    h.controller.setBrightness(0.75)
    await h.hdr?.setHDR(displayID: Harness.displayID, enabled: false)
    await h.controller.noteHDRStateMayHaveChanged()
    h.controller.setBrightness(0.6)

    #expect(h.submitted.contains(.native(0.75)))
    #expect(h.submitted.contains { $0.kind == .ddc })
    #expect(mispairedSubmits(h).isEmpty)
  }

  /// The paths that write no register submit through NOBODY: force-software,
  /// combined with the DDC leg turned off, and the fully blocked corner. The
  /// empty list is what proves the software legs never borrowed an applier.
  @Test func thePathsThatWriteNoRegisterSubmitNothingAtAll() {
    let forced = Harness { prefs, _ in prefs.forceSoftware = true }
    forced.controller.setBrightness(0.75)
    #expect(forced.submittedPairs.isEmpty)

    let ddcOff = Harness { prefs, _ in
      var tuning = prefs.tuning(for: .brightness)
      tuning.unavailableDDC = true
      prefs.setTuning(tuning, for: .brightness)
    }
    ddcOff.controller.setBrightness(0.4)
    #expect(ddcOff.submittedPairs.isEmpty)

    let blocked = Harness { prefs, _ in
      prefs.disableCombinedBrightness = true
      var tuning = prefs.tuning(for: .brightness)
      tuning.unavailableDDC = true
      prefs.setTuning(tuning, for: .brightness)
    }
    blocked.controller.setBrightness(0.4)
    #expect(blocked.submittedPairs.isEmpty)
  }

  /// The register writers that are not the slider pair correctly too: the split
  /// delivery (register first, software after), the temporary dim, the
  /// re-assert, and the full-range hand-back. Each is its own entry point into
  /// `applyPaths` or `submitDDCBrightness`, so each could pick its own applier.
  @Test func everySecondaryRegisterWriterPairsCorrectly() async {
    let h = Harness()
    h.controller.setBrightness(0.4)
    h.prefs.disableCombinedBrightness = true
    h.controller.reapplyAfterPrefChange() // register-then-software delivery
    h.controller.beginTemporaryDim(factor: 0.5)
    h.controller.endTemporaryDim()
    h.controller.reassertHardware()
    h.controller.restoreFullRangeDDC()
    await h.controller.waitForPendingWrites()

    #expect(h.submittedPairs.count >= 4)
    #expect(mispairedSubmits(h).isEmpty)
    #expect(h.submittedPairs.allSatisfy { $0.applier is DDCCommandApplier })
    // A mispaired submit is a DROPPED write, so the writer is the other half of
    // the assertion: the register actually moved.
    #expect(await !h.ddc.recordedWrites().isEmpty)
  }
}
