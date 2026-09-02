import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

// Records paired (measured, model-inputs) samples so candidate exposure models
// can be fitted and scored offline.
//
// Deliberately NOT part of the app: iterating on the model against the shipped
// build costs a deploy plus a multi-day soak to read one number. Nothing here
// writes DDC, it only reads the screen, so it is safe to run alongside the live
// comparison.
//
// The wallpaper is read PER DISPLAY through NSWorkspace, the same source the app's
// own wallpaper island uses. A single explicit --wallpaper path cannot express a rig
// running a different wallpaper on each panel, and it diverged from the app on
// precisely the input being fitted: a Dell showing nothing but wallpaper scored 0.201
// against its own wallpaper term where it should have scored ~1.0. The resolved path
// is recorded per sample, and --wallpaper survives as an override.
//
// **Attribution is PANEL space, capture is SURFACE space, and the two are not the
// same set of displays.** ScreenCaptureKit OMITS a display that is mirroring, so a
// panel showing pixels can be absent from `SCShareableContent.displays` while the
// surface it mirrors onto is present. So: one capture per SURFACE, one record per
// PANEL showing that surface. `CaptureAttribution` is the whole of that decision, it
// is pure, and `--self-test` exercises every branch, including the mirror topologies
// this rig cannot be reconfigured into on demand.

let candelaBundleID = "com.rydersel.Candela"

struct Options {
  var displayFilter: CGDirectDisplayID?
  var wallpaper: URL?
  var interval: Double = 60
  var out = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Candela/model-replay")
  var maxSamples = Int.max
  var selfTest = false
}

func usage() -> Never {
  print("""
  candela-model-capture: record paired exposure samples for offline model fitting

    --display <id>        only this display (default: every online display)
    --wallpaper <path>    desktop picture, decoded through ImageIO
    --interval <seconds>  sampling period (default 60)
    --out <dir>           log directory (default ~/Library/Application Support/Candela/model-replay)
    --max-samples <n>     stop after this many samples per display
    --self-test           run the attribution and guard checks over synthetic
                          topologies, print the result, and exit

  The wallpaper is re-read per sample, per display. Point --out at a FRESH
  directory: this tool appends to whatever is already there, and the fit reads
  every file in the directory.

  --display accepts either a PANEL or the SURFACE it mirrors onto; a mirroring
  panel is absent from ScreenCaptureKit, so filtering on the surface alone
  would silently match nothing.

  Ctrl-C prints the same final summary the sample budget does, and exits
  non-zero when nothing was written.
  """)
  exit(2)
}

// MARK: - Counters

/// Every number the run reports. One struct so a snapshot is coherent: the
/// signal handler reads it off its own thread while the sampling loop is mid
/// tick, and a torn read would print a summary describing no instant.
struct Tally: Sendable {
  var taken = 0
  var written = 0
  // Whole ticks.
  var skippedLocked = 0
  var skippedSessionUnknown = 0
  var skippedNoSurfaces = 0
  var contentFailures = 0
  // Records that were planned and did not happen. Counted per RECORD, never
  // per surface, so `written` plus these is the number of records the tick
  // intended to write.
  var skippedAsleep = 0
  var skippedBlack = 0
  var skippedUnusable = 0
  var skippedFiltered = 0
  var skippedDuplicate = 0
  var skippedRotationMismatch = 0
  var skippedTopologyMoved = 0
  var skippedWallpaperUndecodable = 0
  var wallpaperMissing = 0
  var captureFailures = 0
  var writeFailures = 0

  /// Every counter, always, even at zero: a skip line that hides its zeroes cannot be
  /// read as "nothing was dropped" versus "this build has no such counter".
  var line: String {
    "written \(written) records over \(taken) ticks  "
      + "ticks skipped: locked \(skippedLocked), session-unknown \(skippedSessionUnknown), "
      + "no-surfaces \(skippedNoSurfaces), content \(contentFailures)  "
      + "records skipped: asleep \(skippedAsleep), black \(skippedBlack), "
      + "unusable \(skippedUnusable), filtered \(skippedFiltered), "
      + "duplicate \(skippedDuplicate), rotation \(skippedRotationMismatch), "
      + "topology-moved \(skippedTopologyMoved), wallpaper \(skippedWallpaperUndecodable)  "
      + "notes: wallpaper-missing \(wallpaperMissing)  "
      + "failures: capture \(captureFailures), write \(writeFailures)"
  }
}

/// The tally behind a lock, so the signal handler and the sampling loop can
/// both reach it.
///
/// `@unchecked Sendable` is confined by construction: the only stored state is the
/// tally, every access is inside `lock`, and nothing hands out a reference to it. The
/// retained signal sources are written once before any tick runs and never read.
final class Ledger: @unchecked Sendable {
  private let lock = NSLock()
  private var tally = Tally()
  private var sources: [DispatchSourceSignal] = []

  func note(_ change: (inout Tally) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    change(&tally)
  }

