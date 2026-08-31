import CandelaKit
import CoreGraphics
import Foundation

// Replays a recorded log through candidate exposure models and scores them with
// the gate's own statistics.
//
// Iterating against the shipped app costs a deploy plus a multi-day soak to read
// one number. Replaying costs seconds, and one log scores every future variant.
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
/// A panel showing static content is near-degenerate for fitting: its records are
/// all the same picture, so it constrains little while still pulling the joint
/// objective. Excluded panels stay in the reporting either way.
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
  // Every value is parsed strictly. Falling back to the default in silence made a
  // run whose parameters are unknown: `0,6` ran at 0.6 and nothing said so.
  switch flag {
  case "--log": directory = URL(fileURLWithPath: value())
  case "--fit-fraction":
    let raw = value()
    guard let parsed = Double(raw), parsed.isFinite, parsed > 0, parsed < 1 else {
      print("--fit-fraction: expected a number strictly between 0 and 1, got \(raw)")
      exit(2)
    }
    fitFraction = parsed
  case "--top-apps":
    let raw = value()
    guard let parsed = Int(raw), parsed > 0 else {
      print("--top-apps: expected a positive integer, got \(raw)")
      exit(2)
    }
    topApps = parsed
  case "--objective":
    let raw = value()
    // An unrecognised name used to run RMSE and label nothing.
    guard raw == "rmse" || raw == "pearson" else {
      print("--objective: expected rmse or pearson, got \(raw)")
      exit(2)
    }
    objective = raw
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

/// How many of the top `depth` slots were filled by CELL INDEX rather than by
/// value.
///
/// `hottest` breaks ties by lowest index and panel-native cell order is row-major,
/// so a tie at the boundary hands the decile to the top rows, where the measured map
/// is hot. Under `.summedCoverage` the V0 map saturates and the boundary tie swallows
/// the whole decile: every slot came from numbering, a model predicting nothing
/// scored 14/24 against a chance value of 2.4, and a real model had to reach 17 to
/// clear the plus-3 gate. A decile decided this way is refused rather than scored.
///
/// The cutoff is the highest value that did NOT make the cut: everything strictly
/// above it is in the decile on merit, the rest came out of the boundary tie group.
func indexDecidedSlots(_ values: [Double], _ depth: Int) -> Int {
  guard values.count > depth, depth > 0 else { return 0 }
  let cutoff = values.sorted(by: >)[depth]
  return max(0, depth - values.filter { $0 > cutoff }.count)
}

func varies(_ values: [Double]) -> Bool {
  guard let first = values.first else { return false }
  return values.contains { $0 != first }
}

// MARK: - Prepared records
//
// Window coverage is the expensive part and does not depend on the parameters, so it
// is computed once. That means this file walks the windows itself rather than calling
// ExposureModel, the duplication that could make the harness fit a different model
// than the one that ships. `verifyPrepared` is the control, and it runs before any
// fitting.

struct PreparedWindow {
  let owner: String
  let layer: Int
  let coverage: [Double]
}

struct Prepared {
  let windows: [PreparedWindow]
  /// Menu-bar-sized system chrome only. Dock and Wallpaper entries are full-display
  /// backing windows that would blanket every cell and delete the wallpaper term, so
  /// they are filtered by area: layer cannot tell them apart.
  let chrome: [PreparedWindow]
  let backdrop: [Double]?
  let dark: Bool
  let measured: [Double]
  let elapsed: Double
  let recordedBaseline: [Double]
  let key: String
  /// Which image the backdrop came from. A wallpaper that changes mid-log is
  /// otherwise invisible in the report.
  let wallpaperPath: String

  /// Names the backdrop for the split-composition report. A structureless backdrop
  /// constrains nothing, so the reader has to be able to see one.
  var backdropLabel: String {
    guard let backdrop else { return "(refused)" }
    let name = wallpaperPath.isEmpty ? "(unnamed)" : String(wallpaperPath.split(separator: "/").last ?? "")
    guard let low = backdrop.min(), let high = backdrop.max() else { return name }
    return high - low < 1e-6 ? "\(name) [flat]" : name
  }

  /// `ExposureModel.admitted(_:)`, mirrored. Any drift is a divergence the
  /// equivalence control reports, so this reads as closely to the original as Swift
  /// allows.
  ///
  /// Applied to the WHOLE list, not to chrome alone. Filtering `windows` down to
  /// `includedLayers` first discards sub-zero-layer system windows that the shipped
  /// model fraction-tests and admits, such as Notification Center.
  private func admits(_ window: PreparedWindow, _ parameters: ExposureModelParameters) -> Bool {
    if ExposureModel.includedLayers.contains(window.layer) { return true }
    // Below the range only, never above, for the reason `ExposureModel.admitted(_:)`
    // states: below is chrome a coverage bound can separate, above is pop-ups it
    // cannot.
    guard window.layer < ExposureModel.includedLayers.lowerBound,
      let limit = parameters.chromeCoverageLimit
    else { return false }
    let fraction = window.coverage.reduce(0, +) / Double(PanelGrid.cellCount)
    return fraction > 0 && fraction < limit
  }

  /// Admission is driven by the PARAMETERS, never by a separate flag: a parallel
  /// boolean was its own divergence source, since `.baseline` carries no chrome limit
  /// while this path appended chrome anyway.
  ///
  /// Chrome is BEHIND every app window: it is what a window occludes, never the
  /// reverse, so it goes last, matching `inputsIncludingChrome`.
  func admitted(_ parameters: ExposureModelParameters) -> [PreparedWindow] {
    (windows + chrome).filter { admits($0, parameters) }
  }

  /// Coverage each admitted window actually contributes under topmost-wins.
  ///
  /// That is the only mass a prior on it can move, so it is the only honest basis
  /// for ranking which apps and layers earn a free parameter. Ranking on RAW coverage
  /// credits a buried window for area a nearer window owns, so a window nobody can
  /// see takes a slot from a visible app.
  func visibleMass(_ parameters: ExposureModelParameters) -> [(owner: String, layer: Int, mass: Double)] {
    var remaining = [Double](repeating: 1, count: PanelGrid.cellCount)
    var claimed: [(owner: String, layer: Int, mass: Double)] = []
    for window in admitted(parameters) {
      var mass = 0.0
      for cell in 0..<PanelGrid.cellCount {
        let claim = min(window.coverage[cell], remaining[cell])
        guard claim > 0 else { continue }
        mass += claim
        remaining[cell] = max(0, remaining[cell] - claim)
      }
      claimed.append((window.owner, window.layer, mass))
    }
    return claimed
  }

  func modelled(_ parameters: ExposureModelParameters) -> [Double] {
    let prior = dark ? parameters.darkAppearancePrior : parameters.lightAppearancePrior
    let all = admitted(parameters)
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

/// `ExposureModel.usableWallpaper`, mirrored: taken whole or refused whole.
///
/// The fast path took the recorded array raw while the shipped model validates
/// it, so a malformed wallpaper would be used by the harness and refused by the
/// model, or would index-crash on a short array. This mirror is documented as
/// exact and this was the one place it was not.
func usableWallpaper(_ cells: [Double]?) -> [Double]? {
  guard let cells, cells.count == PanelGrid.cellCount else { return nil }
  guard cells.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return nil }
  return cells
}

func prepare(_ record: ModelReplayRecord) -> Prepared {
  let transform = record.transform
  // NOT filtered by layer here. Admission depends on the parameters and the coverage
  // fraction, so it belongs at `modelled` time next to the chrome rule, or the fast
  // path drops windows the shipped model keeps.
  let windows = record.windows.map(\.snapshot)
    .map {
      PreparedWindow(
        owner: $0.ownerName, layer: $0.layer,
        coverage: transform.coverage(ofDisplayRect: $0.bounds))
    }
  // Filtered by COVERAGE OF THIS DISPLAY, not by area compared against it. Chrome
  // windows in a record belong to every display, so an area test admitted the built-in
  // panel's full-display backing windows onto the ultrawide purely because a laptop
  // screen is smaller than half of it, contributing exactly zero coverage. Coverage is
  // display-local by construction, and the upper bound still keeps a full-display
  // backdrop from blanketing every cell and deleting the wallpaper term.
  let chrome = record.chrome.map(\.snapshot)
    // NOT filtered here. The limit is a parameter, and applying it at prepare time
    // made the harness treat it as a boolean: a rung's limit of 0.02 scored
    // byte-identically to 0.5. The value has to be read where it is used.
    .map {
      // The REAL owner name, not a synthesised "chrome<layer>" one: `ExposureModel`
      // resolves luminance by the window's actual owner, so a rename diverges from it
      // and `layerPriors` already provides the per-layer separation.
      PreparedWindow(
        owner: $0.ownerName, layer: $0.layer,
        coverage: transform.coverage(ofDisplayRect: $0.bounds))
    }
  return Prepared(
    windows: windows, chrome: chrome, backdrop: usableWallpaper(record.wallpaper),
    dark: record.appearanceIsDark,
    measured: record.measuredPanel, elapsed: record.elapsed,
    recordedBaseline: record.modelledBaseline, key: record.display.persistenceKey,
    wallpaperPath: record.wallpaperPath)
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

/// Higher is better, for both objectives. `nil` means this group carries no
/// information at all, which is a property of the DATA.
///
/// **Pearson cannot fit absolute luminance.** It is invariant under `y -> a*y + b`,
/// so scaling and offsetting every prior leaves it unmoved: the ground-truth harness
/// recovered known luminances 0.85, 0.35 and 0.05 in the right ORDER as 1.00, 0.61
/// and 0.25, biased high throughout. MP2's bar is the hottest multiple, which an
/// offset does change, so fitting on a scale-blind objective and judging on a
/// scale-sensitive one is incoherent.
///
/// Both maps are in the same unit, luminance times seconds, so a residual between
/// them is meaningful as it stands. RMSE is normalised by the measured mean only so
/// the number reads comparably across panels.
func score(
  _ records: [Prepared], _ parameters: ExposureModelParameters
) -> Double? {
  if objective == "pearson" {
    let (measured, modelled) = accumulate(records, parameters)
    // A flat MEASURED map is a property of the data: this group can say nothing
    // about any candidate, so it drops out for everyone alike.
    guard varies(measured) else { return nil }
    // A flat MODELLED map is a property of the PARAMETERS. Returning nothing for it
    // let a candidate that degenerated one panel drop it from the mean and win on the
    // rest. Zero modelled variance is the worst correlation there is, so it scores
    // as one.
    return pearson(measured, modelled) ?? -1
  }
  // Fit on PER-RECORD residuals, not on the accumulated map.
  //
  // Each instant is an observation; summing first throws away which app was where at
  // the time. With three known luminances rotating through three tiles, every cell
  // averages all three apps, the summed map constrains only their SUM, and the fit
  // compresses all three toward the mean. The report below still uses accumulated
  // maps, because accumulation is what the shipped comparison does.
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
  guard count > 0, total > 0 else { return nil }
  let mean = total / Double(count)
  return -((squared / Double(count)).squareRoot() / mean)
}

/// Mean per-display Pearson.
///
/// Parameters are fitted JOINTLY across panels, because an app's luminance belongs to
/// the app and not to the display it happens to be on. Fitting one panel at a time
/// confounds an app prior with the appearance prior whenever that panel runs a single
/// app, which is this rig's usual state.
///
/// The maps themselves are never pooled. Summing two panels' exposure into one grid
/// would invent a display that does not exist.
func scoreJointly(
  _ groups: [[Prepared]], _ parameters: ExposureModelParameters
) -> Double {
  var total = 0.0
  var counted = 0
  // `.isFinite`, never a magic number. `-1` was both the "no data" sentinel and the
  // score of a normalised RMSE of 1.0, and measured baseline nRMSE on this rig is
  // 1.13 to 1.29, so every real group was silently discarded and the objective
  // rewarded a candidate for breaking a group out of the average.
  for group in groups where !group.isEmpty {
    guard let value = score(group, parameters), value.isFinite else { continue }
    total += value
    counted += 1
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
// A panel's pixel dimensions can change mid-session: a synthesised size, a resolution
// change, a dock cycle. The capture request shape follows the dimensions, so the
// measurement bins into panel-native cells differently either side of it. Grouping on
// the EDID key alone merges two geometries into one accumulated map, and every control
// still passes, because each control recomputes from each record's OWN metadata.
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
// Dictionary order is not stable between runs of the same binary on the same log, so
// every ranking and printed list breaks ties on the key. Without it a run-to-run diff
// is noise.
let orderedDisplays = byDisplay.map { (key: $0.key, records: $0.value) }
  .sorted {
    $0.records.count == $1.records.count
      ? $0.key < $1.key : $0.records.count > $1.records.count
  }

let identities = Set(records.map(\.display.persistenceKey))
if byDisplay.count > identities.count {
  print(
    "\nNOTE: \(identities.count) panel identities produced \(byDisplay.count) geometry groups.")
  print("A panel changed size or rotation mid-log; its records are scored separately.")
  for (key, group) in orderedDisplays {
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
  // A rewrite once dropped this loop and left its declaration, print and return in
  // place, so the control reported `yes` unconditionally: a claim whose failure mode
  // is silence, sitting on the verdict artifact.
  var mismatches = 0
  var probes: [ExposureModelParameters] = [.baseline]
  // Priors drawn from the log's own owners and layers, so a probe cannot miss
  // for want of an app that happens not to be on this panel.
  let probeOwners = Set(raw.flatMap { $0.windows.map(\.owner) + $0.chrome.map(\.owner) }).sorted()
  // EVERY layer, not chrome's alone. Both sides resolve
  // `appPriors[owner] ?? layerPriors[layer] ?? appearancePrior`. Seeded from chrome
  // alone, whose owners here all carry an app prior, the app branch short-circuits
  // every window and the layer branch is never reached: a deliberately wrong lookup
  // still printed `yes`, and rungs V2 and V3 are nothing but layer priors.
  let probeLayers = Set(raw.flatMap { $0.windows.map(\.layer) + $0.chrome.map(\.layer) }).sorted()
  for compositing in [ExposureModelParameters.Compositing.summedCoverage, .topmostWins] {
    var layersOnly = ExposureModelParameters.baseline
    layersOnly.compositing = compositing
    layersOnly.chromeCoverageLimit = compositing == .topmostWins ? ladderChromeLimit : 0.08
    for (index, layer) in probeLayers.enumerated() {
      layersOnly.layerPriors[layer] = Double(index % 4) / 3.0
    }
    // No app priors at all, so every admitted window resolves THROUGH the layer
    // table and a wrong key changes the answer.
    probes.append(layersOnly)
    // And again with app priors, so the precedence between the two branches is
    // exercised rather than only one of them.
    var withApps = layersOnly
    for (index, owner) in probeOwners.enumerated() {
      withApps.appPriors[owner] = Double(index % 5) / 4.0
    }
    probes.append(withApps)
  }
  // Order sensitivity is a property of the CODE, not of a log: two windows that do
  // not overlap are legitimately order-invariant, and a tiled desktop is entirely so.
  // Probing with hard-coded app names reported "order-blind" and refused a whole panel
  // where none of them covered anything.
  //
  // What is checkable is narrower: where a record does contain overlapping covered
  // windows, reversing them must change the result. Where it contains none, the answer
  // is "not applicable", never "failed". `ExposureModelCompositingTests` pins the code
  // property itself.
  //
  // Sampled ACROSS the log, not from its head: a divergence beginning later was
  // invisible, leaving the control printing "yes" while every rung scored on records
  // the harness and the shipped model disagreed about.
  let step = max(1, raw.count / 60)
  var indices = Array(Swift.stride(from: 0, to: raw.count, by: step))
  // The last record is always included: `to:` skips it on an even count, and a
  // divergence beginning in the final records is what survives a head sample.
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
    // Order can only matter where windows genuinely OVERLAP. Two covered windows
    // side by side are order-invariant and correctly so, which is what a tiled desktop
    // looks like, so "more than one covered window" is not enough of a test.
    var stacked = [Double](repeating: 0, count: PanelGrid.cellCount)
    for window in covering {
      for cell in 0..<PanelGrid.cellCount { stacked[cell] += window.coverage[cell] }
    }
    guard stacked.contains(where: { $0 > 1.000_001 }) else { continue }
    // Overlaps between windows of the SAME owner are order-invariant in the model
    // too, since it resolves luminance by owner, so such a record cannot tell an
    // order-blind harness from an order-independent layout.
    guard Set(covering.map(\.owner)).count > 1 else { continue }
    // Distinct priors drawn from THIS record's own owners, so the probe cannot
    // miss for want of an app that happens not to be on this panel.
    var probe = ExposureModelParameters.baseline
    probe.compositing = .topmostWins
    // Per distinct OWNER, not per window: assigning by window index gives A and B the
    // same value in `[A, A, B, B]`, which reads as order-blind on an ordinary desktop.
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
  // property of the code, pinned by `ExposureModelCompositingTests`. Whether a given
  // log can demonstrate it is a property of that day's windows, and a tiled desktop
  // legitimately cannot.
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
/// optimiser leaves it wherever it started, and printing that value implies a finding
/// the data does not contain. A smoke run published two apps' spread starting values
/// as fitted luminances; neither app appeared in the log at all.
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

/// Sensitivity is a change IN the objective, so what counts as "moved" has to be
/// measured against the objective's own size.
///
/// An absolute 1e-6 test is finer than the 5 decimal places the value prints at, so
/// anything in [1e-6, 5e-6) printed `0.00000` with no label: on one run a layer with
/// sensitivity 4.92e-6 published a fitted luminance unlabelled, four parts per million
/// under a plus or minus 0.25 swing of the parameter.
let identifiabilityFraction = 1e-3

func identifiabilityThreshold(_ base: Double) -> Double {
  base.isFinite ? max(1e-9, abs(base) * identifiabilityFraction) : 1e-9
}

/// MP2 as amended. Three conditions, all required.
///
/// The predicate `multiple >= 2.7 && top10 >= 5` was broken three ways, each measured
/// on this rig before any real verdict was read:
///
/// - **One-sided.** A model that OVERSHOOTS passed: 5.78x modelled against 2.99x
///   measured would have printed PASS.
/// - **An absolute threshold against a moving target.** 2.7 was 85% of a measured
///   3.17x, but 60% of a measured 4.48x. The bar loosened and nobody chose that.
/// - **A ranking half that is free at this accumulation length.** Top-10 overlap is
///   not portable across accumulation length, so the bar collapsed to the peak
///   criterion alone.
///
/// Three rungs then printed PASS on an 8-record holdout from a log the readiness gate
/// refuses, including one with no per-window luminance term at all.
///
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
  ceiling: Int, holdout: Int, indexDecided: Int
) -> (ok: Bool, why: String) {
  guard holdout >= ExposureAccumulator.minimumSamplesForAnalysis else {
    return (false, "n<\(ExposureAccumulator.minimumSamplesForAnalysis)")
  }
  guard measuredPeak > 0 else { return (false, "flat") }
  let ratio = modelledPeak / measuredPeak
  guard ratio >= 0.85, ratio <= 1.18 else {
    return (false, String(format: "peak %.3f", ratio))
  }
  // Refused, never scored. When the decile boundary sits inside a tie group, `hottest`
  // fills the remaining slots by cell index, and row-major order puts those on the top
  // rows where a laptop's menu bar and title bars live. Both sides count: the rung's
  // own map and the V0 map the plus-3 gate measures it against.
  guard indexDecided == 0 else {
    return (
      false,
      "decile REFUSED: \(indexDecided)/24 slots decided by cell index rather than by value"
    )
  }
  // The decile gate is decided FIRST, and the reference only ever explains a failure.
  // It can never veto a rung that cleared the bar.
  //
  // Not cosmetic: `ceilingDecile` fits on the OBJECTIVE (normalised RMSE) while this
  // compares DECILE overlap. On one holdout the reference came out at 0/24 while an
  // honestly fitted rung reached 6/24, so gating on the reference printed a rung that
  // beat the bar by six cells as "fail (ranking UNREACHABLE)".
  func signed(_ value: Int) -> String { value >= 0 ? "+\(value)" : "\(value)" }
  if decile - baselineDecile >= 3 { return (true, "PASS") }
  // The reference is only mentioned when it is BELOW this rung's own gain: saying
  // "the bar may be unreachable" on a rung that already beat it is the wrong-quantity
  // comparison surviving in prose.
  if ceiling - baselineDecile < 3, ceiling <= decile {
    return (false, "decile \(signed(decile - baselineDecile)), and an objective-optimal fit on "
      + "the holdout reached only \(signed(ceiling - baselineDecile))")
  }
  return (
    false,
    "decile \(signed(decile - baselineDecile)), reference \(signed(ceiling - baselineDecile))")
}

/// This rung's hottest-DECILE agreement, so the next rung can be judged against
/// the baseline rather than against an absolute number, plus how much of that
/// decile the values did not decide.
struct RungScore {
  let decile: Int
  /// Carried forward because the plus-3 gate measures every later rung against
  /// the V0 decile: if that reference was index-decided, so is the comparison.
  let indexDecided: Int
}

@discardableResult
func report(_ label: String, _ records: [Prepared], _ parameters: ExposureModelParameters,
  freeParameters: Int, baseline: RungScore?, ceiling: Int,
  fitGroups: [[Prepared]] = []) -> RungScore
{
  let (measured, modelled) = accumulate(records, parameters)
  let p = pearson(measured, modelled) ?? .nan
  let s = pearson(averageRanks(measured), averageRanks(modelled)) ?? .nan
  let multiple = hottestMultiple(modelled)
  let measuredMultiple = hottestMultiple(measured)
  // Reported, never gating. EM14 blocks hottestRelative, which the peak ratio
  // licenses, and hottestOwner, which needs the SINGLE hottest cell to be right. No
  // rung has scored above 0/1 on that, so hottestOwner stays blocked whatever the
  // gate says about the peak.
  let top1 = agreement(measured, modelled, 1)
  let top24 = agreement(measured, modelled, 24)
  // Both maps, and the V0 map the gate compares against: a tie on either side
  // is a slot `hottest` filled from the cell numbering.
  let ownTies = max(indexDecidedSlots(measured, 24), indexDecidedSlots(modelled, 24))
  let ties = max(ownTies, baseline?.indexDecided ?? 0)

  // Free parameters are counted as those the objective can actually move.
  // The printed count is what a reader uses to judge overfitting, and a prior
  // the data cannot constrain is not a degree of freedom that was spent.
  let threshold = fitGroups.isEmpty
    ? .infinity : identifiabilityThreshold(scoreJointly(fitGroups, parameters))
  var effective = -1
  if !fitGroups.isEmpty {
    var live = 0
    for app in parameters.appPriors.keys.sorted()
    where sensitivity(fitGroups, parameters, get: { $0.appPriors[app] ?? 0 },
      set: { $0.appPriors[app] = $1 }) > threshold { live += 1 }
    for layer in parameters.layerPriors.keys.sorted()
    where sensitivity(fitGroups, parameters, get: { $0.layerPriors[layer] ?? 0 },
      set: { $0.layerPriors[layer] = $1 }) > threshold { live += 1 }
    for probe in [
      (get: { (p: ExposureModelParameters) in p.lightAppearancePrior },
       set: { (p: inout ExposureModelParameters, v: Double) in p.lightAppearancePrior = v }),
      (get: { (p: ExposureModelParameters) in p.darkAppearancePrior },
       set: { (p: inout ExposureModelParameters, v: Double) in p.darkAppearancePrior = v }),
    ] where sensitivity(fitGroups, parameters, get: probe.get, set: probe.set) > threshold {
      live += 1
    }
    effective = live
  }

  let verdict = baseline.map {
    passes(modelledPeak: multiple, measuredPeak: measuredMultiple, decile: top24,
      baselineDecile: $0.decile, ceiling: ceiling, holdout: records.count, indexDecided: ties)
  }
  // A prior resting on a clamp is a misspecification signal, not a fit. Every fitted
  // family, not just apps: V2 fits nothing BUT layer priors. And only priors the
  // objective can actually move, or the marker fires on every rung because an
  // unidentifiable prior is sitting at its start value.
  var pinnedNames: [String] = []
  if !fitGroups.isEmpty {
    for (app, value) in parameters.appPriors.sorted(by: { $0.key < $1.key })
    where value <= 0 || value >= 1 {
      if sensitivity(fitGroups, parameters, get: { $0.appPriors[app] ?? 0 },
        set: { $0.appPriors[app] = $1 }) > threshold { pinnedNames.append(app) }
    }
    for (layer, value) in parameters.layerPriors.sorted(by: { $0.key < $1.key })
    where value <= 0 || value >= 1 {
      if sensitivity(fitGroups, parameters, get: { $0.layerPriors[layer] ?? 0 },
        set: { $0.layerPriors[layer] = $1 }) > threshold { pinnedNames.append("layer \(layer)") }
    }
    if parameters.darkAppearancePrior <= 0 || parameters.darkAppearancePrior >= 1,
      sensitivity(fitGroups, parameters, get: { $0.darkAppearancePrior },
        set: { $0.darkAppearancePrior = $1 }) > threshold { pinnedNames.append("dark") }
    // The light prior is the one the run card asks the operator to exercise, so it is
    // the one most likely to land on a clamp during the session.
    if parameters.lightAppearancePrior <= 0 || parameters.lightAppearancePrior >= 1,
      sensitivity(fitGroups, parameters, get: { $0.lightAppearancePrior },
        set: { $0.lightAppearancePrior = $1 }) > threshold { pinnedNames.append("light") }
  }
  let pinned = !pinnedNames.isEmpty
  print(
    String(
      format: "  %-30@ params %2d/%-2d r %6.3f  rho %6.3f  peak %.2fx/%.2fx = %.2f  top1 %d/1  decile %2d/24 (idx %2d)  %@%@",
      label as NSString, effective >= 0 ? effective : freeParameters, freeParameters,
      p, s, multiple, measuredMultiple,
      measuredMultiple > 0 ? multiple / measuredMultiple : .nan, top1, top24, ownTies,
      (verdict.map { $0.ok ? "PASS" : "fail (\($0.why))" } ?? "baseline") as NSString,
      (pinned ? "  [pinned at a clamp: \(pinnedNames.joined(separator: ", "))]" : "")
        as NSString))
  return RungScore(decile: top24, indexDecided: ownTies)
}

// MARK: - Run

struct DisplayRun {
  let key: String
  let shape: ModelReplayRecord.Display
  let fit: [Prepared]
  let hold: [Prepared]
}

/// What each split actually contains, because the temporal cut can land on a
/// change in the world and nothing else reports it.
///
/// It has: a split landing on the appearance change left the fit half with 0 light
/// records and nearly all the holdout light, so the light prior was correctly
/// labelled unidentifiable while driving most of the scored data at its default.
func describeSplit(_ label: String, _ records: [Prepared]) {
  let dark = records.filter(\.dark).count
  var backdrops: [String: Int] = [:]
  for record in records { backdrops[record.backdropLabel, default: 0] += 1 }
  let listed = backdrops.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
  print("  \(label) \(records.count) records: dark \(dark), light \(records.count - dark)"
    + "; backdrop \(listed)")
}

/// A parameter the fit half cannot see, driving most of the half it is scored
/// on, is the shape that turns a same-condition comparison into a
/// cross-condition generalisation claim without saying so.
func warnUnidentifiable(_ fit: [Prepared], _ hold: [Prepared]) {
  guard !hold.isEmpty else { return }
  for (name, matches) in [
    ("light appearance", { (record: Prepared) in !record.dark }),
    ("dark appearance", { (record: Prepared) in record.dark }),
  ] {
    let inFit = fit.filter(matches).count
    let inHold = hold.filter(matches).count
    guard inFit == 0, inHold * 2 > hold.count else { continue }
    print(String(
      format: "  WARNING: the %@ prior is unfittable here (0 of %d fit records) while its "
        + "condition drives %d of %d holdout records (%.0f%%). Every score below rests on its "
        + "unfitted default.",
      name, fit.count, inHold, hold.count, 100 * Double(inHold) / Double(hold.count)))
  }
  // A backdrop the fit half never saw is an untested input under the scores, and a
  // structureless one constrains nothing at all.
  let known = Set(fit.map(\.backdropLabel))
  let unseen = hold.filter { !known.contains($0.backdropLabel) }
  guard !unseen.isEmpty else { return }
  var names: [String: Int] = [:]
  for record in unseen { names[record.backdropLabel, default: 0] += 1 }
  print(String(
    format: "  WARNING: %d of %d holdout records (%.0f%%) use a backdrop the fit half never saw: %@",
    unseen.count, hold.count, 100 * Double(unseen.count) / Double(hold.count),
    names.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
}

var runs: [DisplayRun] = []
for (key, raw) in orderedDisplays {
  let shape = raw[0].display
  print("\n=== \(shape.persistenceKey)  \(shape.pixelWidth)x\(shape.pixelHeight) rot \(shape.rotation.rawValue)  \(raw.count) records")
  guard runControls(raw), verifyPrepared(raw) else {
    print("  controls failed; refusing to score variants on this log")
    continue
  }
  let prepared = raw.map(prepare)
  let split = max(1, min(prepared.count - 1, Int(Double(prepared.count) * fitFraction)))
  let fit = Array(prepared.prefix(split))
  let hold = Array(prepared.suffix(from: split))
  describeSplit("fit    ", fit)
  describeSplit("holdout", hold)
  warnUnidentifiable(fit, hold)
  runs.append(DisplayRun(key: key, shape: shape, fit: fit, hold: hold))
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
// Selected from the FIT SPLIT of the FITTED panels only. Reading the holdout to decide
// which apps get free parameters is a softer form of the failure MP14 exists to
// prevent, and reading panels that --fit-displays removed lets an app that never
// appears in the fit earn a parameter applied to the holdout.
//
// Ranked through the LADDER's own parameterisation, so the table cannot offer a slot
// the admission rule refuses. Crediting a window without checking its layer let the
// Window Server layer, which `admitted` can never admit, take a top-four slot and
// displace a layer that moves. Ranking on RAW coverage instead of visible mass lets a
// permanently buried window win a slot from a visible app under topmost-wins.
var ranking = ExposureModelParameters.baseline
ranking.compositing = .topmostWins
ranking.chromeCoverageLimit = ladderChromeLimit

for group in fitGroups {
  for record in group {
    // Chrome carries the LAYER table on an ordinary desktop: every app window is
    // layer 0, so without it the table is empty and V2 is byte identical to V1 while
    // printing as a rung that ran. `admitted` puts chrome behind the app windows,
    // exactly where the model does.
    for entry in record.visibleMass(ranking) {
      let mass = entry.mass * record.elapsed
      guard mass > 0 else { continue }
      layerWeight[entry.layer, default: 0] += mass
      appWeight[entry.owner, default: 0] += mass
    }
  }
}
// Layer 0 carries every ordinary window, so a prior on it only restates the
// appearance prior.
let layers = layerWeight.filter { $0.key != 0 }
  .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
  .prefix(4).map(\.key)
// Apps with next to no visible coverage cannot be fitted, however often they appear
// in the window list. `coverage` is clipped to the display, so an app living on
// another panel scores ~0 here.
let heaviest = appWeight.values.max() ?? 0
let appFloor = heaviest * 0.01
let rankedApps = appWeight.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
let carrying = rankedApps.filter { $0.value > appFloor }
let apps = carrying.prefix(topApps).map(\.key)
// The three lists partition every owner the fit split saw. An app above the floor but
// outside the top N used to appear in none of them and vanish from the report.
let overflow = carrying.dropFirst(topApps).map(\.key)
let tooLight = rankedApps.filter { $0.value <= appFloor }.map(\.key)

print("\n=== joint fit across \(fitGroups.count) of \(runs.count) panels")
print("  layers: \(layers)")
print("  apps:   \(apps)")
if !overflow.isEmpty {
  print("  above the floor but outside --top-apps \(topApps): \(overflow)")
}
if !tooLight.isEmpty {
  // Named for what it measures: "no coverage on the FITTED panels" reported an app at
  // 0.99 percent of the heaviest as having none.
  print("  under 1% of the heaviest app's visible mass: \(tooLight)")
}

var v1 = ExposureModelParameters.baseline
v1.compositing = .topmostWins

// V2 is MP4's stated bet: admit system chrome and give each chrome LAYER its own
// luminance. Chrome enters here rather than at the end of the ladder because the
// layer table has nothing else to fit on an ordinary desktop.
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

// Spread the starting values rather than sharing one: coordinate descent from a
// single shared start can sit still in a flat region and report "no app differs",
// which says more about the optimiser than about the data.
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
    // identifiable count probes them on every rung. A denominator that omitted the
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
  var baseline: RungScore?
  let ceiling = ceilingDecile(run.hold, apps: apps, layers: layers)
  for (label, parameters, free) in ladder {
    let scored = report(
      label, run.hold, parameters, freeParameters: free,
      baseline: baseline, ceiling: ceiling, fitGroups: fitGroups)
    if baseline == nil {
      baseline = scored
      if scored.indexDecided > 0 {
        // The reference is a decile count too, so it is withheld here: a number the
        // line above has just declared meaningless would be read as evidence anyway.
        print(
          "  DECILE REFUSED on this panel: \(scored.indexDecided) of the baseline's 24 slots were "
            + "filled by cell index rather than by value, so the plus-3 gate has no reference to "
            + "measure against. No rung below can pass or fail on the decile here, and the "
            + "objective-optimal reference is withheld for the same reason.")
      } else {
        print(
          "  reference: \(ceiling)/24 decile from an objective-optimal fit ON THE HOLDOUT "
            + "(\(ceiling - scored.decile >= 0 ? "+" : "")\(ceiling - scored.decile) vs baseline; the bar needs +3). "
            + "Fitted on RMSE, not on the decile, so it is a reference and NOT an upper bound.")
      }
    }
  }
}

let final = v4
let finalObjective = scoreJointly(fitGroups, final)
let finalThreshold = identifiabilityThreshold(finalObjective)
print("\nfitted parameters (joint), with objective sensitivity:")
print(String(
  format: "  objective %.5f; a prior counts as identifiable only above %g of it (%.5f)",
  finalObjective, identifiabilityFraction, finalThreshold))
func line(_ name: String, _ value: Double, _ moved: Double) {
  let verdict = moved > finalThreshold ? "" : "  UNIDENTIFIABLE from this data"
  // The relative figure is what the threshold is expressed in. An absolute 0.00000
  // said nothing about whether a prior was fitted or merely left where it started.
  let relative = finalObjective.isFinite && finalObjective != 0
    ? moved / abs(finalObjective) : Double.nan
  print(String(format: "    %-28@ %.3f   sensitivity %.5f (%.1e of the objective)%@",
    name as NSString, value, moved, relative, verdict as NSString))
}
line("light appearance", final.lightAppearancePrior,
  sensitivity(fitGroups, final, get: { $0.lightAppearancePrior },
    set: { $0.lightAppearancePrior = $1 }))
line("dark appearance", final.darkAppearancePrior,
  sensitivity(fitGroups, final, get: { $0.darkAppearancePrior },
    set: { $0.darkAppearancePrior = $1 }))
for (app, value) in final.appPriors
  .sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value })
{
  line("app \(app)", value,
    sensitivity(fitGroups, final, get: { $0.appPriors[app] ?? 0 },
      set: { $0.appPriors[app] = $1 }))
}
for (layer, value) in final.layerPriors.sorted(by: { $0.key < $1.key }) {
  line("layer \(layer)", value,
    sensitivity(fitGroups, final, get: { $0.layerPriors[layer] ?? 0 },
      set: { $0.layerPriors[layer] = $1 }))
}
