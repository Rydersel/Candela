import CandelaKit
import CoreGraphics
import Foundation

// Replays a recorded log through candidate exposure models and scores them with
// the gate's own statistics.
//
// The point of the instrument: iterating against the shipped app costs a deploy
// plus a multi-day soak to read one number. Replaying costs seconds, and one
// log scores every future variant.
//
// Two controls run before any variant is scored (MP8). If replay cannot
// reproduce what the capture tool computed live, the log is lossy or the replay
// is wrong, and everything downstream is arithmetic on noise.

let arguments = Array(CommandLine.arguments.dropFirst())
var directory = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Candela/model-replay")
var fitFraction = 0.6
var topApps = 8
// Read from nonisolated scoring helpers; written once during argument parsing,
// before any of them run.
nonisolated(unsafe) var objective = "rmse"
/// Key prefixes of the displays whose records drive the FIT. Empty means all.
///
/// A panel showing static content is near-degenerate for fitting: its records
/// are all the same picture, so it constrains little while still pulling the
/// joint objective. It stays in the reporting either way, and on this rig it is
/// still the only rotated panel and therefore the only transform check.
var fitDisplays: [String] = []

var index = 0
while index < arguments.count {
  let flag = arguments[index]
  index += 1
  func value() -> String {
    guard index < arguments.count else {
      print("missing value for \(flag)")
      exit(2)
    }
    defer { index += 1 }
    return arguments[index]
  }
  switch flag {
  case "--log": directory = URL(fileURLWithPath: value())
  case "--fit-fraction": fitFraction = Double(value()) ?? 0.6
  case "--top-apps": topApps = Int(value()) ?? 8
  case "--objective": objective = value()
  case "--fit-displays":
    fitDisplays = value().split(separator: ",").map(String.init)
  default:
    print("""
      candela-model-fit: score candidate exposure models against a recorded log

        --log <dir>            replay log directory
        --fit-fraction <f>     temporal split; leading fraction fits, rest scores (default 0.6)
        --top-apps <n>         how many apps get a fitted prior (default 8)
        --objective <name>     rmse (default) or pearson
        --fit-displays <k,..>  key prefixes whose records drive the fit (default: all)
      """)
    exit(2)
  }
}

// MARK: - Statistics

func pearson(_ x: [Double], _ y: [Double]) -> Double? {
  let n = Double(x.count)
  let mx = x.reduce(0, +) / n
  let my = y.reduce(0, +) / n
  var cov = 0.0, vx = 0.0, vy = 0.0
  for i in x.indices {
    let dx = x[i] - mx, dy = y[i] - my
    cov += dx * dy
    vx += dx * dx
    vy += dy * dy
  }
  guard vx > 0, vy > 0 else { return nil }
  return min(1, max(-1, cov / (vx * vy).squareRoot()))
}

func averageRanks(_ values: [Double]) -> [Double] {
  let ascending = values.indices.sorted {
    values[$0] == values[$1] ? $0 < $1 : values[$0] < values[$1]
  }
  var ranks = [Double](repeating: 0, count: values.count)
  var start = 0
  while start < ascending.count {
    var end = start
    while end + 1 < ascending.count, values[ascending[end + 1]] == values[ascending[start]] {
      end += 1
    }
    let average = Double(start + end) / 2
    for position in start...end { ranks[ascending[position]] = average }
    start = end + 1
  }
  return ranks
}

func hottest(_ values: [Double], _ count: Int) -> [Int] {
  Array(
    values.indices.sorted { values[$0] == values[$1] ? $0 < $1 : values[$0] > values[$1] }
      .prefix(count))
}

func hottestMultiple(_ values: [Double]) -> Double {
  let mean = values.reduce(0, +) / Double(values.count)
  guard mean > 0, let peak = values.max() else { return 0 }
  return peak / mean
}

func agreement(_ a: [Double], _ b: [Double], _ depth: Int) -> Int {
  Set(hottest(a, depth)).intersection(Set(hottest(b, depth))).count
}

// MARK: - Prepared records
//
// Window coverage is the expensive part and does not depend on the parameters,
// so it is computed once. That means this file walks the windows itself rather
// than calling ExposureModel, which is exactly the duplication that could make
// the harness fit a different model than the one that ships. `verifyPrepared`
// below is the control for it and runs before any fitting.

struct PreparedWindow {
  let owner: String
  let layer: Int
  let coverage: [Double]
}

struct Prepared {
  let windows: [PreparedWindow]
  /// Menu-bar-sized system chrome only. The Dock and Wallpaper entries are
  /// full-display backing windows; admitting those would blanket every cell
  /// and delete the wallpaper term, so they are filtered by area rather than
  /// by layer, which cannot tell them apart.
  let chrome: [PreparedWindow]
  let backdrop: [Double]?
  let dark: Bool
  let measured: [Double]
  let elapsed: Double
  let recordedBaseline: [Double]
  let key: String

  /// `ExposureModel.admitted(_:)`, mirrored. Any drift between the two is a
  /// divergence the equivalence control will report, so this reads as closely
  /// to the original as Swift allows.
  ///
  /// Applied to the WHOLE list rather than to chrome alone. `prepare()` used to
  /// filter `windows` down to `includedLayers` before this ran, which silently
  /// discarded sub-zero-layer system windows that the shipped model
  /// fraction-tests and admits. Notification Center, at 3.1% coverage of the
  /// built-in and exactly zero on both externals, was precisely that: it made
  /// the control fail on that one panel, in the two parameterisations carrying
  /// a chrome limit, on every sampled record.
  private func admits(_ window: PreparedWindow, _ parameters: ExposureModelParameters) -> Bool {
    if ExposureModel.includedLayers.contains(window.layer) { return true }
    // Below the range only, and never above it, for the reason
    // `ExposureModel.admitted(_:)` states: below is chrome a coverage bound can
    // separate, above is transient pop-ups it cannot.
    guard window.layer < ExposureModel.includedLayers.lowerBound,
      let limit = parameters.chromeCoverageLimit
    else { return false }
    let fraction = window.coverage.reduce(0, +) / Double(PanelGrid.cellCount)
    return fraction > 0 && fraction < limit
  }