  var snapshot: Tally {
    lock.lock()
    defer { lock.unlock() }
    return tally
  }

  func retain(_ signalSources: [DispatchSourceSignal]) {
    lock.lock()
    defer { lock.unlock() }
    sources = signalSources
  }
}

/// The ONE exit path, shared by the sample budget and by Ctrl-C.
///
/// The "wrote nothing, exit non-zero" guarantee used to sit after the sampling loop,
/// which only ends once `--max-samples` ticks have elapsed. In practice the operator
/// always ends with Ctrl-C, so neither the summary nor the exit status ever ran and a
/// whole session could report success by saying nothing.
func finishRun(_ ledger: Ledger, reason: String) -> Never {
  let tally = ledger.snapshot
  if tally.written == 0 {
    // The hint is CONDITIONAL: a fixed "a locked screen is the usual cause" line
    // beside a non-zero wallpaper or duplicate counter misdirects the diagnosis.
    let hint =
      tally.skippedLocked > 0 || tally.skippedSessionUnknown > 0
      ? "A locked screen is the usual cause; nothing was recorded.\n"
      : "Read the non-zero counters above: they name what refused every record.\n"
    FileHandle.standardError.write(
      Data(("\nWROTE NOTHING (\(reason)).\n" + tally.line + "\n" + hint).utf8))
    exit(1)
  }
  FileHandle.standardOutput.write(Data(("\ndone (\(reason)): " + tally.line + "\n").utf8))
  exit(0)
}

/// Ctrl-C and `kill` both land on the summary rather than on a bare kill.
///
/// `SIG_IGN` first, because a `DispatchSource` signal handler runs IN ADDITION to
/// the default disposition, and the default for both is to terminate before it runs.
func installSignalHandlers(_ ledger: Ledger) {
  var sources: [DispatchSourceSignal] = []
  for number in [SIGINT, SIGTERM] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
      finishRun(ledger, reason: number == SIGINT ? "interrupted" : "terminated")
    }
    source.activate()
    sources.append(source)
  }
  ledger.retain(sources)
}

// MARK: - Attribution

/// A display that gets its own record, and the key that record is filed under.
struct AttributionTarget: Equatable, Sendable {
  var id: CGDirectDisplayID
  var key: String
  var name: String
  /// False for the display-ID fallback: a virtual display or the built-in,
  /// neither of which `DisplayDiscovery` returns and neither of which has an
  /// EDID key that survives being recreated.
  var isKnownPanel: Bool
}

/// One capture, and every panel that record is written for.
struct SurfacePlan: Equatable, Sendable {
  var surface: CGDirectDisplayID
  var targets: [AttributionTarget]
}

/// What one tick intends to do, and everything it refused, with a reason.
struct CapturePlan: Equatable, Sendable {
  var surfaces: [SurfacePlan] = []
  /// Keys refused because another surface in the SAME tick already claimed
  /// them.
  var duplicateKeys: [String] = []
  /// Sentences, one per target dropped for a rotation the surface's grid
  /// cannot describe.
  var rotationRefusals: [String] = []
  var filteredOut = 0
  /// Known panels that no surface in this tick attributes anything to. The
  /// only honest "this panel is recording nothing" signal, because it is read
  /// off the result rather than predicted from a mirror flag.
  var unreachablePanels: [CGDirectDisplayID] = []
  /// A `--display` value that matched no panel and no surface this tick.
  var filterMatchedNothing = false

  var recordCount: Int { surfaces.reduce(0) { $0 + $1.targets.count } }
}

/// A panel `DisplayDiscovery` found, reduced to what attribution needs.
struct KnownPanel: Equatable, Sendable {
  var id: CGDirectDisplayID
  var name: String
  var persistenceKey: String
}

/// Pure. Every mirror question in a tick is answered from ONE `MirrorTopology`
/// sample and one rotation sample, so no two answers can describe different instants.
enum CaptureAttribution {
  /// The panels showing `surface`'s pixels, `id`-ascending.
  ///
  /// A mirror set is one master with N slaves, so N greater than 1 is ORDINARY, not
  /// an edge case: taking the first match gave one of two slaves nothing at all,
  /// silently, and picked a different loser whenever discovery order changed. Sorting
  /// by ID keeps a mid-session re-discovery from splitting one panel's stream across
  /// two keys.
  ///
  /// When the surface is itself a panel it is in this list too. Panel A mirroring onto
  /// panel B used to resolve B's own capture to A, so B stopped accumulating under its
  /// own key with no warning, because B was in the ScreenCaptureKit list throughout.
  static func targets(
    surface: CGDirectDisplayID, topology: MirrorTopology, panels: [CGDirectDisplayID: KnownPanel]
  ) -> [AttributionTarget] {
    let members = ([surface] + topology.slaves(of: surface)).sorted()
    let known = members.compactMap { panels[$0] }
    guard !known.isEmpty else {
      // `DisplayDiscovery` returns only external DDC-capable panels, so a virtual
      // display and the built-in have no entry. They are still good capture surfaces:
      // The measured side is the composited framebuffer, not emitted light.
      return [
        AttributionTarget(
          id: surface, key: "cgdisplay-\(surface)", name: "display \(surface)",
          isKnownPanel: false)
      ]
    }
    return known.map {
      AttributionTarget(id: $0.id, key: $0.persistenceKey, name: $0.name, isKnownPanel: true)
    }
  }

