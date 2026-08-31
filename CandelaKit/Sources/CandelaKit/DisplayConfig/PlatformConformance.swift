import CandelaPrivateAPIs
import CoreGraphics
import Foundation
import ObjectiveC

/// Does the platform still behave as this app assumes?
///
/// Every private-API guard in the codebase fails POLITELY: a renamed symbol or
/// a moved descriptor field becomes "0 modes revealed" while the suites stay
/// green, because they prove our logic against fixtures typed in on the day the
/// assumption was measured. This runs against attached hardware, asserts the
/// assumptions themselves, and exits non-zero, so `candela-probe conform` is one
/// command to run after a macOS update.
///
/// Three rules, each the lesson of a measured failure elsewhere in the repo:
///
/// - **A skip is a reported fact, never a silent pass** (DT30's honesty rule).
///   A write-only panel cannot exercise the DDC read path; the run says so.
/// - **A run that demonstrates nothing is a failure.** Zero passing checks exit
///   non-zero even with zero failures.
/// - **The verdict logic is pure and red-tested.** An invariant never observed
///   failing is not yet a test.
public enum PlatformConformance {
  public enum Outcome: Sendable, Equatable {
    case pass(String)
    case fail(String)
    case skip(String)
    /// HP7: the check ran but its positive control did not fire, so the
    /// measurement means nothing either way. Counts against the exit code.
    case inconclusive(String)
  }

  /// Whether a check's positive control fired, on the checks that carry one.
  /// A control that did not fire is what turns a result inconclusive.
  public enum ControlOutcome: Sendable, Equatable {
    case fired
    case failed
  }

  public struct Check: Sendable, Equatable {
    public let name: String
    public let outcome: Outcome
    /// Absent on checks with no positive control.
    public let control: ControlOutcome?

    public init(name: String, outcome: Outcome, control: ControlOutcome? = nil) {
      self.name = name
      self.outcome = outcome
      self.control = control
    }
  }

  /// One run's record. `checks` is publicly appendable so the probe's own
  /// checks fold into the same exit code instead of inventing a second one.
  public struct Report: Sendable {
    /// The macOS version and build this run describes. A passing run is a
    /// dated record against one build, never a general claim.
    public let platform: String
    public var checks: [Check]

    public init(platform: String, checks: [Check] = []) {
      self.platform = platform
      self.checks = checks
    }

    public var passed: Int { checks.count { if case .pass = $0.outcome { true } else { false } } }
    public var failed: Int { checks.count { if case .fail = $0.outcome { true } else { false } } }
    public var skipped: Int { checks.count { if case .skip = $0.outcome { true } else { false } } }
    public var inconclusive: Int {
      checks.count { if case .inconclusive = $0.outcome { true } else { false } }
    }

    /// Zero needs no failure AND at least one pass. All-skips is non-zero: a
    /// run that demonstrated nothing must not read as the platform conforming.
    /// An inconclusive check is non-zero too (HP7), because a dead positive
    /// control makes the whole run unbelievable.
    public var exitCode: Int32 {
      failed == 0 && inconclusive == 0 && passed > 0 ? 0 : 1
    }