  func modelled(_ parameters: ExposureModelParameters) -> [Double] {
    let prior = dark ? parameters.darkAppearancePrior : parameters.lightAppearancePrior
    // Admission is driven by the PARAMETERS, never by a separate flag. A
    // parallel boolean was its own divergence source: `.baseline` carries no
    // chrome limit, so the shipped model admitted none while this path appended
    // it anyway, and the equivalence control caught exactly one mismatch per
    // record. One switch, one meaning.
    //
    // Chrome is BEHIND every app window: it is what a window occludes, never
    // the reverse, so it goes last, matching `inputsIncludingChrome`, which is
    // `windows + chrome`.
    let all = (windows + chrome).filter { admits($0, parameters) }
    switch parameters.compositing {
    case .summedCoverage:
      var coverage = [Double](repeating: 0, count: PanelGrid.cellCount)
      for window in all {
        for cell in coverage.indices { coverage[cell] += window.coverage[cell] }
      }
      return (0..<PanelGrid.cellCount).map { cell in
        let covered = min(1, max(0, coverage[cell]))
        return covered * prior + (1 - covered) * (backdrop?[cell] ?? prior)
      }
    case .topmostWins:
      var remaining = [Double](repeating: 1, count: PanelGrid.cellCount)
      var accumulated = [Double](repeating: 0, count: PanelGrid.cellCount)
      for window in all {
        let luminance =
          parameters.appPriors[window.owner] ?? parameters.layerPriors[window.layer] ?? prior
        for cell in 0..<PanelGrid.cellCount {
          let claim = min(window.coverage[cell], remaining[cell])
          guard claim > 0 else { continue }
          accumulated[cell] += claim * luminance
          remaining[cell] = max(0, remaining[cell] - claim)
        }
      }
      return (0..<PanelGrid.cellCount).map { cell in
        min(1, max(0, accumulated[cell] + remaining[cell] * (backdrop?[cell] ?? prior)))
      }
    }
  }
}

func prepare(_ record: ModelReplayRecord) -> Prepared {
  let transform = record.transform
  // NOT filtered by layer here. Admission depends on the parameters and on the
  // coverage fraction, so it belongs at `modelled` time next to the chrome
  // rule, or the fast path drops windows the shipped model keeps.
  let windows = record.windows.map(\.snapshot)
    .map {
      PreparedWindow(
        owner: $0.ownerName, layer: $0.layer,
        coverage: transform.coverage(ofDisplayRect: $0.bounds))
    }
  // Filtered by COVERAGE OF THIS DISPLAY, not by area compared against it.
  // Chrome windows in a record belong to every display, so an area test admitted
  // the BUILT-IN panel's full-display backing windows onto the ultrawide purely
  // because a laptop screen is smaller than half of it: measured 0.425 of the
  // MAG's area, kept, and contributing exactly zero coverage. Three of the four
  // "chrome layers" were ghosts of another display. Coverage is display-local by
  // construction, and the upper bound still keeps a full-display backdrop from
  // blanketing every cell and deleting the wallpaper term.
  let chrome = record.chrome.map(\.snapshot)
    // NOT filtered here. The limit is a parameter, and applying it at prepare
    // time made the harness treat it as a boolean: changing a rung's limit to
    // 0.02 left the scores byte-identical to 0.5 and the equivalence control
    // still printed yes, because its probe hardcoded the same literal. One
    // switch, one meaning, means the value has to be read where it is used.
    .map {
      // The REAL owner name, not a synthesised "chrome<layer>" one. Renaming
      // made this path diverge from `ExposureModel`, which resolves luminance
      // by the window's actual owner, so the equivalence control could never
      // pass. Per-layer separation is already what `layerPriors` provides, and
      // chrome windows carry distinct layers, so the rename bought nothing and
      // cost the control.
      PreparedWindow(
        owner: $0.ownerName, layer: $0.layer,
        coverage: transform.coverage(ofDisplayRect: $0.bounds))
    }
  return Prepared(
    windows: windows, chrome: chrome, backdrop: record.wallpaper, dark: record.appearanceIsDark,
    measured: record.measuredPanel, elapsed: record.elapsed,
    recordedBaseline: record.modelledBaseline, key: record.display.persistenceKey)
}

/// Accumulated (measured, modelled) maps over a set of records, in the same
/// exposure unit the shipped comparison uses.
func accumulate(
  _ records: [Prepared], _ parameters: ExposureModelParameters
) -> ([Double], [Double]) {
  var measured = [Double](repeating: 0, count: PanelGrid.cellCount)
  var modelled = [Double](repeating: 0, count: PanelGrid.cellCount)
  for record in records {
    let grid = record.modelled(parameters)
    for cell in 0..<PanelGrid.cellCount {
      measured[cell] += record.measured[cell] * record.elapsed
      modelled[cell] += grid[cell] * record.elapsed
    }
  }
  return (measured, modelled)
}

