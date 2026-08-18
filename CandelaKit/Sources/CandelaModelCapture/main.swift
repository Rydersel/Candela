import AppKit
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
// The wallpaper is read PER DISPLAY through NSWorkspace, the same source the
// app's own wallpaper island uses. An earlier version took a single explicit
// --wallpaper path, on the theory that an explicit input is more reproducible
// than an ambient one. That was wrong in effect twice over: this rig runs a
// different wallpaper on each panel, which one path cannot express, and it
// diverged from the app on precisely the input being fitted. A run where the
// Dell showed nothing but wallpaper scored 0.201 against its own wallpaper
// term where it should have scored ~1.0, which is what surfaced it.
//
// The resolved path is recorded per sample, so the log stays self-describing
// and --wallpaper survives as an override.

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

  The wallpaper is re-read per sample, per display. Point --out at a FRESH
  directory: this tool appends to whatever is already there, and the fit reads
  every file in the directory.
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

/// The wallpaper macOS is actually showing on this display.
@MainActor func wallpaperURL(for displayID: CGDirectDisplayID) -> URL? {
  if let override = options.wallpaper { return override }
  let screen = NSScreen.screens.first {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      == displayID
  }
  guard let screen else { return nil }
  return NSWorkspace.shared.desktopImageURL(for: screen)
}

/// Panel-physical wallpaper cells, through the same reduction the app uses so
/// the model and the measurement disagree only about content.
@MainActor func wallpaperCells(url: URL?, for transform: PanelSpaceTransform) -> [Double]? {
  guard let url,
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
  let filled = LuminanceReduction.cropToFill(
    image, aspect: transform.displaySize.width / transform.displaySize.height)
  guard let grid = LuminanceReduction.meanLuminance(of: filled, cols: cols, rows: rows) else {
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
    // Dropped when nameless, exactly as CGWindowListSource does. Admitting one
    // as "" would let it earn a fitted prior the shipped model can never
    // produce, and would slip past the Candela exclusion below.
    guard let owner = entry[kCGWindowOwnerName as String] as? String, !owner.isEmpty else {
      return nil
    }
    guard pid != ownPID, owner != "Candela" else { return nil }
    return ModelReplayRecord.Window(
      id: number, pid: pid, owner: owner,
      x: rect.origin.x - displayOrigin.x, y: rect.origin.y - displayOrigin.y,
      w: rect.size.width, h: rect.size.height, layer: layer)
  }
}

/// Whether the login session's screen is locked.
///
/// A locked or sleeping display still answers a capture, and what comes back is
/// black. Black is a luminance the accumulator cannot tell from a dark panel,
/// so an unattended overnight run would book hours of "this panel was dark" at
/// the same weight as real use and drown the informative samples. This is the
/// same defect shape as the letterbox padding: a plausible measurement of
/// something that was never on screen.
@MainActor func screenIsLocked() -> Bool {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
  return (session["CGSSessionScreenIsLocked"] as? Int) == 1
}

/// Read PER SAMPLE, never once at launch.
///
/// A run that spans a light/dark switch would otherwise label every later
/// record with the appearance it started in. The measured side sees the real
/// appearance and the modelled side uses the stale flag, and BOTH replay
/// controls still pass, because the log stays self-consistent with its own
/// wrong label. Exercising the light prior is a thing this probe actively wants
/// the operator to do, so freezing it made the advice self-defeating.
@MainActor func currentAppearanceIsDark() -> Bool {
  // A plain read is enough: cfprefsd invalidates the cache, so a live toggle is
  // picked up [MEASURED 2026-08-18, with a positive and negative control pair].
  // An earlier version called `removeVolatileDomain(forName: .globalDomain)`
  // first, which measured byte-identical: NSGlobalDomain is a PERSISTENT domain
  // and `volatileDomainNames` is empty, so there was nothing to remove. Removed
  // rather than kept as a charm; the same idiom aimed at NSRegistrationDomain
  // would wipe every registered default.
  UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
}

let log = try ModelReplayLog(directory: options.out)

// A run header per RUN, not per directory. A single fixed name was overwritten
// on every restart, and restarting is something this tool asks for, so the
// provenance of everything already in the directory was being destroyed.
let startedAt = Date().timeIntervalSinceReferenceDate
let header: [String: Any] = [
  "startedAt": startedAt,
  "interval": options.interval,
  "maxSamples": options.maxSamples,
  "out": options.out.path,
  "displayFilter": options.displayFilter.map(String.init) ?? "all",
  "wallpaperOverride": options.wallpaper?.path ?? "(per display via NSWorkspace)",
  "appearanceIsDarkAtStart": currentAppearanceIsDark(),
]
try? JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted])
  .write(to: options.out.appendingPathComponent(String(format: "run-%.0f.json", startedAt)))

