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
  default:
    print("""
      candela-model-fit: score candidate exposure models against a recorded log

        --log <dir>            replay log directory
        --fit-fraction <f>     temporal split; leading fraction fits, rest scores (default 0.6)
        --top-apps <n>         how many apps get a fitted prior (default 8)
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

  func modelled(_ parameters: ExposureModelParameters, includeChrome: Bool = false) -> [Double] {
    let prior = dark ? parameters.darkAppearancePrior : parameters.lightAppearancePrior
    // Chrome is BEHIND every app window: it is what a window occludes, never
    // the reverse, so it goes last in a front-to-back walk.
    let all = includeChrome ? windows + chrome : windows
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
  let windows = record.windows.map(\.snapshot)
    .filter { ExposureModel.includedLayers.contains($0.layer) }
    .map {
      PreparedWindow(
        owner: $0.ownerName, layer: $0.layer,
        coverage: transform.coverage(ofDisplayRect: $0.bounds))
    }
  let displayArea = transform.displaySize.width * transform.displaySize.height
  let chrome = record.chrome.map(\.snapshot)
    .filter { snapshot in
      let area = snapshot.bounds.width * snapshot.bounds.height
      return area > 0 && displayArea > 0 && area < 0.5 * displayArea
    }
    .map {
      PreparedWindow(
        owner: "chrome", layer: $0.layer,
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
  _ records: [Prepared], _ parameters: ExposureModelParameters, includeChrome: Bool = false
) -> ([Double], [Double]) {
  var measured = [Double](repeating: 0, count: PanelGrid.cellCount)
  var modelled = [Double](repeating: 0, count: PanelGrid.cellCount)
  for record in records {
    let grid = record.modelled(parameters, includeChrome: includeChrome)
    for cell in 0..<PanelGrid.cellCount {
      measured[cell] += record.measured[cell] * record.elapsed
      modelled[cell] += grid[cell] * record.elapsed
    }
  }
  return (measured, modelled)
}

func score(
  _ records: [Prepared], _ parameters: ExposureModelParameters, includeChrome: Bool = false
) -> Double {
  let (measured, modelled) = accumulate(records, parameters, includeChrome: includeChrome)
  return pearson(measured, modelled) ?? -1
}

// MARK: - Load

let (records, skipped) = try ModelReplayLog.read(directory: directory)
print("log: \(directory.path)")
print("records \(records.count), skipped \(skipped)")
guard !records.isEmpty else {
  print("nothing to score")
  exit(1)
}

var byDisplay: [String: [ModelReplayRecord]] = [:]
for record in records { byDisplay[record.display.persistenceKey, default: []].append(record) }

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
  var mismatches = 0
  var params = ExposureModelParameters.baseline
  params.compositing = .topmostWins
  params.appPriors = ["Ghostty": 0.11, "Zed": 0.9]
  params.layerPriors = [24: 0.8]
  for record in raw.prefix(40) {
    let prepared = prepare(record)
    for candidate in [ExposureModelParameters.baseline, params] {
      let fast = prepared.modelled(candidate)
      let reference = ExposureModel.modelledGrid(
        inputs: record.inputs, through: record.transform, parameters: candidate)
      if (0..<PanelGrid.cellCount).contains(where: { abs(fast[$0] - reference[$0]) > 1e-9 }) {
        mismatches += 1
      }
    }
  }
  print("  control: prepared path matches ExposureModel \(mismatches == 0 ? "yes" : "NO (\(mismatches))")")
  return mismatches == 0
}

// MARK: - Fitting

/// Coordinate refinement over `0...1`, maximising Pearson on the fit split
/// (MP3, fixed before any result was seen).
func refine(
  _ start: ExposureModelParameters, keys: [(get: (ExposureModelParameters) -> Double,
    set: (inout ExposureModelParameters, Double) -> Void)],
  on records: [Prepared], includeChrome: Bool = false, passes: Int = 3
) -> ExposureModelParameters {
  var best = start
  var bestScore = score(records, best, includeChrome: includeChrome)
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
        let candidateScore = score(records, candidate, includeChrome: includeChrome)
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

func report(_ label: String, _ records: [Prepared], _ parameters: ExposureModelParameters,
  freeParameters: Int, includeChrome: Bool = false)
{
  let (measured, modelled) = accumulate(records, parameters, includeChrome: includeChrome)
  let p = pearson(measured, modelled) ?? .nan
  let s = pearson(averageRanks(measured), averageRanks(modelled)) ?? .nan
  let multiple = hottestMultiple(modelled)
  let measuredMultiple = hottestMultiple(measured)
  let top1 = agreement(measured, modelled, 1)
  let top5 = agreement(measured, modelled, 5)
  let top10 = agreement(measured, modelled, 10)
  let top24 = agreement(measured, modelled, 24)
  let passes = multiple >= 2.7 && top10 >= 5
  print(
    String(
      format: "  %-34@ params %2d  r %.3f  rho %.3f  peak %.2fx (measured %.2fx)  top1 %d/1  top5 %d/5  top10 %d/10  top24 %2d/24  %@",
      label as NSString, freeParameters, p, s, multiple, measuredMultiple, top1, top5, top10,
      top24, (passes ? "PASS" : "fail") as NSString))
}

// MARK: - Run

for (key, raw) in byDisplay.sorted(by: { $0.value.count > $1.value.count }) {
  let shape = raw[0].display
  print("\n=== \(key)  \(shape.pixelWidth)x\(shape.pixelHeight) rot \(shape.rotation.rawValue)  \(raw.count) records")
  guard runControls(raw), verifyPrepared(raw) else {
    print("  controls failed; refusing to score variants on this log")
    continue
  }

  let prepared = raw.map(prepare)
  let split = max(1, Int(Double(prepared.count) * fitFraction))
  let fit = Array(prepared.prefix(split))
  let hold = Array(prepared.suffix(from: min(split, prepared.count - 1)))
  print("  fit \(fit.count) records, holdout \(hold.count) records")

  // Which layers and apps are actually worth a parameter here.
  var layerWeight: [Int: Double] = [:]
  var appWeight: [String: Double] = [:]
  for record in prepared {
    for window in record.windows {
      let mass = window.coverage.reduce(0, +) * record.elapsed
      layerWeight[window.layer, default: 0] += mass
      appWeight[window.owner, default: 0] += mass
    }
  }
  let layers = layerWeight.filter { $0.key != 0 }.sorted { $0.value > $1.value }
    .prefix(3).map(\.key)
  let apps = appWeight.sorted { $0.value > $1.value }.prefix(topApps).map(\.key)

  print("  fitted layers: \(layers)")
  print("  fitted apps:   \(apps)")
  print("\n  --- holdout scores ---")

  // V0: the shipped model.
  report("V0 baseline", hold, .baseline, freeParameters: 0)

  // V1: compositing only, no new parameters.
  var v1 = ExposureModelParameters.baseline
  v1.compositing = .topmostWins
  report("V1 z-order only", hold, v1, freeParameters: 0)

  // V2: layer priors.
  var v2 = v1
  for layer in layers { v2.layerPriors[layer] = 0.5 }
  v2 = refine(
    v2,
    keys: layers.map { layer in
      (get: { $0.layerPriors[layer] ?? 0.5 }, set: { $0.layerPriors[layer] = $1 })
    }, on: fit)
  report("V2 + layer priors", hold, v2, freeParameters: layers.count)

  // V3: refit the appearance priors too.
  var v3 = refine(
    v2,
    keys: [
      (get: { $0.lightAppearancePrior }, set: { $0.lightAppearancePrior = $1 }),
      (get: { $0.darkAppearancePrior }, set: { $0.darkAppearancePrior = $1 }),
    ], on: fit)
  report("V3 + refitted appearance", hold, v3, freeParameters: layers.count + 2)

  // V4: app priors.
  var v4 = v3
  for app in apps { v4.appPriors[app] = v3.darkAppearancePrior }
  v4 = refine(
    v4,
    keys: apps.map { app in
      (get: { $0.appPriors[app] ?? 0.5 }, set: { $0.appPriors[app] = $1 })
    }, on: fit)
  report("V4 + app priors", hold, v4, freeParameters: layers.count + 2 + apps.count)

  // V5: admit menu-bar-sized chrome, which the shipped window source discards
  // and the measured capture contains. Its own prior, fitted.
  var v5 = v4
  v5.appPriors["chrome"] = v4.lightAppearancePrior
  v5 = refine(
    v5, keys: [(get: { $0.appPriors["chrome"] ?? 0.5 }, set: { $0.appPriors["chrome"] = $1 })],
    on: fit, includeChrome: true)
  report(
    "V5 + menu-bar chrome", hold, v5, freeParameters: layers.count + 3 + apps.count,
    includeChrome: true)

  print("\n  fitted V4: light \(String(format: "%.3f", v4.lightAppearancePrior)) dark \(String(format: "%.3f", v4.darkAppearancePrior))")
  for (app, value) in v4.appPriors.sorted(by: { $0.key < $1.key }) {
    print("    app \(app): \(String(format: "%.3f", value))")
  }
  for (layer, value) in v4.layerPriors.sorted(by: { $0.key < $1.key }) {
    print("    layer \(layer): \(String(format: "%.3f", value))")
  }
}