/// Higher is better, for both objectives.
///
/// **Pearson cannot fit absolute luminance, and that is not a subtlety.** It is
/// invariant under `y -> a*y + b`, so scaling and offsetting every prior leaves
/// it unmoved. The ground-truth harness demonstrated it directly: windows of
/// known luminance 0.85, 0.35 and 0.05 were recovered in the right ORDER as
/// 1.00, 0.61 and 0.25, biased high throughout. Meanwhile MP2's bar is the
/// hottest multiple, which an offset does change. Fitting on a scale-blind
/// objective and judging on a scale-sensitive one is incoherent, and it is what
/// produced a fit that drove the dark prior to 0.000 and overshot the peak.
///
/// Both maps are in the same unit, luminance times seconds, so a residual
/// between them is meaningful as it stands. RMSE is normalised by the measured
/// mean only so the number reads comparably across panels.
func score(
  _ records: [Prepared], _ parameters: ExposureModelParameters
) -> Double {
  if objective == "pearson" {
    let (measured, modelled) = accumulate(records, parameters)
    return pearson(measured, modelled) ?? -.infinity
  }
  // Fit on PER-RECORD residuals, not on the accumulated map.
  //
  // Each instant is an observation; summing first throws away which app was
  // where at the time. The ground-truth harness showed exactly what that costs:
  // with three known luminances rotating through three tiles, every cell ends
  // up averaging all three apps, so the summed map constrains only their SUM
  // and the fit compresses all three toward the mean (0.85, 0.35 and 0.05 came
  // back as 0.64, 0.41 and 0.19). The report below still uses accumulated maps,
  // because accumulation is what the shipped comparison does.
  var squared = 0.0
  var total = 0.0
  var count = 0
  for record in records {
    let grid = record.modelled(parameters)
    for cell in 0..<PanelGrid.cellCount {
      let delta = record.measured[cell] - grid[cell]
      squared += delta * delta
      total += record.measured[cell]
      count += 1
    }
  }
  guard count > 0, total > 0 else { return -.infinity }
  let mean = total / Double(count)
  return -((squared / Double(count)).squareRoot() / mean)
}

/// Mean per-display Pearson.
///
/// Parameters are fitted JOINTLY across panels, because an app's luminance is a
/// property of the app and not of the display it happens to be on. Fitting one
/// panel at a time made an app prior perfectly confounded with the appearance
/// prior whenever that panel ran a single app, which is exactly the rig's
/// current state: Brave on the Dell, Ghostty on the MAG.
///
/// The maps themselves are never pooled. Summing two panels' exposure into one
/// 240-cell grid would invent a display that does not exist.
func scoreJointly(
  _ groups: [[Prepared]], _ parameters: ExposureModelParameters
) -> Double {
  var total = 0.0
  var counted = 0
  // `.isFinite`, never a magic number. `-1` was previously both the "no data"
  // sentinel and the score of a normalised RMSE of 1.0. Measured baseline nRMSE
  // on this rig is 1.13 to 1.29, so EVERY real group was silently discarded and
  // the joint objective sat on a sentinel plateau: the header printed "joint fit
  // across 2 panels" while one panel contributed nothing, ever, and the
  // objective rewarded a candidate for breaking a group out of the average.
  for group in groups where !group.isEmpty {
    let value = score(group, parameters)
    if value.isFinite {
      total += value
      counted += 1
    }
  }
  return counted > 0 ? total / Double(counted) : -.infinity
}

// MARK: - Load

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
  isDirectory.boolValue
else {
  print("not a log directory: \(directory.path)")
  print("--log takes the DIRECTORY the capture wrote, not one of its .jsonl files.")
  exit(2)
}
let (records, skipped) = try ModelReplayLog.read(directory: directory)
print("log: \(directory.path)")
print("records \(records.count), skipped \(skipped)")
guard !records.isEmpty else {
  print("nothing to score")
  exit(1)
}

// Grouped by identity AND GEOMETRY, not identity alone.
//
// A panel's pixel dimensions can change mid-session: a synthesised size, a
// resolution change, a dock cycle. The capture request shape follows the
// dimensions, so the measurement bins into panel-native cells differently
// either side of it. Grouping on the EDID key alone would merge two different
// geometries into one 240-cell accumulated map, and every control would still
// pass, because each control recomputes from each record's OWN recorded
// metadata. Splitting preserves the data and makes the split visible; merging
// would have destroyed it silently.
/// The chrome coverage limit every rung from V2 onward uses. Named once so the
/// ranking filter and the admission rule cannot drift apart.
let ladderChromeLimit = 0.5

var byDisplay: [String: [ModelReplayRecord]] = [:]
for record in records {
  let shape = record.display
  byDisplay[
    "\(shape.persistenceKey)|\(shape.pixelWidth)x\(shape.pixelHeight)@\(shape.rotation.rawValue)",
    default: []
  ].append(record)
}
let identities = Set(records.map(\.display.persistenceKey))
if byDisplay.count > identities.count {
  print(
    "\nNOTE: \(identities.count) panel identities produced \(byDisplay.count) geometry groups.")
  print("A panel changed size or rotation mid-log; its records are scored separately.")
  for (key, group) in byDisplay.sorted(by: { $0.value.count > $1.value.count }) {
    print("  \(key.prefix(8))  \(key.split(separator: "|").last ?? "")  \(group.count) records")
  }
}

// MARK: - Controls (MP8)

let tolerance = 1.0 / pow(10.0, Double(ModelReplayLog.decimals - 1))

func runControls(_ raw: [ModelReplayRecord]) -> Bool {
  var replayFailures = 0
  var transformFailures = 0
  for record in raw {
    let replayed = ExposureModel.modelledGrid(
      inputs: record.inputs, through: record.transform, parameters: .baseline)
    if (0..<PanelGrid.cellCount).contains(where: {
      abs(replayed[$0] - record.modelledBaseline[$0]) > tolerance
    }) { replayFailures += 1 }

    let derived = record.transform.panelNativeGrid(
      fromDisplayGrid: record.capture.grid, cols: record.capture.cols, rows: record.capture.rows)
    if (0..<PanelGrid.cellCount).contains(where: {
      abs(derived[$0] - record.measuredPanel[$0]) > tolerance
    }) { transformFailures += 1 }
  }
  print("  control: replay reproduces live model      \(raw.count - replayFailures)/\(raw.count)")
  print("  control: transform reproduces live measure \(raw.count - transformFailures)/\(raw.count)")
  return replayFailures == 0 && transformFailures == 0
}

