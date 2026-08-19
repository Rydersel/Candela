import Testing
@testable import CandelaKit

/// The conformance suite's own failure mode is passing vacuously, so every
/// verdict here is demonstrated RED as well as green (#82's hardware
/// verification item 1): an invariant never observed failing is not yet a test.
@Suite("Platform conformance")
struct PlatformConformanceTests {
  private typealias PC = PlatformConformance

  // MARK: - The exit code is the interface

  @Test func aCleanRunExitsZero() {
    let report = PC.Report(platform: "test", checks: [
      .init(name: "a", outcome: .pass("ok")),
      .init(name: "b", outcome: .skip("not on this rig")),
    ])
    #expect(report.exitCode == 0)
  }

  @Test func oneFailureIsNonZero() {
    let report = PC.Report(platform: "test", checks: [
      .init(name: "a", outcome: .pass("ok")),
      .init(name: "b", outcome: .fail("moved")),
    ])
    #expect(report.exitCode != 0)
  }

  /// The vacuity rule: a run that demonstrated nothing must not read as the
  /// platform conforming, whether it ran no checks at all or skipped them all.
  @Test func zeroChecksIsAFailureNotAPass() {
    #expect(PC.Report(platform: "test", checks: []).exitCode != 0)
  }

  @Test func allSkipsIsAFailureNotAPass() {
    let report = PC.Report(platform: "test", checks: [
      .init(name: "a", outcome: .skip("no display matched the filter")),
      .init(name: "b", outcome: .skip("no display matched the filter")),
    ])
    #expect(report.exitCode != 0)
    #expect(report.lines().contains { $0.contains("demonstrated nothing") })
  }

  /// A skip is a reported fact: it appears in the output and in the summary,
  /// and it never counts toward the passes that make the run green.
  @Test func skipsAreReportedAndNeverCountAsPasses() {
    let report = PC.Report(platform: "test", checks: [
      .init(name: "ddc.reply", outcome: .skip("write-only panel")),
      .init(name: "cgs.count", outcome: .pass("ok")),
    ])
    #expect(report.passed == 1)
    #expect(report.skipped == 1)
    #expect(report.lines().contains { $0.hasPrefix("SKIP ddc.reply") })
    #expect(report.lines().last == "conform: 1 passed, 0 failed, 1 skipped")
  }

  /// The platform stamp comes first: a passing run is a dated record against
  /// one macOS build, never a general claim.
  @Test func theBuildStampLeadsTheOutput() {
    let report = PC.Report(platform: "Version 26.6.1 (Build 25G76)")
    #expect(report.lines().first == "platform: Version 26.6.1 (Build 25G76)")
  }

  // MARK: - modeNumber == index (S6 §4)

  @Test func indexAgreementPassesWhenTheyMatch() {
    let outcome = PC.indexAgreement(pairs: [(0, 0), (1, 1), (2, 2)])
    #expect(outcome == .pass("modeNumber == index across 3 descriptors"))
  }

  @Test func indexAgreementFailsOnTheFirstDrift() {
    let outcome = PC.indexAgreement(pairs: [(0, 0), (1, 7)])
    #expect(outcome == .fail("descriptor at index 1 carries modeNumber 7"))
  }

  @Test func indexAgreementRefusesToPassOnNothing() {
    guard case .fail = PC.indexAgreement(pairs: []) else {
      Issue.record("an empty list must not read as agreement")
      return
    }
  }

  // MARK: - The CG cross-check (the one that earns its keep)

  private func descriptor(
    id: Int32, logical: (Int, Int), pixels: (Int, Int)
  ) -> CGSModeDescriptor {
    CGSModeDescriptor(
      modeNumber: id, flags: 0,
      logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1,
      refreshHz: 60, density: Double(pixels.0) / Double(logical.0)
    )
  }

  @Test func subsetPassesWhenEveryPublishedModeAgrees() {
    let outcome = PC.subset(
      published: [(id: 5, logicalWidth: 1720, logicalHeight: 720, pixelWidth: 3440, pixelHeight: 1440)],
      cgs: [5: descriptor(id: 5, logical: (1720, 720), pixels: (3440, 1440))]
    )
    #expect(outcome == .pass("all 1 CoreGraphics modes present in CGS with geometry agreeing"))
  }

  @Test func subsetFailsOnAMissingID() {
    let outcome = PC.subset(
      published: [(id: 9, logicalWidth: 1720, logicalHeight: 720, pixelWidth: 3440, pixelHeight: 1440)],
      cgs: [5: descriptor(id: 5, logical: (1720, 720), pixels: (3440, 1440))]
    )
    #expect(outcome == .fail("CoreGraphics ioDisplayModeID 9 is absent from the CGS list"))
  }

  /// A moved logical-size field is the layout shift this check exists for.
  @Test func subsetFailsOnLogicalGeometryDisagreement() {
    let outcome = PC.subset(
      published: [(id: 5, logicalWidth: 1720, logicalHeight: 720, pixelWidth: 3440, pixelHeight: 1440)],
      cgs: [5: descriptor(id: 5, logical: (720, 1720), pixels: (3440, 1440))]
    )
    guard case let .fail(detail) = outcome else {
      Issue.record("swapped logical fields must fail")
      return
    }
    #expect(detail.contains("CG logical 1720x720"))
    #expect(detail.contains("CGS 720x1720"))
  }

  /// The framebuffer fields live at offsets 200/204, outside the transcribed
  /// headers; a shift there must not hide behind agreeing logical fields.
  @Test func subsetFailsOnFramebufferDisagreement() {
    let outcome = PC.subset(
      published: [(id: 5, logicalWidth: 1720, logicalHeight: 720, pixelWidth: 3440, pixelHeight: 1440)],
      cgs: [5: descriptor(id: 5, logical: (1720, 720), pixels: (1720, 720))]
    )
    guard case let .fail(detail) = outcome else {
      Issue.record("a framebuffer mismatch must fail")
      return
    }
    #expect(detail.contains("framebuffer"))
  }

  @Test func subsetRefusesToPassWithNothingPublished() {
    guard case .fail = PC.subset(published: [], cgs: [:]) else {
      Issue.record("no published modes means nothing was cross-validated")
      return
    }
  }

  // MARK: - Plausibility rate

  @Test func ninetyFivePercentIsTheFloor() {
    guard case .pass = PC.plausibilityRate(plausible: 19, total: 20) else {
      Issue.record("19/20 is exactly 95 percent and must pass")
      return
    }
    guard case .fail = PC.plausibilityRate(plausible: 18, total: 20) else {
      Issue.record("18/20 is 90 percent and must fail")
      return
    }
  }

  @Test func plausibilityRefusesToPassOnNothing() {
    guard case .fail = PC.plausibilityRate(plausible: 0, total: 0) else {
      Issue.record("zero descriptors judged must not read as plausible")
      return
    }
  }

  // MARK: - Density range

  @Test func densitiesInsideTheRangePass() {
    guard case .pass = PC.densityRange(densities: [0.5, 1.0, 2.0, 4.0]) else {
      Issue.record("the measured range must pass")
      return
    }
  }

  /// A Float-to-something-else type change at offset 208 lands here first.
  @Test func aDensityOutsideTheRangeFails() {
    guard case let .fail(detail) = PC.densityRange(densities: [1.0, 4.5]) else {
      Issue.record("4.5 is outside the range and must fail")
      return
    }
    #expect(detail.contains("4.5"))
  }

  @Test func densityRefusesToPassOnNothing() {
    guard case .fail = PC.densityRange(densities: []) else {
      Issue.record("no densities read must not read as in-range")
      return
    }
  }
}