print("candela-model-capture: interval \(options.interval)s, out \(options.out.path)")
for entry in DisplayDiscovery.discover() {
  let resolved = wallpaperURL(for: entry.display.id)?.lastPathComponent ?? "(unreadable)"
  print("  display \(entry.display.id) \(entry.display.persistenceKey.prefix(8)): wallpaper \(resolved)")
}
if let filter = options.displayFilter { print("  restricted to display \(filter)") }
fflush(stdout)

var discovered = DisplayDiscovery.discover()
var lastOnline = Set<CGDirectDisplayID>()
var taken = 0
var written = 0
var skippedLocked = 0
var skippedAsleep = 0
var skippedBlack = 0
var skippedUnusable = 0
var mirroredReported = Set<CGDirectDisplayID>()
var unreachableReported = Set<CGDirectDisplayID>()
var captureFailures = 0
var writeFailures = 0
var contentFailures = 0
while taken < options.maxSamples {
  // `defer`, so every path counts and reports: it runs on `continue` too.
  //
  // The locked path used to `continue` before the progress print at the bottom
  // of the loop, so a run started on a locked screen burned its entire sample
  // budget in TOTAL silence and exited having written nothing. At the run
  // card's settings that is 16.7 hours of a blank terminal. Caught by running
  // the tool end to end at 02:00 with the screen locked, after four code
  // reviews had read the same lines without seeing it.
  defer {
    taken += 1
    if taken % 10 == 0 {
      // `written` first, deliberately. Counting ticks made a run whose grant
      // had been revoked look identical to a healthy one.
      print(
        "written \(written) records over \(taken) ticks  "
          + "skipped: locked \(skippedLocked), asleep \(skippedAsleep), black \(skippedBlack), "
          + "unusable \(skippedUnusable)  "
          + "failures: content \(contentFailures), capture \(captureFailures), write \(writeFailures)")
      fflush(stdout)
    }
  }

  let content: SCShareableContent
  do {
    content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
  } catch {
    // `taken` still advances: otherwise a permanently failing fetch spins past
    // --max-samples forever, writing nothing.
    contentFailures += 1
    FileHandle.standardError.write(Data("shareable content failed: \(error)\n".utf8))
    try await Task.sleep(for: .seconds(options.interval))
    continue
  }

  let appearanceIsDark = currentAppearanceIsDark()
  // Re-resolved on a TOPOLOGY CHANGE rather than blindly every tick. The ID-to-EDID-key map is what moves: CLAUDE.md
  // records the MAG going 3->2 and the Dell 2->3 across one dock cycle. Frozen
  // at launch, a swap silently writes one panel's records under the other
  // panel's key, and the fit then merges a landscape panel and a rotated one
  // into a single 240-cell map. Every control still passes. Discovery is IOKit
  // iteration only and issues no DDC traffic, so §2's single-writer rule is
  // safe, but it is not free: it leaks 2 mach ports per call and costs ~13 ms,
  // so calling it every tick turns a once-per-launch leak into a per-tick one.
  // Keying off the online display set catches the reconfiguration that matters
  // while leaving a steady rig alone.
  let onlineNow = Set(content.displays.map(\.displayID))
  if onlineNow != lastOnline {
    discovered = DisplayDiscovery.discover()
    lastOnline = onlineNow
  }

  // Silence is the failure mode this whole tool was rebuilt around: a panel that
  // is online but unreachable must say so once, not simply never appear.
  for entry in discovered where !content.displays.contains(where: { $0.displayID == entry.display.id })
    && !discovered.contains(where: { CGDisplayMirrorsDisplay($0.display.id) == entry.display.id })
  {
    let mirrorTarget = CGDisplayMirrorsDisplay(entry.display.id)
    if mirrorTarget == 0, unreachableReported.insert(entry.display.id).inserted {
      print(
        "  WARNING: \(entry.display.name) (id \(entry.display.id)) is online but absent from "
          + "ScreenCaptureKit and mirrors nothing. It will not be recorded.")
      fflush(stdout)
    }
  }

  if screenIsLocked() {
    skippedLocked += 1
    try await Task.sleep(for: .seconds(options.interval))
    continue
  }

  for scDisplay in content.displays {
    if let wanted = options.displayFilter, scDisplay.displayID != wanted { continue }
    // A sleeping display captures as black. Never book that as content.
    if CGDisplayIsAsleep(scDisplay.displayID) != 0 {
      skippedAsleep += 1
      continue
    }
    // DisplayDiscovery returns only external DDC-capable panels, so a virtual
    // display and the built-in have no entry. They are still perfectly good
    // capture surfaces: EM13 makes the measured side the composited
    // framebuffer rather than emitted light, so nothing here needs a physical
    // panel. Fall back to a key derived from the display ID, which is stable
    // for the life of a run and is only used to group records.
    // A MIRRORING panel is absent from ScreenCaptureKit entirely, so the pixels
    // it is showing arrive here under the display it mirrors. Attribute them to
    // the PANEL, never to the surface carrying them: a virtual display has no
    // EDID and its fallback key changes when it is recreated, so nothing
    // accumulated under it can be attached to the glass that actually wore.
    //
    // Measured 2026-08-18 with a synthesized size engaged: the MAG reported
    // `inSCK=false, mirrorOf=79` while online, awake and advertising its native
    // descriptor, and produced ZERO records. Silent, because a display missing
    // from the list is indistinguishable from one that was skipped.
    let mirroring = discovered.first {
      CGDisplayMirrorsDisplay($0.display.id) == scDisplay.displayID
    }
    if let mirroring, mirroredReported.insert(mirroring.display.id).inserted {
      print(
        "  note: \(mirroring.display.name) (id \(mirroring.display.id)) is mirroring "
          + "display \(scDisplay.displayID); attributing its capture to the panel")
      fflush(stdout)
    }
    let persistenceKey =
      mirroring?.display.persistenceKey
      ?? discovered.first(where: { $0.display.id == scDisplay.displayID })?.display.persistenceKey
      ?? "cgdisplay-\(scDisplay.displayID)"
    guard
      let rotation = DisplayRotation(
        degrees: CGDisplayRotation(mirroring?.display.id ?? scDisplay.displayID))
    else {
      // Counted, not silent: an all-zero skip line beside zero written records
      // is the "recording nothing" shape the progress rewrite exists to expose.
      skippedUnusable += 1
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
      captureFailures += 1
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
    else {
      skippedUnusable += 1
      continue
    }

    // Belt and braces: an awake, unlocked display that captures pure black is
    // more likely a state we failed to detect than a panel genuinely showing
    // nothing. Dropping it costs one sample; booking it costs the run.
    if captured.allSatisfy({ $0 <= 0 }) {
      skippedBlack += 1
      continue
    }

    let measuredPanel = transform.panelNativeGrid(
      fromDisplayGrid: captured, cols: cols, rows: rows)
    let paperURL = wallpaperURL(for: scDisplay.displayID)
    let paper = wallpaperCells(url: paperURL, for: transform)
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

    let record = ModelReplayRecord(
      t: Date().timeIntervalSinceReferenceDate, elapsed: options.interval,
      display: .init(
        persistenceKey: persistenceKey, displayID: scDisplay.displayID,
        pixelWidth: scDisplay.width, pixelHeight: scDisplay.height, rotation: rotation),
      capture: .init(cols: cols, rows: rows, grid: captured),
      measuredPanel: measuredPanel, modelledBaseline: modelled,
      wallpaper: paper, wallpaperPath: paperURL?.path ?? "",
      appearanceIsDark: appearanceIsDark, windows: observed, chrome: chrome)

    // Never an unguarded `try` in this loop: a full disk, a removed output
    // directory or a non-finite window rect would otherwise end a multi-hour
    // run at whatever point it happened.
    do {
      try log.append(record)
      written += 1
    } catch {
      writeFailures += 1
      FileHandle.standardError.write(Data("append failed: \(error)\n".utf8))
    }
  }

  try await Task.sleep(for: .seconds(options.interval))
}

if written == 0 {
  FileHandle.standardError.write(
    Data(
      ("\nWROTE NOTHING over \(taken) ticks: locked \(skippedLocked), asleep \(skippedAsleep), "
        + "black \(skippedBlack), unusable \(skippedUnusable), content \(contentFailures), "
        + "capture \(captureFailures), write \(writeFailures).\n"
        + "A locked screen is the usual cause; nothing was recorded.\n").utf8))
  exit(1)
}
print("done: \(written) records over \(taken) ticks")