/// The prepared fast path must agree with the shipped model, or the harness is
/// fitting something other than what ships.
func verifyPrepared(_ raw: [ModelReplayRecord]) -> Bool {
  // Restored after being deleted by accident. A rewrite of the order check
  // below removed this loop and left its declaration, its print and its return
  // in place, so the control reported `yes` unconditionally: a claim whose
  // failure mode is silence, sitting on the verdict artifact. The compiler said
  // so ("variable 'mismatches' was never mutated", "will never be executed")
  // and nobody read the warning.
  var mismatches = 0
  var probes: [ExposureModelParameters] = [.baseline]
  for compositing in [ExposureModelParameters.Compositing.summedCoverage, .topmostWins] {
    var probe = ExposureModelParameters.baseline
    probe.compositing = compositing
    probe.chromeCoverageLimit = compositing == .topmostWins ? ladderChromeLimit : 0.08
    // Priors drawn from the log's own owners and layers, so the probe cannot
    // miss for want of an app that happens not to be on this panel.
    for (index, owner) in Set(raw.flatMap { $0.windows.map(\.owner) }).sorted().enumerated() {
      probe.appPriors[owner] = Double(index % 5) / 4.0
    }
    for (index, layer) in Set(raw.flatMap { $0.chrome.map(\.layer) }).sorted().enumerated() {
      probe.layerPriors[layer] = Double(index % 4) / 3.0
    }
    probes.append(probe)
  }
  // Order sensitivity is a property of the CODE, not of a log: two windows that
  // do not overlap are legitimately order-invariant, and a desktop of tiled
  // windows is entirely so. An earlier version of this control probed with
  // hard-coded app names (Ghostty, Zed, layer 24); on a panel where none of
  // them covered anything it reported "order-blind" and REFUSED THE WHOLE
  // PANEL, dropping the rotated Dell and then printing a false "no coverage"
  // line for an app with 45 windows on it.
  //
  // What is checkable here is narrower and still worth checking: where a record
  // does contain overlapping covered windows, reversing them must change the
  // result. Where it contains none, the answer is "not applicable", never
  // "failed". `ExposureModelCompositingTests` pins the code property itself.
  // Sampled ACROSS the log, not from its head. A divergence that begins later
  // was invisible: mutating a record at index 60 left the control printing
  // "yes" while every rung scored on 154 records the harness and the shipped
  // model disagreed about. The release binary makes the wider sample free.
  let step = max(1, raw.count / 60)
  var indices = Array(Swift.stride(from: 0, to: raw.count, by: step))
  // The last record is always included: `to:` skips it on an even count, and a
  // divergence that begins in the final records is exactly the shape that
  // survives a head sample.
  if let last = indices.last, last != raw.count - 1, raw.count > 0 {
    indices.append(raw.count - 1)
  }
  let sampled = indices.map { raw[$0] }
  for record in sampled {
    let prepared = prepare(record)
    for candidate in probes {
      // Both chrome settings: V2 onward all composite with chrome admitted, and
      // that path previously had no control and no test anywhere.
      // Kit is handed the chrome-bearing input whenever the candidate admits
      // chrome, so both sides see the same window list under the same rule.
      let fast = prepared.modelled(candidate)
      let reference = ExposureModel.modelledGrid(
        inputs: candidate.chromeCoverageLimit == nil
          ? record.inputs : record.inputsIncludingChrome,
        through: record.transform, parameters: candidate)
      if (0..<PanelGrid.cellCount).contains(where: { abs(fast[$0] - reference[$0]) > 1e-9 }) {
        mismatches += 1
      }
    }
  }

  var orderTested = 0
  var orderBlind = 0
  for record in sampled {
    let prepared = prepare(record)
    let covering = prepared.windows.filter { $0.coverage.contains { $0 > 0 } }
    guard covering.count > 1 else { continue }
    // Order can only matter where windows genuinely OVERLAP: two covered
    // windows sitting side by side are order-invariant and correctly so, which
    // is exactly what a tiled desktop looks like. Requiring only "more than one
    // covered window" still failed the Dell for having a legitimately
    // order-independent layout.
    var stacked = [Double](repeating: 0, count: PanelGrid.cellCount)
    for window in covering {
      for cell in 0..<PanelGrid.cellCount { stacked[cell] += window.coverage[cell] }
    }
    guard stacked.contains(where: { $0 > 1.000_001 }) else { continue }
    // Overlaps between windows of the SAME owner are order-invariant in the
    // model too, because it resolves luminance by owner. Such a record cannot
    // distinguish an order-blind harness from an order-independent layout.
    guard Set(covering.map(\.owner)).count > 1 else { continue }
    // Distinct priors drawn from THIS record's own owners, so the probe cannot
    // miss for want of an app that happens not to be on this panel.
    var probe = ExposureModelParameters.baseline
    probe.compositing = .topmostWins
    // Per distinct OWNER, not per window: assigning by window index let
    // `[A, A, B, B]` give A and B the same value, which reads as order-blind on
    // an ordinary desktop.
    for (index, owner) in Set(covering.map(\.owner)).sorted().enumerated() {
      probe.appPriors[owner] = index.isMultiple(of: 2) ? 0.05 : 0.95
    }
    var reversed = record
    reversed.windows.reverse()
    let forward = prepared.modelled(probe)
    let backward = prepare(reversed).modelled(probe)
    orderTested += 1
    if (0..<PanelGrid.cellCount).allSatisfy({ abs(forward[$0] - backward[$0]) < 1e-12 }) {
      orderBlind += 1
    }
  }
  // INFORMATIONAL, never fatal. Whether the harness honours window order is a
  // property of the code, pinned by ExposureModelCompositingTests
  // ("window order decides the answer, so the log may never be re-sorted").
  // Whether a given log can demonstrate it is a property of that day's windows,
  // and a tiled desktop legitimately cannot. Failing a panel for that dropped
  // the rotated Dell and then reported an app with 45 windows on it as having
  // no coverage.
  if orderTested == 0 {
    print("  note:    window order not exercised by this log (no differing-owner overlap)")
  } else if orderBlind == orderTested {
    print("  note:    window order changed nothing in \(orderTested) overlapping records")
  } else {
    print(
      "  control: window ORDER changes the model               yes (\(orderTested - orderBlind)/\(orderTested))")
  }
  let chromeSeen = sampled.contains { !$0.chrome.isEmpty }
  print(
    "  control: prepared path matches ExposureModel \(mismatches == 0 ? "yes" : "NO (\(mismatches))")"
      + " (\(sampled.count) of \(raw.count) records, \(probes.count) parameterisations, "
      + "chrome \(chromeSeen ? "present" : "ABSENT from this log"))")
  return mismatches == 0
}