  /// The whole tick's decision, refusals included.
  ///
  /// - Parameter rotations: every online display's `CGDisplayRotation`, sampled
  ///   with the topology.
  static func plan(
    surfaces: [CGDirectDisplayID], topology: MirrorTopology,
    panels: [CGDirectDisplayID: KnownPanel], rotations: [CGDirectDisplayID: Double],
    filter: CGDirectDisplayID?
  ) -> CapturePlan {
    var plan = CapturePlan()
    var claimed = Set<String>()
    var attributed = Set<CGDirectDisplayID>()
    var unfiltered: [SurfacePlan] = []

    for surface in surfaces.sorted() {
      var kept: [AttributionTarget] = []
      for target in targets(surface: surface, topology: topology, panels: panels) {
        // The capture's grid is in the SURFACE's display space. Reading a panel's
        // own rotation while taking geometry from the surface is how a record ends up
        // describing neither display.
        let surfaceRotation = rotations[surface]
        let targetRotation = rotations[target.id] ?? surfaceRotation
        guard let surfaceRotation, let targetRotation,
          DisplayRotation(degrees: surfaceRotation) != nil,
          surfaceRotation == targetRotation
        else {
          plan.rotationRefusals.append(
            "\(target.name) (id \(target.id)) reads rotation "
              + "\(rotations[target.id].map { "\($0)" } ?? "(absent)") while surface "
              + "\(surface) reads \(rotations[surface].map { "\($0)" } ?? "(absent)"); "
              + "one grid cannot describe both")
          continue
        }
        // The single-record-per-panel property otherwise rests entirely on the
        // measured claim that ScreenCaptureKit omits a mirroring display. If that
        // stops holding, master and slave both arrive as surfaces, resolve to one
        // panel, and two records land under one key at one timestamp.
        guard claimed.insert(target.key).inserted else {
          plan.duplicateKeys.append(target.key)
          continue
        }
        attributed.insert(target.id)
        kept.append(target)
      }
      if !kept.isEmpty { unfiltered.append(SurfacePlan(surface: surface, targets: kept)) }
    }

    // Read off the plan, not predicted from a mirror flag: a panel is
    // unreachable exactly when nothing in this tick writes for it.
    plan.unreachablePanels = panels.keys.filter { !attributed.contains($0) }.sorted()

    guard let filter else {
      plan.surfaces = unfiltered
      return plan
    }
    // Matched against the PANEL as well as the surface. Filtering on the surface
    // alone matched nothing whenever the named panel was mirroring, since such a panel
    // is absent from ScreenCaptureKit: zero records and an all-zero skip line.
    for entry in unfiltered {
      let kept = entry.targets.filter { $0.id == filter || entry.surface == filter }
      plan.filteredOut += entry.targets.count - kept.count
      if !kept.isEmpty { plan.surfaces.append(SurfacePlan(surface: entry.surface, targets: kept)) }
    }
    plan.filterMatchedNothing = plan.surfaces.isEmpty
    return plan
  }
}

// MARK: - Self-test

