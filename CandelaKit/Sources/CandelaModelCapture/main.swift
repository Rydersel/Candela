import CandelaKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

// Records paired (measured, model-inputs) samples so candidate exposure models
// can be fitted and scored offline.
//
// Deliberately NOT part of the app. Iterating on the model against the shipped
// build costs a deploy plus a multi-day soak to read one number; a standalone
// tool collects the same evidence today, commits no prefs schema, and cannot
// disturb a soak in progress. Nothing here writes DDC; it only reads the
// screen, so it is safe to run alongside the live comparison.
//
// AppKit is deliberately absent: the wallpaper arrives as an explicit path
// rather than an ambient NSWorkspace read, which also makes it a recorded
// input of the run rather than something that can change underneath one.

struct Options {
  var displayFilter: CGDirectDisplayID?
  var wallpaper: URL?
  var interval: Double = 60
  var out = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Candela/model-replay")
  var maxSamples = Int.max
}

func usage() -> Never {
  print("""
  candela-model-capture: record paired exposure samples for offline model fitting

    --display <id>        only this display (default: every online display)
    --wallpaper <path>    desktop picture, decoded through ImageIO
    --interval <seconds>  sampling period (default 60)
    --out <dir>           log directory (default ~/Library/Application Support/Candela/model-replay)
    --max-samples <n>     stop after this many samples per display

  The wallpaper cannot be re-read mid-run, so restart the tool after changing it.
  Current path:
    osascript -e 'tell application "Finder" to get POSIX path of (desktop picture as alias)'
  """)
  exit(2)
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
  arguments.removeFirst()
  func value() -> String {
    guard let next = arguments.first else { usage() }
    arguments.removeFirst()
    return next
  }
  switch flag {
  case "--display":
    guard let id = CGDirectDisplayID(value()) else { usage() }
    options.displayFilter = id
  case "--wallpaper": options.wallpaper = URL(fileURLWithPath: value())
  case "--interval":
    guard let seconds = Double(value()), seconds > 0 else { usage() }
    options.interval = seconds
  case "--out": options.out = URL(fileURLWithPath: value())
  case "--max-samples":
    guard let count = Int(value()), count > 0 else { usage() }
    options.maxSamples = count
  default: usage()
  }
}

guard CGPreflightScreenCaptureAccess() else {
  // A shell-launched process inherits the terminal's grant, so this failing
  // means the TERMINAL lacks Screen Recording, not the tool.
  FileHandle.standardError.write(
    Data("no Screen Recording grant. Grant it to this terminal, then retry.\n".utf8))
  exit(1)
}

let ownPID = ProcessInfo.processInfo.processIdentifier

/// Panel-physical wallpaper cells, through the same reduction the app uses so
/// the model and the measurement disagree only about content.
@MainActor func wallpaperCells(for transform: PanelSpaceTransform) -> [Double]? {
  guard let url = options.wallpaper,
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 512,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary)
  else { return nil }
  let (cols, rows) = LuminanceReduction.requestedSize(
    displayWidth: Int(transform.displaySize.width),
    displayHeight: Int(transform.displaySize.height))
  guard let grid = LuminanceReduction.meanLuminance(of: image, cols: cols, rows: rows) else {
    return nil
  }
  return transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
}

/// On-screen windows in display-local coordinates, front-to-back, with our own
/// process and Candela's overlays removed.
///
/// Candela's exclusion is not tidiness: detection dimming draws overlays, and
/// capturing them would feed the dimming back into the measurement being fitted
/// against, which is the feedback loop the sampler already guards.
@MainActor func windows(displayOrigin: CGPoint, options: CGWindowListOption)
  -> [ModelReplayRecord.Window]
{
  let listing =
    CGWindowListCopyWindowInfo(options, kCGNullWindowID)
    as? [[String: Any]] ?? []
  return listing.compactMap { entry in
    guard let number = entry[kCGWindowNumber as String] as? UInt32,
      let pid = entry[kCGWindowOwnerPID as String] as? Int32,
      let layer = entry[kCGWindowLayer as String] as? Int,
      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return nil }
    let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
    guard pid != ownPID, owner != "Candela" else { return nil }
    return ModelReplayRecord.Window(
      id: number, pid: pid, owner: owner,
      x: rect.origin.x - displayOrigin.x, y: rect.origin.y - displayOrigin.y,
      w: rect.size.width, h: rect.size.height, layer: layer)
  }
}