// MARK: - Fitting

/// Coordinate refinement over `0...1`, maximising Pearson on the fit split
/// (MP3, fixed before any result was seen).
func refine(
  _ start: ExposureModelParameters, keys: [(get: (ExposureModelParameters) -> Double,
    set: (inout ExposureModelParameters, Double) -> Void)],
  on groups: [[Prepared]], passes: Int = 3
) -> ExposureModelParameters {
  var best = start
  var bestScore = scoreJointly(groups, best)
  guard !keys.isEmpty else { return best }
  for pass in 0..<passes {
    let step = 0.1 / pow(2.0, Double(pass))
    for key in keys {
      let centre = key.get(best)
      var localBest = centre
      var localScore = bestScore
      for offset in stride(from: -5.0, through: 5.0, by: 1.0) {
        let candidateValue = min(1, max(0, centre + offset * step))
        var candidate = best
        key.set(&candidate, candidateValue)
        let candidateScore = scoreJointly(groups, candidate)
        if candidateScore > localScore {
          localScore = candidateScore
          localBest = candidateValue
        }
      }
      key.set(&best, localBest)
      bestScore = localScore
    }
  }
  return best
}

/// How much the objective moves when a parameter is pushed either way.
///
/// A parameter the objective is FLAT in is unidentifiable from this data: the
/// optimiser will leave it wherever it started, and printing that value implies
/// a finding the data does not contain. The smoke run reported Claude at 0.857
/// and Sublime Text at 0.714, which were simply their spread starting values;
/// both apps live on a panel that is not in this log, so no coverage of theirs
/// exists to fit against.
func sensitivity(
  _ groups: [[Prepared]], _ parameters: ExposureModelParameters,
  get: (ExposureModelParameters) -> Double,
  set: (inout ExposureModelParameters, Double) -> Void
) -> Double {
  let base = scoreJointly(groups, parameters)
  var moved = 0.0
  for delta in [-0.25, 0.25] {
    var candidate = parameters
    set(&candidate, min(1, max(0, get(parameters) + delta)))
    moved = max(moved, abs(scoreJointly(groups, candidate) - base))
  }
  return moved
}

/// MP2 as amended 2026-08-18. Three conditions, all required.
///
/// The previous predicate was `multiple >= 2.7 && top10 >= 5`, and it was broken
/// three ways, each measured on this rig before any real verdict was read:
///
/// - **One-sided.** A model that OVERSHOOTS passed. The MP3 amendment's own
///   documented-as-defective fit, 5.78x modelled against 2.99x measured, would
///   have printed PASS.
/// - **An absolute threshold against a moving target.** 2.7 was 85% of a
///   measured 3.17x. Measured on tomorrow-shaped data is 4.48x, so the same
///   constant demanded 60%. The bar loosened and nobody chose that.
/// - **A ranking half that is free at this accumulation length.** V0, the
///   shipped model, already scores 5/10 here, where over #120's four days it
///   scored 1/10. Top-10 overlap is not portable across accumulation length, so
///   the bar collapsed to the peak criterion alone.
///
/// Consequence, verified: three rungs printed PASS on an 8-record holdout from a
/// log the readiness gate refuses, including V3, which contains no per-window
/// luminance term at all and cleared the bar by driving the dark prior to 0.000.
/// The decile reached by fitting every prior DIRECTLY ON THE HOLDOUT.
///
/// Deliberate cheating, to give a failing rung a reference point: if the best
/// fit this family can produce also gains nothing, the threshold may simply be
/// unreachable on this data, which is a different finding from "the model lost".
///
/// **Not an upper bound, and must never gate a pass.** `refine` maximises the
/// objective (normalised RMSE); this counts hottest-decile overlap. They are
/// different quantities, so an honestly fitted rung can and does exceed it.
func ceilingDecile(_ hold: [Prepared], apps: [String], layers: [Int]) -> Int {
  var cheat = ExposureModelParameters.baseline
  cheat.compositing = .topmostWins
  cheat.chromeCoverageLimit = ladderChromeLimit
  for layer in layers { cheat.layerPriors[layer] = 0.5 }
  for (offset, app) in apps.enumerated() {
    cheat.appPriors[app] = Double(offset + 1) / Double(apps.count + 1)
  }
  var keys: [(get: (ExposureModelParameters) -> Double,
    set: (inout ExposureModelParameters, Double) -> Void)] = [
    (get: { $0.lightAppearancePrior }, set: { $0.lightAppearancePrior = $1 }),
    (get: { $0.darkAppearancePrior }, set: { $0.darkAppearancePrior = $1 }),
  ]
  keys += layers.map { layer in
    (get: { $0.layerPriors[layer] ?? 0.5 }, set: { $0.layerPriors[layer] = $1 })
  }
  keys += apps.map { app in
    (get: { $0.appPriors[app] ?? 0.5 }, set: { $0.appPriors[app] = $1 })
  }
  let fitted = refine(cheat, keys: keys, on: [hold], passes: 4)
  let (measured, modelled) = accumulate(hold, fitted)
  return agreement(measured, modelled, 24)
}