/// Proves each guard can fire, over topologies this rig cannot be
/// reconfigured into on demand.
///
/// A check whose failure mode is silence is not a check: every case below is paired
/// with the configuration that must produce the OPPOSITE answer, so a predicate that
/// has stopped discriminating fails here rather than passing quietly.
func runSelfTest() -> Never {
  var failures = 0
  func expect(_ label: String, _ condition: Bool) {
    print("  \(condition ? "ok  " : "FAIL") \(label)")
    if !condition { failures += 1 }
  }

  func display(
    _ id: CGDirectDisplayID, mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    isMaster: Bool = false
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(vendor: id, model: id, serial: id, isBuiltIn: false),
      name: "d\(id)", isBuiltIn: false, mirrorsDisplay: mirrors,
      isInMirrorSet: isMaster || mirrors != kCGNullDirectDisplay)
  }
  let mag = KnownPanel(id: 2, name: "MAG", persistenceKey: "3669-mag")
  let dell = KnownPanel(id: 3, name: "DELL", persistenceKey: "10AC-dell")
  let flat: [CGDirectDisplayID: Double] = [1: 0, 2: 0, 3: 0, 79: 0]

  print("candela-model-capture --self-test")

  // A steady rig: one record per surface, each under its own key.
  let steady = MirrorTopology([display(1), display(2), display(3)])
  let steadyPlan = CaptureAttribution.plan(
    surfaces: [1, 2, 3], topology: steady, panels: [2: mag, 3: dell], rotations: flat, filter: nil)
  expect("steady rig writes one record per display", steadyPlan.recordCount == 3)
  expect("steady rig reports nothing unreachable", steadyPlan.unreachablePanels.isEmpty)
  expect(
    "the built-in falls back to a display-ID key",
    steadyPlan.surfaces.first { $0.surface == 1 }?.targets.first?.key == "cgdisplay-1")

  // A synthesized size: the MAG mirrors a virtual display and is absent from
  // ScreenCaptureKit, so only the VD is a surface.
  let synthesized = MirrorTopology([display(1), display(2, mirrors: 79), display(3), display(79, isMaster: true)])
  let synthesizedPlan = CaptureAttribution.plan(
    surfaces: [1, 3, 79], topology: synthesized, panels: [2: mag, 3: dell], rotations: flat,
    filter: nil)
  expect(
    "a mirroring panel is recorded under its own EDID key",
    synthesizedPlan.surfaces.first { $0.surface == 79 }?.targets == [
      AttributionTarget(id: 2, key: "3669-mag", name: "MAG", isKnownPanel: true)
    ])
  expect("no panel is unreachable while it mirrors", synthesizedPlan.unreachablePanels.isEmpty)

  // The filter is the blocking case: --display <MAG> used to compare against
  // the surface and match nothing at all.
  let filtered = CaptureAttribution.plan(
    surfaces: [1, 3, 79], topology: synthesized, panels: [2: mag, 3: dell], rotations: flat,
    filter: 2)
  expect("--display finds a panel through the surface it mirrors", filtered.recordCount == 1)
  expect("--display on a mirroring panel is not a silent miss", !filtered.filterMatchedNothing)
  let missed = CaptureAttribution.plan(
    surfaces: [1, 3], topology: steady, panels: [2: mag, 3: dell], rotations: flat, filter: 99)
  expect("a filter that matches nothing says so", missed.filterMatchedNothing)

  // Two slaves on one surface. Taking the first match gave one of them nothing.
  let twoSlaves = MirrorTopology([
    display(1, isMaster: true), display(2, mirrors: 1), display(3, mirrors: 1),
  ])
  let twoSlavesPlan = CaptureAttribution.plan(
    surfaces: [1], topology: twoSlaves, panels: [2: mag, 3: dell], rotations: flat, filter: nil)
  expect("two panels on one surface both get a record", twoSlavesPlan.recordCount == 2)
  expect(
    "and in a discovery-order-independent order",
    twoSlavesPlan.surfaces.first?.targets.map(\.id) == [2, 3])

  // Panel mirroring onto panel: the master must keep its own key.
  let panelOntoPanel = MirrorTopology([display(2, mirrors: 3), display(3, isMaster: true)])
  let panelPlan = CaptureAttribution.plan(
    surfaces: [3], topology: panelOntoPanel, panels: [2: mag, 3: dell], rotations: flat,
    filter: nil)
  expect(
    "a mirrored-onto panel still records under its own key",
    panelPlan.surfaces.first?.targets.map(\.key) == ["3669-mag", "10AC-dell"])

  // Duplicate: if ScreenCaptureKit ever lists a mirroring display too, the
  // same key arrives twice in one tick at one timestamp.
  let duplicatePlan = CaptureAttribution.plan(
    surfaces: [2, 79], topology: synthesized, panels: [2: mag], rotations: flat, filter: nil)
  expect("a repeated key in one tick is refused", duplicatePlan.duplicateKeys == ["3669-mag"])
  expect("and only one record survives", duplicatePlan.recordCount == 1)

  // Rotation: the surface's grid cannot describe a panel at a different angle.
  let mismatched = CaptureAttribution.plan(
    surfaces: [1], topology: twoSlaves, panels: [2: mag, 3: dell],
    rotations: [1: 0, 2: 0, 3: 270], filter: nil)
  expect("a slave at another rotation is refused", mismatched.rotationRefusals.count == 1)
  expect("while its same-rotation sibling is kept", mismatched.recordCount == 1)
  let unrepresentable = CaptureAttribution.plan(
    surfaces: [1], topology: MirrorTopology([display(1)]), panels: [1: mag],
    rotations: [1: 45], filter: nil)
  expect("a rotation no transform can describe is refused", unrepresentable.recordCount == 0)

  // Unreachable, read off the result rather than from a mirror flag.
  let absent = CaptureAttribution.plan(
    surfaces: [3], topology: steady, panels: [2: mag, 3: dell], rotations: flat, filter: nil)
  expect("a panel no surface carries is reported unreachable", absent.unreachablePanels == [2])

  print(failures == 0 ? "self-test passed" : "self-test FAILED (\(failures))")
  exit(failures == 0 ? 0 : 1)
}

// MARK: - Arguments

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
  case "--self-test": options.selfTest = true
  default: usage()
  }
}