    /// `label` names the run in the summary sentences. It defaults to
    /// "conform" so the committed conformance baseline stays byte-identical.
    public func lines(label: String = "conform") -> [String] {
      var out = ["platform: \(platform)"]
      for check in checks {
        switch check.outcome {
        case let .pass(detail): out.append("PASS \(check.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
        case let .fail(detail): out.append("FAIL \(check.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
        case let .skip(reason): out.append("SKIP \(check.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(reason)")
        case let .inconclusive(detail): out.append("INCONCLUSIVE \(check.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
        }
      }
      // Appended only when non-zero, so a control-free run's summary line is
      // the one the committed baseline pins.
      var summary = "\(label): \(passed) passed, \(failed) failed, \(skipped) skipped"
      if inconclusive > 0 { summary += ", \(inconclusive) inconclusive" }
      out.append(summary)
      if passed == 0 {
        out.append("\(label): this run demonstrated nothing; that is a failure, not a pass")
      }
      return out
    }
  }

  // MARK: - Pure verdicts (each red-tested in PlatformConformanceTests)

  /// S6 §4: a CGS descriptor's `modeNumber` IS the index it was read at, and
  /// the same ID space as `ioDisplayModeID`. If this drifts, every apply
  /// resolves to a different mode than the one asked for.
  public static func indexAgreement(pairs: [(index: Int, modeNumber: Int32)]) -> Outcome {
    guard !pairs.isEmpty else { return .fail("no descriptors to check") }
    if let bad = pairs.first(where: { Int32($0.index) != $0.modeNumber }) {
      return .fail("descriptor at index \(bad.index) carries modeNumber \(bad.modeNumber)")
    }
    return .pass("modeNumber == index across \(pairs.count) descriptors")
  }

  /// CoreGraphics' published list, a public API, cross-validates the private
  /// descriptor layout: if a field offset moves, geometry stops agreeing here
  /// and the run fails loudly instead of the feature revealing nothing.
  public static func subset(
    published: [(id: Int32, logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int)],
    cgs: [Int32: CGSModeDescriptor]
  ) -> Outcome {
    guard !published.isEmpty else { return .fail("CoreGraphics published no modes to cross-check") }
    for mode in published {
      guard let descriptor = cgs[mode.id] else {
        return .fail("CoreGraphics ioDisplayModeID \(mode.id) is absent from the CGS list")
      }
      guard descriptor.logicalWidth == mode.logicalWidth,
            descriptor.logicalHeight == mode.logicalHeight
      else {
        return .fail(
          "id \(mode.id): CG logical \(mode.logicalWidth)x\(mode.logicalHeight), CGS \(descriptor.logicalWidth)x\(descriptor.logicalHeight)"
        )
      }
      guard descriptor.pixelWidth == mode.pixelWidth,
            descriptor.pixelHeight == mode.pixelHeight
      else {
        return .fail(
          "id \(mode.id): CG framebuffer \(mode.pixelWidth)x\(mode.pixelHeight), CGS \(descriptor.pixelWidth)x\(descriptor.pixelHeight)"
        )
      }
    }
    return .pass("all \(published.count) CoreGraphics modes present in CGS with geometry agreeing")
  }

  /// A layout shift does not fail every descriptor: some garbage still lands
  /// inside the gates by luck. 95 percent is the floor measured healthy layouts
  /// clear easily (the rig's three panels all sit at 100).
  public static func plausibilityRate(plausible: Int, total: Int) -> Outcome {
    guard total > 0 else { return .fail("no descriptors to judge") }
    let rate = Double(plausible) / Double(total)
    guard rate >= 0.95 else {
      return .fail("only \(plausible) of \(total) descriptors plausible; a moved field rejects wholesale")
    }
    return .pass("\(plausible) of \(total) descriptors plausible")
  }

  /// `density` reads a Float at offset 208. A type or scale change lands
  /// outside [0.5, 4.0] immediately, so this is the field's own tripwire even
  /// when the plausibility rate survives.
  public static func densityRange(densities: [Double]) -> Outcome {
    guard !densities.isEmpty else { return .fail("no density values read") }
    if let bad = densities.first(where: {
      $0 < CGSModeRevelation.minimumDensity || $0 > CGSModeRevelation.maximumDensity
    }) {
      return .fail("density \(bad) outside [\(CGSModeRevelation.minimumDensity), \(CGSModeRevelation.maximumDensity)]")
    }
    return .pass("all \(densities.count) densities within [\(CGSModeRevelation.minimumDensity), \(CGSModeRevelation.maximumDensity)]")
  }

  // MARK: - The hardware run

  /// Runs every non-destructive check, plus the reconfiguring ones when
  /// `applyDestructive` is set. `ddcPanels` comes from the caller so the
  /// probe's `--display` filter applies to this command like every other.
  public static func run(
    configurator: CoreGraphicsDisplayConfigurator,
    ddcPanels: [(name: String, writer: any DDCWriting)],
    applyDestructive: Bool,
    limitTo: CGDirectDisplayID? = nil
  ) async -> Report {
    var report = Report(platform: ProcessInfo.processInfo.operatingSystemVersionString)
    // `limitTo` carries the probe's `--display` contract: a filter matching
    // nothing skips every hardware check, and the zero-passes rule then fails
    // the run rather than printing green.
    let displays = configurator.displays().filter { limitTo == nil || $0.id == limitTo }
    let noDisplays = limitTo != nil && displays.isEmpty
      ? "no online display matches --display \(limitTo!)"
      : "no online displays to enumerate"

    report.checks += cgsChecks(configurator: configurator, displays: displays, noDisplays: noDisplays)
    report.checks += rotationChecks(
      configurator: configurator, displays: displays,
      applyDestructive: applyDestructive, noDisplays: noDisplays
    )
    report.checks += monitorPanelChecks()
    report.checks += displayServicesChecks(
      displays: displays, applyDestructive: applyDestructive, isFiltered: limitTo != nil
    )
    report.checks += await ddcChecks(panels: ddcPanels)
    return report
  }

  // MARK: CGS mode revelation

  private static func cgsChecks(
    configurator: CoreGraphicsDisplayConfigurator, displays: [ConfiguredDisplay],
    noDisplays: String
  ) -> [Check] {
    var checks: [Check] = []

    // Symbols, one check each: after an update the useful answer is WHICH one
    // went missing, and `revealsHiddenModes` collapses that into a bool.
    checks.append(Check(
      name: "cgs.symbol.count",
      outcome: SkyLight.getDisplayModeCount != nil
        ? .pass("CGSGetNumberOfDisplayModes resolved")
        : .fail("CGSGetNumberOfDisplayModes did not resolve from SkyLight")
    ))
    checks.append(Check(
      name: "cgs.symbol.description",
      outcome: SkyLight.getDisplayModeDescription != nil
        ? .pass("CGSGetDisplayModeDescriptionOfLength resolved")
        : .fail("CGSGetDisplayModeDescriptionOfLength did not resolve from SkyLight")
    ))
    checks.append(Check(
      name: "cgs.symbol.configure",
      outcome: SkyLight.configureDisplayMode != nil
        ? .pass("CGSConfigureDisplayMode resolved")
        : .fail("CGSConfigureDisplayMode did not resolve from SkyLight")
    ))

    // Every early exit still names every remaining check: one that vanishes
    // from the output is a silent absence, and the first red-matrix run had
    // five disappear behind a missing symbol.
    func bailingOut(_ reason: String) -> [Check] {
      checks + ["cgs.count", "cgs.descriptor.bounds", "cgs.index", "cgs.subset",
                "cgs.plausibility", "cgs.density", "cgs.reveals"]
        .map { Check(name: $0, outcome: .skip(reason)) }
    }
    guard displays.isEmpty == false else { return bailingOut(noDisplays) }
    guard let getCount = SkyLight.getDisplayModeCount,
          let getDescription = SkyLight.getDisplayModeDescription
    else { return bailingOut("unreachable while a CGS symbol above is missing") }

    // Count > 0 for every online display.
    var counts: [String] = []
    var countFailure: String?
    for display in displays {
      var count: Int32 = 0
      let status = getCount(display.id, &count)
      if status != 0 {
        countFailure = "display \(display.id): CGSGetNumberOfDisplayModes returned \(status)"
        break
      }
      if count <= 0 {
        countFailure = "display \(display.id) reports \(count) modes"
        break
      }
      counts.append("\(display.id):\(count)")
    }
    checks.append(Check(
      name: "cgs.count",
      outcome: countFailure.map { .fail($0) } ?? .pass("all displays report modes (\(counts.joined(separator: " ")))")
    ))
    if let countFailure {
      return checks + ["cgs.descriptor.bounds", "cgs.index", "cgs.subset",
                       "cgs.plausibility", "cgs.density", "cgs.reveals"]
        .map { Check(name: $0, outcome: .skip("unreachable while cgs.count fails: \(countFailure)")) }
    }

    // The callee must write nothing past the declared 212 bytes. The buffer is
    // poisoned rather than zeroed so an overwrite of any value is visible.
    let poison: UInt8 = 0xAA
    let byteCount = 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    defer { buffer.deallocate() }
    var boundsFailure: String?
    var sampled = 0
    outer: for display in displays {
      var count: Int32 = 0
      guard getCount(display.id, &count) == 0 else { continue }
      for index in 0 ..< min(Int(count), 8) {
        memset(buffer, Int32(poison), byteCount)
        guard getDescription(display.id, Int32(index), buffer, SkyLight.descriptorLength) == 0
        else { continue }
        sampled += 1
        for offset in Int(SkyLight.descriptorLength) ..< 400
        where buffer.load(fromByteOffset: offset, as: UInt8.self) != poison {
          boundsFailure = "display \(display.id) descriptor \(index) wrote past the declared length at byte \(offset)"
          break outer
        }
      }
    }
    checks.append(Check(
      name: "cgs.descriptor.bounds",
      outcome: boundsFailure.map { .fail($0) }
        ?? (sampled > 0
          ? .pass("bytes 212..<400 untouched across \(sampled) sampled descriptors")
          : .fail("no descriptor could be read to sample"))
    ))

    var indexPairs: [(index: Int, modeNumber: Int32)] = []
    var subsetOutcome: Outcome = .skip("no display produced both lists")
    var subsetValidated = 0
    var plausible = 0, judged = 0
    var densities: [Double] = []
    var revealedTotal = 0
    var plausibilitySkips: [String] = []
    for display in displays {
      let descriptors = CoreGraphicsDisplayConfigurator.cgsDescriptors(for: display.id)
      indexPairs += descriptors.enumerated().map { ($0.offset, $0.element.modeNumber) }
      densities += descriptors.map(\.density)

      let (published, revealed) = configurator.enumerate(display.id)
      revealedTotal += revealed?.modes.count ?? 0

      // The first divergence is kept as the answer: one moved field is a
      // platform fact, not a per-panel quirk. The pass detail counts across
      // displays so a green line is not read as one panel's evidence.
      if !published.isEmpty, !descriptors.isEmpty, isFail(subsetOutcome) == false {
        let next = subset(
          published: published.map {
            (id: $0.ioModeID, logicalWidth: $0.logicalWidth, logicalHeight: $0.logicalHeight,
             pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
          },
          cgs: Dictionary(descriptors.map { ($0.modeNumber, $0) }, uniquingKeysWith: { a, _ in a })
        )
        if case .fail = next {
          subsetOutcome = next
        } else {
          subsetValidated += published.count
          subsetOutcome = .pass(
            "all \(subsetValidated) CoreGraphics modes present in CGS with geometry agreeing")
        }
      }

      // Plausibility needs the panel's native pixel size, which only the
      // CG-published native-flagged mode can provide.
      guard let native = published.first(where: \.isNative) else {
        plausibilitySkips.append("display \(display.id) publishes no native-flagged mode")
        continue
      }
      for descriptor in descriptors {
        judged += 1
        if CGSModeRevelation.isPlausible(
          descriptor, nativePixelWidth: native.pixelWidth, nativePixelHeight: native.pixelHeight
        ) { plausible += 1 }
      }
    }

    checks.append(Check(name: "cgs.index", outcome: indexAgreement(pairs: indexPairs)))
    checks.append(Check(name: "cgs.subset", outcome: subsetOutcome))
    var plausibilityOutcome = plausibilityRate(plausible: plausible, total: judged)
    if !plausibilitySkips.isEmpty, case let .pass(detail) = plausibilityOutcome {
      plausibilityOutcome = .pass("\(detail); not judged: \(plausibilitySkips.joined(separator: ", "))")
    }
    checks.append(Check(name: "cgs.plausibility", outcome: plausibilityOutcome))
    checks.append(Check(name: "cgs.density", outcome: densityRange(densities: densities)))

    // Without this canary, "the feature silently reveals nothing" is
    // indistinguishable from "these panels hide nothing". Any external panel on
    // the rig reveals dozens, so zero means the pipeline broke somewhere the
    // gates cannot name.
    checks.append(Check(
      name: "cgs.reveals",
      outcome: revealedTotal > 0
        ? .pass("\(revealedTotal) modes revealed across the attached displays")
        : .fail("no display revealed a single mode; the revelation pipeline is dark")
    ))
    return checks
  }

  private static func isFail(_ outcome: Outcome) -> Bool {
    if case .fail = outcome { return true }
    return false
  }

  // MARK: Rotation (SLSSetDisplayRotation)

  private static func rotationChecks(
    configurator: CoreGraphicsDisplayConfigurator,
    displays: [ConfiguredDisplay],
    applyDestructive: Bool,
    noDisplays: String
  ) -> [Check] {
    var checks: [Check] = []
    checks.append(Check(
      name: "rotation.symbol",
      outcome: configurator.canRotate
        ? .pass("SLSSetDisplayRotation resolved")
        : .fail("SLSSetDisplayRotation did not resolve from SkyLight")
    ))

    guard !displays.isEmpty else {
      checks.append(Check(name: "rotation.readback", outcome: .skip(noDisplays)))
      return checks
    }
    var readings: [String] = []
    var readbackFailure: String?
    for display in displays {
      guard let rotation = configurator.rotation(of: display.id) else {
        readbackFailure = "display \(display.id): CGDisplayRotation returned no valid rotation"
        break
      }
      readings.append("\(display.id):\(rotation.degrees)")
    }
    checks.append(Check(
      name: "rotation.readback",
      outcome: readbackFailure.map { .fail($0) }
        ?? .pass("every display reports a valid rotation (\(readings.joined(separator: " ")))")
    ))

    // RS5's measured no-ops. If a macOS update ever makes 360 or -90 a real
    // rotation, this run must find out rather than a user; the restore attempt
    // below is why it needs the operator's consent.
    guard applyDestructive else {
      checks.append(Check(
        name: "rotation.noop",
        outcome: .skip("requires --apply (calls the private setter on live hardware)")
      ))
      return checks
    }
    guard let setRotation = SkyLight.setDisplayRotation,
          let target = displays.first(where: { !$0.isBuiltIn }) ?? displays.first,
          let before = configurator.rotation(of: target.id)
    else {
      checks.append(Check(
        name: "rotation.noop", outcome: .skip("no rotatable display or missing symbol")
      ))
      return checks
    }
    var noopFailure: String?
    for degrees: Int32 in [360, -90] {
      let status = setRotation(target.id, degrees)
      let after = configurator.rotation(of: target.id)
      if status != 0 || after != before {
        noopFailure = "\(degrees) returned \(status), rotation \(before.degrees) -> \(after.map { String($0.degrees) } ?? "unreadable")"
        // Achieved state moved: put it back before reporting, or the check
        // leaves the rig in the state it exists to warn about.
        if after != before { _ = setRotation(target.id, before.degrees) }
        break
      }
    }
    checks.append(Check(
      name: "rotation.noop",
      outcome: noopFailure.map { .fail($0) }
        ?? .pass("360 and -90 both return 0 and change nothing on display \(target.id)")
    ))
    return checks
  }

  // MARK: MonitorPanel

  /// `unsafeBitCast` to an @objc protocol crashes rather than degrades if Apple
  /// reshapes these classes, so the property is checked through the ObjC
  /// runtime BEFORE anything casts.
  private static func monitorPanelChecks() -> [Check] {
    var checks: [Check] = []
    guard dlopen(
      "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY
    ) != nil,
      let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type
    else {
      checks.append(Check(
        name: "monitorpanel.class",
        outcome: .fail("MPDisplayMgr did not resolve after dlopen of MonitorPanel.framework")
      ))
      return checks
    }
    checks.append(Check(name: "monitorpanel.class", outcome: .pass("MPDisplayMgr resolved")))

    let manager = managerClass.init()
    guard manager.responds(to: NSSelectorFromString("displays")) else {
      checks.append(Check(
        name: "monitorpanel.displays",
        outcome: .fail("MPDisplayMgr no longer responds to -displays")
      ))
      return checks
    }
    let mgr = unsafeBitCast(manager, to: MPDisplayMgr.self)
    let displays = mgr.displays() ?? []
    guard let first = displays.first else {
      checks.append(Check(
        name: "monitorpanel.displays",
        outcome: .fail("MPDisplayMgr enumerates zero displays on a machine with panels attached")
      ))
      return checks
    }
    checks.append(Check(
      name: "monitorpanel.displays", outcome: .pass("\(displays.count) MPDisplay entries")
    ))

    let object = first as AnyObject
    var failures: [String] = []
    for name in ["displayID", "hasHDRModes", "preferHDRModes"]
    where class_getProperty(object_getClass(object), name) == nil {
      failures.append("\(name) is no longer a declared property")
    }
    if !object.responds(to: NSSelectorFromString("preferHDRModes")) {
      failures.append("no -preferHDRModes getter")
    }
    if !object.responds(to: NSSelectorFromString("setPreferHDRModes:")) {
      failures.append("no -setPreferHDRModes: setter")
    }
    checks.append(Check(
      name: "monitorpanel.properties",
      outcome: failures.isEmpty
        ? .pass("displayID, hasHDRModes and preferHDRModes are properties with live accessors")
        : .fail(failures.joined(separator: "; "))
    ))
    return checks
  }

  // MARK: DisplayServices

  private static func displayServicesChecks(
    displays: [ConfiguredDisplay], applyDestructive: Bool, isFiltered: Bool
  ) -> [Check] {
    var missing: [String] = []
    if !DisplayServices.resolvedGetter { missing.append("DisplayServicesGetBrightness") }
    if !DisplayServices.resolvedSetter { missing.append("DisplayServicesSetBrightness") }
    let symbols = Check(
      name: "displayservices.symbols",
      outcome: missing.isEmpty
        ? .pass("get and set both resolved")
        : .fail("\(missing.joined(separator: ", ")) did not resolve")
    )

    // Read from the built-in: the one panel DisplayServices answers for on
    // every machine this app runs on. Every early exit still names the
    // roundtrip check, because a check that disappears is a silent pass.
    func pair(_ read: Outcome, roundtrip: Outcome) -> [Check] {
      [symbols,
       Check(name: "displayservices.read", outcome: read),
       Check(name: "displayservices.roundtrip", outcome: roundtrip)]
    }
    guard let builtIn = displays.first(where: \.isBuiltIn) else {
      let reason = isFiltered
        ? "the built-in display is outside the --display filter"
        : "no built-in display attached"
      return pair(.skip(reason), roundtrip: .skip(reason))
    }
    guard let value = DisplayServices.getBrightness(for: builtIn.id) else {
      return pair(
        .fail("get returned nothing for the built-in display"),
        roundtrip: .skip("unreachable while the read fails")
      )
    }
    let read: Outcome = (0.0 ... 1.0).contains(value)
      ? .pass("built-in reads \(value)")
      : .fail("built-in reads \(value), outside 0...1")

    guard applyDestructive else {
      return pair(
        read, roundtrip: .skip("requires --apply (writes brightness, even if to its current value)")
      )
    }
    // Same value back, so the panel never visibly moves. What is tested is that
    // a set is OBSERVABLE by a get, the pair every controller trusts.
    let wrote = DisplayServices.setBrightness(value, for: builtIn.id)
    let reread = DisplayServices.getBrightness(for: builtIn.id)
    return pair(read, roundtrip: wrote && reread.map({ abs($0 - value) < 0.01 }) == true
      ? .pass("set \(value) observed back by get")
      : .fail("set returned \(wrote), reread \(reread.map { String($0) } ?? "nothing")"))
  }

  // MARK: DDC reply frames

  /// The transports validate every Get VCP reply through `DDCReplyFrame`, so a
  /// read that returns a parsed value IS the frame-layout check. A panel that
  /// does not answer reads cannot exercise it, and says so.
  private static func ddcChecks(
    panels: [(name: String, writer: any DDCWriting)]
  ) async -> [Check] {
    guard !panels.isEmpty else {
      return [Check(name: "ddc.reply", outcome: .skip("no DDC-capable external displays"))]
    }
    var exercised: [String] = []
    var skipped: [String] = []
    var failure: String?
    for panel in panels {
      guard let reply = await panel.writer.read(command: 0x10) else {
        skipped.append(panel.name)
        continue
      }
      guard reply.max > 0, reply.current <= reply.max else {
        failure = "\(panel.name): frame parsed but current \(reply.current) / max \(reply.max) is not a sane luminance pair"
        break
      }
      exercised.append("\(panel.name) \(reply.current)/\(reply.max)")
    }
    if let failure { return [Check(name: "ddc.reply", outcome: .fail(failure))] }
    if exercised.isEmpty {
      return [Check(
        name: "ddc.reply",
        outcome: .skip(
          "no attached panel answers reads (\(skipped.joined(separator: ", "))); the reply-frame layout was NOT exercised this run"
        )
      )]
    }
    var detail = "valid VCP 0x10 reply from \(exercised.joined(separator: ", "))"
    if !skipped.isEmpty {
      detail += "; not exercised on \(skipped.joined(separator: ", ")) (no read answer)"
    }
    return [Check(name: "ddc.reply", outcome: .pass(detail))]
  }
}