func passes(
  modelledPeak: Double, measuredPeak: Double, decile: Int, baselineDecile: Int,
  ceiling: Int, holdout: Int
) -> (ok: Bool, why: String) {
  guard holdout >= ExposureAccumulator.minimumSamplesForAnalysis else {
    return (false, "n<\(ExposureAccumulator.minimumSamplesForAnalysis)")
  }
  guard measuredPeak > 0 else { return (false, "flat") }
  let ratio = modelledPeak / measuredPeak
  guard ratio >= 0.85, ratio <= 1.18 else {
    return (false, String(format: "peak %.3f", ratio))
  }
  // The decile gate is decided FIRST, and the reference only ever explains a
  // failure. It can never veto a rung that cleared the bar.
  //
  // This ordering is not cosmetic. `ceilingDecile` fits on the OBJECTIVE
  // (normalised RMSE), while this compares DECILE overlap, and those are
  // different quantities: measured on the archived Dell holdout the reference
  // came out at 0/24 while an honestly fitted rung reached 6/24. Gated first,
  // that printed a rung which beat the bar by six cells as
  // "fail (ranking UNREACHABLE)", and the run card tells the reader to trust
  // that line above the others.
  func signed(_ value: Int) -> String { value >= 0 ? "+\(value)" : "\(value)" }
  if decile - baselineDecile >= 3 { return (true, "PASS") }
  // The reference is only mentioned when it is BELOW this rung's own gain;
  // saying "the bar may be unreachable" on a rung that already beat the
  // reference is the wrong-quantity comparison surviving in prose.
  if ceiling - baselineDecile < 3, ceiling <= decile {
    return (false, "decile \(signed(decile - baselineDecile)), and an objective-optimal fit on "
      + "the holdout reached only \(signed(ceiling - baselineDecile))")
  }
  return (
    false,
    "decile \(signed(decile - baselineDecile)), reference \(signed(ceiling - baselineDecile))")
}

/// Returns this rung's hottest-DECILE agreement so the next rung can be judged
/// against the baseline rather than against an absolute number.
@discardableResult
func report(_ label: String, _ records: [Prepared], _ parameters: ExposureModelParameters,
  freeParameters: Int, baselineDecile: Int?, ceiling: Int,
  fitGroups: [[Prepared]] = []) -> Int
{
  let (measured, modelled) = accumulate(records, parameters)
  let p = pearson(measured, modelled) ?? .nan
  let s = pearson(averageRanks(measured), averageRanks(modelled)) ?? .nan
  let multiple = hottestMultiple(modelled)
  let measuredMultiple = hottestMultiple(measured)
  // Reported, never gating. EM14 blocks two claims: hottestRelative, which the
  // peak ratio licenses, and hottestOwner, which needs the SINGLE hottest cell
  // to be right. No rung has ever scored above 0/1 on that, so hottestOwner
  // stays blocked whatever the gate says about the peak.
  let top1 = agreement(measured, modelled, 1)
  let top24 = agreement(measured, modelled, 24)

  // Free parameters are counted as those the objective can actually move.
  // The printed count is what a reader uses to judge overfitting, and a prior
  // the data cannot constrain is not a degree of freedom that was spent.
  var effective = -1
  if !fitGroups.isEmpty {
    var live = 0
    for app in parameters.appPriors.keys
    where sensitivity(fitGroups, parameters, get: { $0.appPriors[app] ?? 0 },
      set: { $0.appPriors[app] = $1 }) > 1e-6 { live += 1 }
    for layer in parameters.layerPriors.keys
    where sensitivity(fitGroups, parameters, get: { $0.layerPriors[layer] ?? 0 },
      set: { $0.layerPriors[layer] = $1 }) > 1e-6 { live += 1 }
    for probe in [
      (get: { (p: ExposureModelParameters) in p.lightAppearancePrior },
       set: { (p: inout ExposureModelParameters, v: Double) in p.lightAppearancePrior = v }),
      (get: { (p: ExposureModelParameters) in p.darkAppearancePrior },
       set: { (p: inout ExposureModelParameters, v: Double) in p.darkAppearancePrior = v }),
    ] where sensitivity(fitGroups, parameters, get: probe.get, set: probe.set) > 1e-6 {
      live += 1
    }
    effective = live
  }

  let verdict = baselineDecile.map {
    passes(modelledPeak: multiple, measuredPeak: measuredMultiple, decile: top24,
      baselineDecile: $0, ceiling: ceiling, holdout: records.count)
  }
  // A prior resting on a clamp is a misspecification signal, not a fit.
  // Every fitted family, not just apps: V2 fits nothing BUT layer priors, so
  // omitting them meant the flag could not fire on the rung that needed it most.
  // Only priors the objective can actually move. A marker that fires on every
  // rung because an unidentifiable prior sits at its start value discriminates
  // nothing, and the row never said WHICH prior it meant.
  var pinnedNames: [String] = []
  if !fitGroups.isEmpty {
    for (app, value) in parameters.appPriors where value <= 0 || value >= 1 {
      if sensitivity(fitGroups, parameters, get: { $0.appPriors[app] ?? 0 },
        set: { $0.appPriors[app] = $1 }) > 1e-6 { pinnedNames.append(app) }
    }
    for (layer, value) in parameters.layerPriors where value <= 0 || value >= 1 {
      if sensitivity(fitGroups, parameters, get: { $0.layerPriors[layer] ?? 0 },
        set: { $0.layerPriors[layer] = $1 }) > 1e-6 { pinnedNames.append("layer \(layer)") }
    }
    if parameters.darkAppearancePrior <= 0 || parameters.darkAppearancePrior >= 1,
      sensitivity(fitGroups, parameters, get: { $0.darkAppearancePrior },
        set: { $0.darkAppearancePrior = $1 }) > 1e-6 { pinnedNames.append("dark") }
    // The light prior is the one the run card asks the operator to exercise, so
    // it is the one most likely to land on a clamp during the session. Its check
    // was dropped when this block was rewritten.
    if parameters.lightAppearancePrior <= 0 || parameters.lightAppearancePrior >= 1,
      sensitivity(fitGroups, parameters, get: { $0.lightAppearancePrior },
        set: { $0.lightAppearancePrior = $1 }) > 1e-6 { pinnedNames.append("light") }
  }
  let pinned = !pinnedNames.isEmpty
  print(
    String(
      format: "  %-30@ params %2d/%-2d r %6.3f  rho %6.3f  peak %.2fx/%.2fx = %.2f  top1 %d/1  decile %2d/24  %@%@",
      label as NSString, effective >= 0 ? effective : freeParameters, freeParameters,
      p, s, multiple, measuredMultiple,
      measuredMultiple > 0 ? multiple / measuredMultiple : .nan, top1, top24,
      (verdict.map { $0.ok ? "PASS" : "fail (\($0.why))" } ?? "baseline") as NSString,
      (pinned ? "  [pinned at a clamp: \(pinnedNames.joined(separator: ", "))]" : "")
        as NSString))
  return top24
}