let appearanceIsDark =
  UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"

let discovered = DisplayDiscovery.discover()
let log = try ModelReplayLog(directory: options.out)

// A run header, so a log can always be traced back to what produced it.
let header: [String: Any] = [
  "startedAt": Date().timeIntervalSinceReferenceDate,
  "interval": options.interval,
  "wallpaper": options.wallpaper?.path ?? "",
  "wallpaperBytes": (try? Data(contentsOf: options.wallpaper ?? URL(fileURLWithPath: "/dev/null")))?
    .count ?? 0,
  "appearanceIsDark": appearanceIsDark,
]
try? JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted])
  .write(to: options.out.appendingPathComponent("run.json"))

print("candela-model-capture: interval \(options.interval)s, out \(options.out.path)")
print("wallpaper: \(options.wallpaper?.path ?? "(none, backdrop falls back to the prior)")")

var taken = 0
while taken < options.maxSamples {
  let content: SCShareableContent
  do {
    content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
  } catch {
    FileHandle.standardError.write(Data("shareable content failed: \(error)\n".utf8))
    try await Task.sleep(for: .seconds(options.interval))
    continue
  }

  for scDisplay in content.displays {
    if let wanted = options.displayFilter, scDisplay.displayID != wanted { continue }
    guard let entry = discovered.first(where: { $0.display.id == scDisplay.displayID }) else {
      continue
    }
    guard let rotation = DisplayRotation(degrees: CGDisplayRotation(scDisplay.displayID)) else {
      continue
    }

    let transform = PanelSpaceTransform(
      displaySize: CGSize(width: scDisplay.width, height: scDisplay.height), rotation: rotation)

    let excluded = content.windows.filter {
      $0.owningApplication?.processID == ownPID
        || $0.owningApplication?.bundleIdentifier == "com.rydersel.Candela"
    }
    let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)

    let config = SCStreamConfiguration()
    let (width, height) = LuminanceReduction.requestedSize(
      displayWidth: scDisplay.width, displayHeight: scDisplay.height)
    config.width = width
    config.height = height
    config.showsCursor = false
    config.colorSpaceName = CGColorSpace.sRGB

    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    } catch {
      FileHandle.standardError.write(
        Data("capture failed on \(scDisplay.displayID): \(error)\n".utf8))
      continue
    }

    // Delivered, never assumed: this is the defect class the project keeps
    // rediscovering.
    let cols = image.width
    let rows = image.height
    guard cols > 0, rows > 0,
      let captured = LuminanceReduction.meanLuminance(of: image, cols: cols, rows: rows)
    else { continue }

    let measuredPanel = transform.panelNativeGrid(
      fromDisplayGrid: captured, cols: cols, rows: rows)
    let paper = wallpaperCells(for: transform)
    let displayOrigin = CGDisplayBounds(scDisplay.displayID).origin
    // Exactly what the app's own source reports, so the baseline is reproducible.
    let observed = windows(
      displayOrigin: displayOrigin, options: [.optionOnScreenOnly, .excludeDesktopElements])
    let everything = windows(displayOrigin: displayOrigin, options: [.optionOnScreenOnly])
    let seen = Set(observed.map(\.id))
    let chrome = everything.filter { !seen.contains($0.id) }

    let inputs = ExposureModelInputs(
      windows: observed.map(\.snapshot), wallpaperCells: paper,
      appearanceIsDark: appearanceIsDark)
    let modelled = ExposureModel.modelledGrid(
      inputs: inputs, through: transform, parameters: .baseline)

    try log.append(
      ModelReplayRecord(
        t: Date().timeIntervalSinceReferenceDate, elapsed: options.interval,
        display: .init(
          persistenceKey: entry.display.persistenceKey, displayID: scDisplay.displayID,
          pixelWidth: scDisplay.width, pixelHeight: scDisplay.height, rotation: rotation),
        capture: .init(cols: cols, rows: rows, grid: captured),
        measuredPanel: measuredPanel, modelledBaseline: modelled,
        wallpaper: paper, appearanceIsDark: appearanceIsDark, windows: observed,
        chrome: chrome))
  }

  taken += 1
  if taken % 10 == 0 { print("samples: \(taken)") }
  try await Task.sleep(for: .seconds(options.interval))
}