if options.selfTest { runSelfTest() }

guard CGPreflightScreenCaptureAccess() else {
  // A shell-launched process inherits the terminal's grant, so this failing
  // means the TERMINAL lacks Screen Recording, not the tool.
  FileHandle.standardError.write(
    Data("no Screen Recording grant. Grant it to this terminal, then retry.\n".utf8))
  exit(1)
}

let ownPID = ProcessInfo.processInfo.processIdentifier

// MARK: - Sampling helpers

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

/// Why a record has no backdrop, kept apart from having one.
///
/// The wallpaper is the model's weakest input, so a run that silently lost it on
/// some fraction of its records produces a verdict about that fraction.
enum Backdrop {
  case cells([Double])
  /// NSWorkspace named no image for this display. Recorded anyway with an empty
  /// path, which the fit can see.
  case noWallpaper
  /// An image was named and could not be turned into cells. The record is REFUSED:
  /// a decode failure looks exactly like a model that cannot predict, so mixing these
  /// into the fit absorbs the failure into the app priors.
  case undecodable(String)
}

/// Panel-physical wallpaper cells, through the same reduction the app uses so
/// the model and the measurement disagree only about content.
@MainActor func backdrop(url: URL?, for transform: PanelSpaceTransform) -> Backdrop {
  guard let url else { return .noWallpaper }
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 512,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary)
  else { return .undecodable(url.path) }
  let (cols, rows) = LuminanceReduction.requestedSize(
    displayWidth: Int(transform.displaySize.width),
    displayHeight: Int(transform.displaySize.height))
  let filled = LuminanceReduction.cropToFill(
    image, aspect: transform.displaySize.width / transform.displaySize.height)
  guard let grid = LuminanceReduction.meanLuminance(of: filled, cols: cols, rows: rows) else {
    return .undecodable(url.path)
  }
  return .cells(transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows))
}

/// ONE window-server listing per tick, taken adjacently for both option sets.
///
/// Both sides of the pairing have to describe one instant. Run per display and after
/// that display's capture and wallpaper decode, the window server was queried 2N times
/// at 2N instants, and two displays' records could disagree about what was on screen
/// in the same tick.
///
/// `everything` is read FIRST, deliberately. Chrome is the set difference, so a window
/// that opens between the two calls appears only in the narrower list: in this order
/// it is admitted to the model, the other way round it is mislabelled as chrome.
struct WindowSample {
  let everything: [[String: Any]]
  let observed: [[String: Any]]
}

@MainActor func sampleWindows() -> WindowSample {
  func listing(_ options: CGWindowListOption) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
  }
  let everything = listing([.optionOnScreenOnly])
  // Exactly what the app's own source reports, so the baseline is reproducible.
  let observed = listing([.optionOnScreenOnly, .excludeDesktopElements])
  return WindowSample(everything: everything, observed: observed)
}

/// Candela's windows, identified the SAME WAY the ScreenCaptureKit filter
/// identifies them.
///
/// The two sides used different criteria: the capture excluded by bundle identifier,
/// this list by the process name `Candela`. A worktree or renamed build owns windows
/// under a different process name and the same bundle identifier, so the measured side
/// dropped its dimming overlays while the modelled side admitted them, feeding the
/// app's own dimming back into the input being fitted against.
///
/// Cached per tick: the lookup is a process-table read, and a busy desktop has well
/// over a hundred window entries spread across a couple of dozen pids.
@MainActor final class CandelaOwnership {
  private var cache: [Int32: Bool] = [:]

  func isCandela(pid: Int32) -> Bool {
    if let known = cache[pid] { return known }
    let verdict = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == candelaBundleID
    cache[pid] = verdict
    return verdict
  }
}

/// On-screen windows in display-local coordinates, front-to-back, with our own
/// process and Candela's overlays removed.
///
/// Candela's exclusion is not tidiness: detection dimming draws overlays, and
/// capturing them feeds the dimming back into the measurement being fitted against.
@MainActor func windows(
  from entries: [[String: Any]], displayOrigin: CGPoint, ownership: CandelaOwnership
) -> [ModelReplayRecord.Window] {
  entries.compactMap { entry in
    guard let number = entry[kCGWindowNumber as String] as? UInt32,
      let pid = entry[kCGWindowOwnerPID as String] as? Int32,
      let layer = entry[kCGWindowLayer as String] as? Int,
      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return nil }
    // Dropped when nameless, exactly as CGWindowListSource does. Admitting one as ""
    // would let it earn a fitted prior the shipped model can never produce.
    guard let owner = entry[kCGWindowOwnerName as String] as? String, !owner.isEmpty else {
      return nil
    }
    guard pid != ownPID, !ownership.isCandela(pid: pid) else { return nil }
    return ModelReplayRecord.Window(
      id: number, pid: pid, owner: owner,
      x: rect.origin.x - displayOrigin.x, y: rect.origin.y - displayOrigin.y,
      w: rect.size.width, h: rect.size.height, layer: layer)
  }
}