// MARK: - Run

struct DisplayRun {
  let key: String
  let shape: ModelReplayRecord.Display
  let fit: [Prepared]
  let hold: [Prepared]
}

var runs: [DisplayRun] = []
for (key, raw) in byDisplay.sorted(by: { $0.value.count > $1.value.count }) {
  let shape = raw[0].display
  print("\n=== \(shape.persistenceKey)  \(shape.pixelWidth)x\(shape.pixelHeight) rot \(shape.rotation.rawValue)  \(raw.count) records")
  guard runControls(raw), verifyPrepared(raw) else {
    print("  controls failed; refusing to score variants on this log")
    continue
  }
  let prepared = raw.map(prepare)
  let split = max(1, min(prepared.count - 1, Int(Double(prepared.count) * fitFraction)))
  print("  fit \(split) records, holdout \(prepared.count - split) records")
  runs.append(
    DisplayRun(
      key: key, shape: shape, fit: Array(prepared.prefix(split)),
      hold: Array(prepared.suffix(from: split))))
}

guard !runs.isEmpty else {
  print("\nno display passed its controls")
  exit(1)
}

let fitGroups =
  fitDisplays.isEmpty
  ? runs.map(\.fit)
  : runs.filter { run in fitDisplays.contains { run.key.hasPrefix($0) } }.map(\.fit)
if !fitDisplays.isEmpty {
  let fitting = runs.filter { run in fitDisplays.contains { run.key.hasPrefix($0) } }
  print("\nfitting on \(fitting.count) of \(runs.count) panels: \(fitting.map { String($0.key.prefix(8)) })")
  print("all panels are still scored and reported below.")
}
guard !fitGroups.isEmpty else {
  print("--fit-displays matched no panel in this log")
  exit(1)
}

// Which layers and apps are worth a parameter, measured over every panel.
var layerWeight: [Int: Double] = [:]
var appWeight: [String: Double] = [:]
// Selected from the FIT SPLIT of the FITTED panels only. Reading the holdout to
// decide which apps get free parameters is a softer form of the failure MP14
// exists to prevent, and reading panels that --fit-displays removed lets an app
// that never appears in the fit earn a parameter applied to the holdout.
for group in fitGroups {
  for record in group {
    for window in record.windows {
      let mass = window.coverage.reduce(0, +) * record.elapsed
      layerWeight[window.layer, default: 0] += mass
      appWeight[window.owner, default: 0] += mass
    }
    // Chrome layers count toward the LAYER table only. Every ordinary window is
    // layer 0, so without these the table is always empty and V2 is byte
    // identical to V1 while printing as a rung that ran. On this rig exactly
    // one chrome layer survives the coverage filter (the menu-bar strips, at
    // fraction ~0.085); the Dock, Wallpaper and WindowServer backdrops sit at
    // exactly 1.0 and are refused. The table can also pick up ordinary
    // non-zero app layers such as 3 when any are present, which is why the
    // rung is not purely about chrome.
    for window in record.chrome {
      // Only ADMISSIBLE coverage counts. Ranking by raw coverage let the Dock
      // and the WindowServer backdrop, both at exactly 1.0 and therefore
      // refused at every limit, take the top two of four slots on weight ~12x
      // the menu bar's, squeezing out real app layers and printing as
      // UNIDENTIFIABLE every run. That biases the ladder toward no-go.
      let fraction = window.coverage.reduce(0, +) / Double(PanelGrid.cellCount)
      // The LADDER's limit, not merely "less than the whole display". A chrome
      // layer landing between the two bounds would otherwise take a ranking slot
      // it can never be admitted into, which is the dead-slot defect one data
      // shape away.
      guard fraction > 0, fraction < ladderChromeLimit else { continue }
      layerWeight[window.layer, default: 0] += window.coverage.reduce(0, +) * record.elapsed
    }
  }
}
let layers = layerWeight.filter { $0.key != 0 }.sorted { $0.value > $1.value }.prefix(4).map(\.key)
// Apps with no coverage on these panels cannot be fitted, however often they
// appear in the window list. `coverage` is already clipped to the display, so
// an app living on another panel scores ~0 here.
let heaviest = appWeight.values.max() ?? 0
let apps = appWeight.filter { $0.value > heaviest * 0.01 }
  .sorted { $0.value > $1.value }.prefix(topApps).map(\.key)
let excluded = appWeight.filter { $0.value <= heaviest * 0.01 }
  .sorted { $0.value > $1.value }.map(\.key)

print("\n=== joint fit across \(runs.count) panels")
print("  layers: \(layers)")
print("  apps:   \(apps)")
if !excluded.isEmpty {
  print("  excluded (no coverage on the FITTED panels): \(excluded)")
}

var v1 = ExposureModelParameters.baseline
v1.compositing = .topmostWins

// V2 is MP4's stated bet: admit system chrome and give each chrome LAYER its
// own luminance. Chrome enters here rather than at the end of the ladder,
// because the layer table has nothing else to fit on an ordinary desktop.
var v2 = v1
v2.chromeCoverageLimit = ladderChromeLimit
for layer in layers { v2.layerPriors[layer] = 0.5 }
v2 = refine(
  v2,
  keys: layers.map { layer in
    (get: { $0.layerPriors[layer] ?? 0.5 }, set: { $0.layerPriors[layer] = $1 })
  }, on: fitGroups)

let v3 = refine(
  v2,
  keys: [
    (get: { $0.lightAppearancePrior }, set: { $0.lightAppearancePrior = $1 }),
    (get: { $0.darkAppearancePrior }, set: { $0.darkAppearancePrior = $1 }),
  ], on: fitGroups)

// Spread the starting values rather than sharing one. Coordinate descent from a
// single shared start can sit still in a flat region and report "no app
// differs", which is a statement about the optimiser rather than the data.
var v4 = v3
for (offset, app) in apps.enumerated() {
  v4.appPriors[app] = Double(offset + 1) / Double(apps.count + 1)
}
v4 = refine(
  v4,
  keys: apps.map { app in
    (get: { $0.appPriors[app] ?? 0.5 }, set: { $0.appPriors[app] = $1 })
  }, on: fitGroups, passes: 4)

let ladder:
  [(String, ExposureModelParameters, Int)] = [
    // Declared counts include the appearance priors on every rung, because the
    // identifiable count probes them on every rung. Comparing a numerator over
    // {apps, layers, light, dark} against a denominator that omitted the
    // appearance pair printed "1/0" for the shipped model.
    ("V0 baseline", .baseline, 2),
    ("V1 z-order only", v1, 2),
    ("V2 + chrome, per-layer priors", v2, layers.count + 2),
    ("V3 + refitted appearance", v3, layers.count + 2),
    ("V4 + app priors", v4, layers.count + 2 + apps.count),
  ]

for run in runs {
  let fitted = fitDisplays.isEmpty || fitDisplays.contains { run.key.hasPrefix($0) }
  print(
    "\n--- holdout scores: \(run.key.prefix(8))  (\(run.hold.count) records)"
      + (fitted ? "" : "  [NOT FITTED: scored for information only]") + " ---")
  // V0 is the control and sets the ranking baseline. If V0 ever passes, the
  // instrument is reporting rather than measuring.
  var baseline: Int?
  let ceiling = ceilingDecile(run.hold, apps: apps, layers: layers)
  for (label, parameters, free) in ladder {
    let decile = report(
      label, run.hold, parameters, freeParameters: free,
      baselineDecile: baseline, ceiling: ceiling, fitGroups: fitGroups)
    if baseline == nil {
      baseline = decile
      print(
        "  reference: \(ceiling)/24 decile from an objective-optimal fit ON THE HOLDOUT "
          + "(\(ceiling - decile >= 0 ? "+" : "")\(ceiling - decile) vs baseline; the bar needs +3). "
          + "Fitted on RMSE, not on the decile, so it is a reference and NOT an upper bound.")
    }
  }
}

let final = v4
print("\nfitted parameters (joint), with objective sensitivity:")
func line(_ name: String, _ value: Double, _ moved: Double) {
  let verdict = moved < 1e-6 ? "  UNIDENTIFIABLE from this data" : ""
  print(String(format: "    %-28@ %.3f   sensitivity %.5f%@",
    name as NSString, value, moved, verdict as NSString))
}
line("light appearance", final.lightAppearancePrior,
  sensitivity(fitGroups, final, get: { $0.lightAppearancePrior },
    set: { $0.lightAppearancePrior = $1 }))
line("dark appearance", final.darkAppearancePrior,
  sensitivity(fitGroups, final, get: { $0.darkAppearancePrior },
    set: { $0.darkAppearancePrior = $1 }))
for (app, value) in final.appPriors.sorted(by: { $0.value > $1.value }) {
  line("app \(app)", value,
    sensitivity(fitGroups, final, get: { $0.appPriors[app] ?? 0 },
      set: { $0.appPriors[app] = $1 }))
}
for (layer, value) in final.layerPriors.sorted(by: { $0.key < $1.key }) {
  line("layer \(layer)", value,
    sensitivity(fitGroups, final, get: { $0.layerPriors[layer] ?? 0 },
      set: { $0.layerPriors[layer] = $1 }))
}