/// Whether the login session's screen is locked, with "cannot tell" as its own
/// answer.
///
/// A locked or sleeping display still answers a capture, and what comes back is
/// black, which the accumulator cannot tell from a dark panel. An unattended overnight
/// run would book hours of "this panel was dark" at the weight of real use.
///
/// **An unreadable session dictionary is treated as LOCKED, not as unlocked.** A lock
/// screen is not black, so the black-frame guard downstream would not catch what a
/// fail-open read admits. Failing closed costs a run that writes nothing and says why;
/// failing open costs a run that writes a verdict about a lock screen.
enum ScreenLockState { case unlocked, locked, unknown }

@MainActor func screenLockState() -> ScreenLockState {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unknown }
  return (session["CGSSessionScreenIsLocked"] as? Int) == 1 ? .locked : .unlocked
}

/// Read PER SAMPLE, never once at launch.
///
/// A run that spans a light/dark switch would otherwise label every later record
/// with the appearance it started in. The measured side sees the real appearance, the
/// modelled side uses the stale flag, and BOTH replay controls still pass, because the
/// log stays self-consistent with its own wrong label.
@MainActor func currentAppearanceIsDark() -> Bool {
  // A plain read is enough: cfprefsd invalidates the cache, so a live toggle is
  // picked up [MEASURED, with a positive and negative control pair]. Do not add
  // `removeVolatileDomain(forName: .globalDomain)` back: it measured byte-identical
  // (NSGlobalDomain is PERSISTENT and `volatileDomainNames` is empty), and the same
  // idiom aimed at NSRegistrationDomain would wipe every registered default.
  UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
}

let configurator = CoreGraphicsDisplayConfigurator()

/// ONE instant's mirror facts plus the rotations that pair with them.
@MainActor func sampleTopology() -> (topology: MirrorTopology, rotations: [CGDirectDisplayID: Double]) {
  let displays = configurator.displays()
  // No synthesis pairing needed: it only separates a mirror set the app engaged from
  // one the user asked for, and a capture measures the same pixels either way.
  let topology = MirrorTopology(displays)
  var rotations: [CGDirectDisplayID: Double] = [:]
  for entry in displays { rotations[entry.id] = CGDisplayRotation(entry.id) }
  return (topology, rotations)
}

func panelMap(
  _ discovered: [(display: ExternalDisplay, writer: any DDCWriting, facts: DisplayHardwareFacts)]
) -> [CGDirectDisplayID: KnownPanel] {
  var map: [CGDirectDisplayID: KnownPanel] = [:]
  for entry in discovered {
    map[entry.display.id] = KnownPanel(
      id: entry.display.id, name: entry.display.name,
      persistenceKey: entry.display.persistenceKey)
  }
  return map
}

var warned = Set<String>()
@MainActor func warnOnce(_ id: String, _ message: String) {
  guard warned.insert(id).inserted else { return }
  print("  \(message)")
  fflush(stdout)
}

// MARK: - Run

let ledger = Ledger()
installSignalHandlers(ledger)

let log = try ModelReplayLog(directory: options.out)

// A run header per RUN, not per directory: a single fixed name was overwritten on
// every restart, destroying the provenance of everything already in the directory.
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
var discovered = DisplayDiscovery.discover()
for entry in discovered {
  let resolved = wallpaperURL(for: entry.display.id)?.lastPathComponent ?? "(unreadable)"
  print("  display \(entry.display.id) \(entry.display.persistenceKey.prefix(8)): wallpaper \(resolved)")
}
if let filter = options.displayFilter { print("  restricted to display \(filter)") }
fflush(stdout)

var panels = panelMap(discovered)
// The RE-DISCOVERY TRIGGER, and it is the identity map rather than the id set.
//
// The ID-to-key map is what moves: display IDs are reassigned across a replug, and the
// observed case is two panels swapping IDs across one dock cycle. That leaves the id
// SET identical, so a set comparison never sees the reconfiguration and the stale map
// keeps booking each panel's capture under the other panel's key.
//
// The identity map is free here, since `sampleTopology` already reads it every tick.
// Re-running `DisplayDiscovery` unconditionally is not: it is IOKit iteration that
// leaks 2 mach ports per call and costs ~13 ms, turning a once-per-launch leak into a
// per-tick one.
//
// Seeded from the launch enumeration, so the first tick does not immediately re-run
// discovery against an empty map.
var lastIdentities = sampleTopology().topology.displays.reduce(
  into: [CGDirectDisplayID: String]()
) { $0[$1.id] = $1.identity.key }

while ledger.snapshot.taken < options.maxSamples {
  // `defer`, so every path counts and reports: it runs on `continue` too. The locked
  // path used to `continue` before the progress print at the bottom of the loop, so a
  // run started on a locked screen burned its whole sample budget in TOTAL silence and
  // exited having written nothing.
  defer {
    var tally = Tally()
    ledger.note {
      $0.taken += 1
      tally = $0
    }
    if tally.taken % 10 == 0 {
      // `written` first, deliberately. Counting ticks made a run whose grant
      // had been revoked look identical to a healthy one.
      print(tally.line)
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
    ledger.note { $0.contentFailures += 1 }
    FileHandle.standardError.write(Data("shareable content failed: \(error)\n".utf8))
    try await Task.sleep(for: .seconds(options.interval))
    continue
  }

  // An empty list ran no loop body and counted nothing, so a grant revoked
  // mid-run advanced the tick counter and moved no other number.
  if content.displays.isEmpty {
    ledger.note { $0.skippedNoSurfaces += 1 }
    warnOnce(
      "no-surfaces",
      "WARNING: ScreenCaptureKit reported ZERO displays. The Screen Recording grant is the "
        + "usual cause; nothing can be recorded while this holds.")
    try await Task.sleep(for: .seconds(options.interval))
    continue
  }

  switch screenLockState() {
  case .locked:
    ledger.note { $0.skippedLocked += 1 }
    try await Task.sleep(for: .seconds(options.interval))
    continue
  case .unknown:
    ledger.note { $0.skippedSessionUnknown += 1 }
    warnOnce(
      "session-unknown",
      "WARNING: the login session dictionary is unreadable, so a locked screen cannot be ruled "
        + "out. Ticks are being skipped rather than booked as content.")
    try await Task.sleep(for: .seconds(options.interval))
    continue
  case .unlocked: break
  }

  let appearanceIsDark = currentAppearanceIsDark()
  let (topology, rotations) = sampleTopology()
  let identities = topology.displays.reduce(into: [CGDirectDisplayID: String]()) {
    $0[$1.id] = $1.identity.key
  }
  if identities != lastIdentities {
    discovered = DisplayDiscovery.discover()
    panels = panelMap(discovered)
    lastIdentities = identities
  }

  let plan = CaptureAttribution.plan(
    surfaces: content.displays.map(\.displayID), topology: topology, panels: panels,
    rotations: rotations, filter: options.displayFilter)

  // Silence is the failure mode this whole tool was rebuilt around: a panel
  // that is online but recorded by nothing must say so once, not simply never
  // appear.
  for id in plan.unreachablePanels {
    warnOnce(
      "unreachable-\(id)",
      "WARNING: \(panels[id]?.name ?? "display \(id)") (id \(id)) is online but no capture "
        + "surface carries its pixels. It will not be recorded.")
  }
  for refusal in plan.rotationRefusals {
    ledger.note { $0.skippedRotationMismatch += 1 }
    warnOnce("rotation-\(refusal)", "WARNING: \(refusal)")
  }
  for key in plan.duplicateKeys {
    ledger.note { $0.skippedDuplicate += 1 }
    warnOnce(
      "duplicate-\(key)",
      "WARNING: two capture surfaces resolved to key \(key) in one tick. The second is refused; "
        + "ScreenCaptureKit is expected to omit a mirroring display and apparently did not.")
  }
  if plan.filteredOut > 0 { ledger.note { $0.skippedFiltered += plan.filteredOut } }
  if plan.filterMatchedNothing, let filter = options.displayFilter {
    warnOnce(
      "filter-miss",
      "WARNING: --display \(filter) matched no panel and no capture surface. Surfaces this tick: "
        + "\(content.displays.map(\.displayID).sorted()); panels: \(panels.keys.sorted()).")
  }
  for entry in plan.surfaces {
    let mirroring = entry.targets.filter { $0.id != entry.surface }
    guard !mirroring.isEmpty else { continue }
    warnOnce(
      "mirroring-\(entry.surface)-\(mirroring.map(\.key).joined(separator: "+"))",
      "note: \(mirroring.map { "\($0.name) (id \($0.id))" }.joined(separator: ", ")) "
        + "mirror display \(entry.surface); that capture is attributed to each of them")
  }

  let windowSample = sampleWindows()
  let ownership = CandelaOwnership()

  for entry in plan.surfaces {
    guard let scDisplay = content.displays.first(where: { $0.displayID == entry.surface })
    else { continue }
    let count = entry.targets.count

    // A sleeping display captures as black. Never book that as content.
    if CGDisplayIsAsleep(entry.surface) != 0
      || entry.targets.contains(where: { CGDisplayIsAsleep($0.id) != 0 })
    {
      ledger.note { $0.skippedAsleep += count }
      continue
    }

    guard let rotationDegrees = rotations[entry.surface],
      let rotation = DisplayRotation(degrees: rotationDegrees)
    else {
      // Counted, not silent: an all-zero skip line beside zero written records
      // is the "recording nothing" shape the progress rewrite exists to expose.
      ledger.note { $0.skippedUnusable += count }
      continue
    }

    let transform = PanelSpaceTransform(
      displaySize: CGSize(width: scDisplay.width, height: scDisplay.height), rotation: rotation)

    let excluded = content.windows.filter {
      $0.owningApplication?.processID == ownPID
        || $0.owningApplication?.bundleIdentifier == candelaBundleID
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
      ledger.note { $0.captureFailures += 1 }
      FileHandle.standardError.write(
        Data("capture failed on \(entry.surface): \(error)\n".utf8))
      continue
    }

    // Everything the capture's suspension can invalidate, re-checked: a sample taken
    // before a reconfiguration describes a machine that no longer exists. Attribution
    // matters most, since a mirror engaged or broken inside the suspension moves the
    // pixels to a different panel without the surface going anywhere.
    let (topologyNow, rotationsNow) = sampleTopology()
    let targetsNow = CaptureAttribution.targets(
      surface: entry.surface, topology: topologyNow, panels: panels)
    // A SUBSET rather than equality: the planned targets have already been through
    // the duplicate and filter passes, so they are legitimately fewer than what the
    // surface resolves to. What must not have happened is one of them going away.
    guard Set(entry.targets.map(\.key)).isSubset(of: Set(targetsNow.map(\.key))),
      rotationsNow[entry.surface] == rotationDegrees
    else {
      ledger.note { $0.skippedTopologyMoved += count }
      continue
    }

    // Delivered, never assumed.
    let cols = image.width
    let rows = image.height
    guard cols > 0, rows > 0,
      let captured = LuminanceReduction.meanLuminance(of: image, cols: cols, rows: rows)
    else {
      ledger.note { $0.skippedUnusable += count }
      continue
    }

    // An awake, unlocked display capturing pure black is more likely a state we
    // failed to detect than a panel showing nothing. Dropping it costs one sample;
    // booking it costs the run.
    if captured.allSatisfy({ $0 <= 0 }) {
      ledger.note { $0.skippedBlack += count }
      continue
    }

    let paperURL = wallpaperURL(for: entry.surface)
    let paper: [Double]?
    switch backdrop(url: paperURL, for: transform) {
    case .cells(let cells):
      paper = cells
    case .noWallpaper:
      paper = nil
      ledger.note { $0.wallpaperMissing += count }
      warnOnce(
        "wallpaper-missing-\(entry.surface)",
        "WARNING: no desktop picture resolved for display \(entry.surface). Its records carry no "
          + "backdrop and the model falls back to the appearance prior on them.")
    case .undecodable(let path):
      ledger.note { $0.skippedWallpaperUndecodable += count }
      warnOnce(
        "wallpaper-undecodable-\(path)",
        "WARNING: the desktop picture at \(path) will not decode. Records for display "
          + "\(entry.surface) are REFUSED rather than fitted without a backdrop, which would look "
          + "exactly like a model that cannot predict.")
      continue
    }

    let measuredPanel = transform.panelNativeGrid(
      fromDisplayGrid: captured, cols: cols, rows: rows)
    let displayOrigin = CGDisplayBounds(entry.surface).origin
    let observed = windows(
      from: windowSample.observed, displayOrigin: displayOrigin, ownership: ownership)
    let everything = windows(
      from: windowSample.everything, displayOrigin: displayOrigin, ownership: ownership)
    let seen = Set(observed.map(\.id))
    let chrome = everything.filter { !seen.contains($0.id) }

    let inputs = ExposureModelInputs(
      windows: observed.map(\.snapshot), wallpaperCells: paper,
      appearanceIsDark: appearanceIsDark)
    let modelled = ExposureModel.modelledGrid(
      inputs: inputs, through: transform, parameters: .baseline)

    // One capture, one record PER PANEL showing it. The pixels are identical by
    // definition inside a mirror set, and the identity is not.
    for target in entry.targets {
      let record = ModelReplayRecord(
        t: Date().timeIntervalSinceReferenceDate, elapsed: options.interval,
        display: .init(
          persistenceKey: target.key, displayID: entry.surface,
          pixelWidth: scDisplay.width, pixelHeight: scDisplay.height, rotation: rotation),
        capture: .init(cols: cols, rows: rows, grid: captured),
        measuredPanel: measuredPanel, modelledBaseline: modelled,
        wallpaper: paper, wallpaperPath: paperURL?.path ?? "",
        appearanceIsDark: appearanceIsDark, windows: observed, chrome: chrome)

      // Never an unguarded `try` in this loop: a full disk, a removed output
      // directory or a non-finite window rect would end a multi-hour run mid-way.
      do {
        try log.append(record)
        ledger.note { $0.written += 1 }
      } catch {
        ledger.note { $0.writeFailures += 1 }
        FileHandle.standardError.write(Data("append failed: \(error)\n".utf8))
      }
    }
  }

  try await Task.sleep(for: .seconds(options.interval))
}

finishRun(ledger, reason: "sample budget reached")
