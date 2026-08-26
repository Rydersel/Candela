import CandelaKit
import CoreGraphics
import Foundation

// The vd host's re-exec contract: as `candela-probe --vd-engage <id> <w> <h>`
// this process performs the HiDPI engage and exits before any probe logic.
VirtualDisplayHost.handleEngageHelperInvocation()

var arguments = Array(CommandLine.arguments.dropFirst())

// Backlog #2: `--display <id>` narrows every subcommand to one display —
// without it, `native set`/`hdr on` fan out to the built-in and every
// external on a multi-monitor desk. Parsed once here, ahead of the switch,
// so the DDC subcommands inherit it for free.
var displayFilter: CGDirectDisplayID?
if let flagIndex = arguments.firstIndex(of: "--display") {
  guard flagIndex + 1 < arguments.count, let id = UInt32(arguments[flagIndex + 1]) else {
    print("usage: --display <CGDirectDisplayID> (see `candela-probe list`)")
    exit(2)
  }
  displayFilter = id
  arguments.removeSubrange(flagIndex ... flagIndex + 1)
}

let found = DisplayDiscovery.discover().filter { displayFilter == nil || $0.display.id == displayFilter }

let usage = """
usage: candela-probe [--display <id>] <subcommand>
  --display <id>                          limit any subcommand to one display
  list                                    online DDC-capable external displays
  get                                     DDC read of VCP 0x10
  set <0-100>                             DDC write of VCP 0x10
  ramp <from> <to> <step> <intervalMs>    DDC brightness sweep
  volume get|set <0-100>                  DDC read/write of VCP 0x62
  contrast get|set <0-100>                DDC read/write of VCP 0x12
  mute on|off                             DDC write of VCP 0x8D (1=mute, 2=unmute)
  vcp get <hex>|set <hex> <0-65535>       raw VCP prober
  modes                                   merged mode list, marking CGS-revealed entries
  curated                                 what the default size picker shows, after curation
  modeapply <ioModeID> [holdSeconds=5]    apply one mode by id at preview scope, then revert
  identity                                EDID identity facts as the checkup reads them, as JSON
  refreshsweep                            apply every rate at the native size at preview scope, then restore
  checkup validate <file>                 verify an exported checkup report against its own hash
  caps                                    DDC/CI capabilities string (VCP 0xF3) + volume verdict
  audio devices                           default CoreAudio output + native-volume check
  native get                              DisplayServicesGetBrightness per display
  native set <0-1>                        DisplayServicesSetBrightness + read-back
  hdr status                              MonitorPanel hasHDRModes / preferHDRModes
  hdr on|off                              toggle HDR, poll up to 5 s for settle
  gamma <0-1> [holdSeconds=15]            uniform gamma scale, held then reset
  gamma reset                             CGDisplayRestoreColorSyncSettings
  watch [seconds=10]                      100 ms native-brightness delta log
  topology                                online displays: kind, identity, virtual verdict, DDC pool
  vd create <slot 1-3> <w> <h> [--hidpi] [--hold <s>]  create a virtual display, hold, destroy
  vd online <id>                          is that display in THIS process's online list
  conform [--apply]                       assert the private-API platform assumptions; run after every macOS update
  regress [--apply] [--json <path>] [--record <dir>] [--commit <sha>] [--tools <dir>] [--debug-app <path>]  assert the app-behaviour invariants against the deployed app
"""

/// The DDC subcommands need a DDC-capable external display. The private-API
/// subcommands (native/hdr/gamma/watch) work on any online display — including
/// the built-in, and including an external whose DDC is locked by HDR mode.
struct ProbeDisplay {
  let id: CGDirectDisplayID
  /// The display's own title, as the app itself publishes it: its sidebar row's
  /// accessibility description and its settings window title.
  let title: String
  /// The label the probe PRINTS, which appends the display id so two panels of
  /// the same model can be told apart. Kept as a separate reading of the same
  /// display because the two are consumed by different things: a person reads
  /// this one, and the accessibility layer matches the title.
  var name: String { "\(title) [\(id)]" }
}

let online: [ProbeDisplay] = {
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
  return ids.prefix(Int(count)).map { id in
    let ddcName = found.first { $0.display.id == id }?.display.name
    let fallback = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    return ProbeDisplay(id: id, title: ddcName ?? fallback)
  }.filter { displayFilter == nil || $0.id == displayFilter }
}()

/// Appended to the "nothing to work on" messages so an unknown `--display` id
/// reads as a bad argument rather than as absent hardware.
let filterNote = displayFilter.map { " (filtered to --display \($0); `candela-probe list` shows the ids)" } ?? ""

func requireDDCDisplays() {
  guard found.isEmpty else { return }
  print("No DDC-capable external displays found.\(filterNote) (Is the display in HDR mode? DDC is locked while HDR is on.)")
  exit(1)
}

func requireOnlineDisplays() {
  guard online.isEmpty else { return }
  print("No online displays found.\(filterNote)")
  exit(1)
}

/// Hex VCP code parser that tolerates the `0x` prefix this tool itself prints
/// (`String(format: "0x%02x", …)`), so its own output pastes back in.
func parseHexByte(_ text: String) -> UInt8? {
  let body = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
  return UInt8(body, radix: 16)
}

/// Generic DDC read/write over `found`, shared by volume/contrast/mute/vcp.
func ddcGet(code: UInt8, label: String) async {
  requireDDCDisplays()
  for entry in found {
    let result = await entry.writer.read(command: code)
    // A read failure is normal on write-only panels (e.g. the MAG 341C, which
    // ACKs every write and returns all-zeros for every read) — not a tool fault.
    print("\(entry.display.name): \(label) \(result.map { "\($0.current)/\($0.max)" } ?? "read failed (panel may be write-only, or DDC is locked by HDR)")")
  }
}

func ddcSet(code: UInt8, value: UInt16, label: String) async {
  requireDDCDisplays()
  for entry in found {
    let ok = await entry.writer.write(command: code, value: value)
    print("\(entry.display.name): \(label) write \(value) -> \(ok ? "ok" : "FAILED")")
  }
}

/// Uniformly scales the display's *current* transfer table. Quartz hands back
/// the ColorSync default in a fresh process, so this is a scale of the default.
func applyGammaScale(_ scale: Float, to displayID: CGDirectDisplayID) -> Bool {
  let capacity = Int(CGDisplayGammaTableCapacity(displayID))
  guard capacity > 0 else { return false }
  var red = [CGGammaValue](repeating: 0, count: capacity)
  var green = [CGGammaValue](repeating: 0, count: capacity)
  var blue = [CGGammaValue](repeating: 0, count: capacity)
  var sampleCount: UInt32 = 0
  guard CGGetDisplayTransferByTable(displayID, UInt32(capacity), &red, &green, &blue, &sampleCount) == .success,
        sampleCount > 0
  else { return false }
  let used = Int(sampleCount)
  let scaledRed = red[0 ..< used].map { $0 * scale }
  let scaledGreen = green[0 ..< used].map { $0 * scale }
  let scaledBlue = blue[0 ..< used].map { $0 * scale }
  return CGSetDisplayTransferByTable(displayID, sampleCount, scaledRed, scaledGreen, scaledBlue) == .success
}

/// Whether `id` is in THIS process's online list. Correct only in a process
/// whose snapshot postdates the event being asked about.
func CandelaVDIsOnlineFresh(_ id: CGDirectDisplayID) -> Bool {
  var count: UInt32 = 0
  guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
  return ids.prefix(Int(count)).contains(id)
}

/// Re-executes this binary to get an online answer from a snapshot taken after
/// the destroy. Returns false when the child cannot be run or does not answer,
/// so an unusable check never manufactures a departure it did not witness.
func freshProcessSaysDeparted(_ id: CGDirectDisplayID) -> Bool {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  child.arguments = ["vd", "online", String(id)]
  let pipe = Pipe()
  child.standardOutput = pipe
  do { try child.run() } catch { return false }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  child.waitUntilExit()
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0"
}

/// The one conformance check that must live in the probe: invariant 8 needs a
/// process whose EXIT reverts the preview apply, and only this binary knows
/// its own path. The child runs `modeapply` at preview scope through the real
/// configurator, whose post-commit verification throws on a reassigned id, so
/// "achieved the requested id" is checked by the same machinery the app
/// trusts; the parent then watches the revert land after the child exits.
func conformApplyPreview(
  configurator: CoreGraphicsDisplayConfigurator,
  applyDestructive: Bool,
  limit: CGDirectDisplayID?
) -> PlatformConformance.Check {
  let name = "cgs.apply.preview"
  guard applyDestructive else {
    return .init(name: name, outcome: .skip("requires --apply (reconfigures a display for ~3 seconds)"))
  }
  // Externals first: the built-in is the panel someone is working on, and a
  // preview bounce there is the most disruptive place to run one.
  let candidates = configurator.displays().sorted { !$0.isBuiltIn && $1.isBuiltIn }
  for display in candidates where limit == nil || display.id == limit {
    let modes = configurator.modes(for: display.id)
    // The largest revealed rung, so the bounce is the least visually violent
    // one the panel offers. A display revealing nothing is cgs.reveals'
    // business, not this check's.
    guard let revealed = modes.filter(\.isRevealed)
      .max(by: { $0.logicalWidth * $0.logicalHeight < $1.logicalWidth * $1.logicalHeight }),
          let before = configurator.currentMode(for: display.id)
    else { continue }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--display", String(display.id), "modeapply", String(revealed.ioModeID), "2"]
    let pipe = Pipe()
    child.standardOutput = pipe
    do { try child.run() } catch {
      return .init(name: name, outcome: .fail("could not spawn the child probe: \(error)"))
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    child.waitUntilExit()
    guard child.terminationStatus == 0 else {
      return .init(name: name, outcome: .fail(
        "child apply of id \(revealed.ioModeID) exited \(child.terminationStatus)"))
    }
    // Not end-anchored: the apply lines end with a rate, and a suffix match on
    // the id goes silently false.
    guard output.split(separator: "\n").contains(where: {
      $0.hasPrefix("after:") && $0.contains(" id \(revealed.ioModeID) ")
    }) else {
      return .init(name: name, outcome: .fail(
        "child reported success but its achieved mode is not id \(revealed.ioModeID)"))
    }
    // The preview scope reverts at child exit; give the reconfiguration a
    // bounded window to land rather than reading the first answer.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if configurator.currentMode(for: display.id)?.ioModeID == before.ioModeID {
        return .init(name: name, outcome: .pass(
          "revealed id \(revealed.ioModeID) achieved at preview scope on display \(display.id), then self-reverted to id \(before.ioModeID)"))
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return .init(name: name, outcome: .fail(
      "preview did not revert: display \(display.id) still off id \(before.ioModeID) five seconds after the child exited"))
  }
  return .init(name: name, outcome: .skip("no display offers a revealed mode to apply"))
}

switch arguments.first {
case nil:
  // Usage prints on ANY machine, with no hardware precondition: someone with
  // nothing attached is exactly who needs to read it, and routing a bare
  // invocation into `list` sent them "No DDC-capable external displays found"
  // and exit 1 instead.
  print(usage)
case "list":
  requireDDCDisplays()
  for entry in found {
    // Column 2 is the persistence key: every per-display `defaults write`
    // key is suffixed with it (docs/ADVANCED-SETTINGS.md).
    print("\(entry.display.id)\t\(entry.display.persistenceKey)\t\(entry.display.name)")
  }
case "topology":
  // Every online display with its kind and identity, then the DDC candidate
  // pool as the shipping filter computes it: the rig's oracle for VD3.
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  _ = CGGetOnlineDisplayList(16, &ids, &count)
  let onlineIDs = Array(ids.prefix(Int(count)))
  print("online-count=\(onlineIDs.count)")
  print("main-display-id=\(CGMainDisplayID())")
  for id in onlineIDs where displayFilter == nil || id == displayFilter {
    let identity = DisplayConfigIdentity(
      vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
      serial: CGDisplaySerialNumber(id), isBuiltIn: CGDisplayIsBuiltin(id) != 0
    )
    let virtualVerdict = VirtualDisplayDetection.isVirtual(id).map { $0 ? "1" : "0" } ?? "unknown"
    print("display id=\(id) identity=\(identity.key) built-in=\(CGDisplayIsBuiltin(id) != 0 ? 1 : 0) virtual=\(virtualVerdict) mirrors=\(CGDisplayMirrorsDisplay(id))")
  }
  let pool = DDCCandidatePolicy.candidates(
    online: onlineIDs,
    isBuiltIn: { CGDisplayIsBuiltin($0) != 0 },
    ownedVirtualIDs: [],
    isForeignVirtual: VirtualDisplayDetection.isVirtual
  )
  print("ddc-pool=\(pool.map(String.init).joined(separator: ","))")

case "vd":
  // Exercises the SHIPPING VirtualDisplayHost without the app: creation,
  // appearance, departure, and (with --hold and an external kill -9) the
  // crash-reclaim behavior. Colour profile counts print around the create so
  // a repeat-run growth is visible immediately (VD11).
  let profilesDir = "/Library/ColorSync/Profiles/Displays"
  func profileCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: profilesDir).count) ?? -1
  }
  // `vd online <id>` exists to be re-executed: a fresh process is the only
  // authority this tool has about whether a display is still there, because its
  // own CoreGraphics snapshot freezes after a destroy (see CandelaVDDestroy).
  if arguments.count >= 3, arguments[1] == "online", let id = UInt32(arguments[2]) {
    print(CandelaVDIsOnlineFresh(id) ? "1" : "0")
    exit(0)
  }
  guard arguments.count >= 2, arguments[1] == "create" else {
    print(usage)
    exit(2)
  }
  // User slots only. The host stands synthesis slots 4 and 5 too, but those
  // are engine-internal (SS6) and standing one by hand would leave a display
  // the app's reconciler does not own.
  guard arguments.count >= 4, let slot = Int(arguments[2]),
        VirtualDisplayIdentity.userSlotRange.contains(slot),
        let width = Int(arguments[3]), arguments.count >= 5, let height = Int(arguments[4])
  else {
    print("usage: vd create <slot 1-3> <width> <height> [--hidpi] [--hold <seconds>]")
    exit(2)
  }
  let hiDPI = arguments.contains("--hidpi")
  var hold: Double = 10
  if let holdIndex = arguments.firstIndex(of: "--hold"), holdIndex + 1 < arguments.count,
     let seconds = Double(arguments[holdIndex + 1]) {
    hold = seconds
  }
  let host = VirtualDisplayHost()
  guard host.isAvailable else {
    print("vd: private class family unavailable on this macOS")
    exit(1)
  }
  print("profiles-before=\(profileCount())")
  let spec = VirtualDisplaySpec(
    name: VirtualDisplayIdentity.defaultName(slot: slot),
    logicalWidth: width, logicalHeight: height, hiDPI: hiDPI, refreshHz: 60
  )
  switch host.create(spec, slot: slot, uuid: UUID(), appearanceTimeout: 10) {
  case let .success(handle):
    print("created id=\(handle.displayID) slot=\(handle.slot) \(handle.spec.logicalWidth)x\(handle.spec.logicalHeight) hiDPI=\(handle.spec.hiDPI ? 1 : 0)")
    print("profiles-after=\(profileCount())")
    print("holding \(hold)s (kill -9 me now to test crash reclaim)")
    try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
    let departed = host.destroy(slot: slot, departureTimeout: 10)
    if departed {
      print("destroyed=1 departed=1")
    } else {
      // Not a retry and not a second chance for the same check: the in-process
      // answer is known to be unable to change, so this asks a process whose
      // snapshot was taken after the destroy. Printing both keeps the verdict
      // honest either way, rather than reporting a display still standing that
      // has already gone.
      let goneForFreshProcess = freshProcessSaysDeparted(handle.displayID)
      print("destroyed=1 departed=\(goneForFreshProcess ? 1 : 0) in-process-wait=timed-out"
        + (goneForFreshProcess
           ? " (confirmed departed by a fresh process; this process cannot observe departures)"
           : " (a fresh process also still sees it: the display really is standing)"))
    }
  case let .failure(failure):
    print("create failed: \(failure)")
    exit(1)
  }

case "modes":
  // Reports the merged list THROUGH CoreGraphicsDisplayConfigurator, so what
  // prints here is exactly what the app's pickers see — revelation included.
  let configurator = CoreGraphicsDisplayConfigurator()
  print(
    "hidden-mode revelation: \(configurator.revealsHiddenModes ? "available" : "UNAVAILABLE")")
  // The probe reads its OWN defaults domain, not the app's, so this is the
  // guard's default rather than whatever the app is running with (#110).
  print("wire-timing guard: \(configurator.guardsWireTiming ? "on" : "OFF")")
  for display in online where displayFilter == nil || display.id == displayFilter {
    let all = configurator.modes(for: display.id)
    let published = all.filter { $0.provenance == .coreGraphics }
    let revealed = all.filter { $0.provenance == .coreGraphicsServices }
    let withheld = configurator.modesWithheldByWireTimingGuard(for: display.id)
    // #95's regression detector. Rows alike in every field the pickers render
    // are rows a person cannot choose between, and the count is only meaningful
    // against real hardware: the duplicates came from CoreGraphics itself, so no
    // fixture can produce them.
    let rendered = all.map {
      "\($0.logicalWidth)x\($0.logicalHeight)|\($0.pixelWidth)x\($0.pixelHeight)|\($0.refreshHz)"
    }
    let duplicateRows = rendered.count - Set(rendered).count
    print(
      "\n\(display.name)  published \(published.count)  revealed \(revealed.count)"
        + (withheld > 0 ? "  withheld-wire-timing \(withheld)" : "")
        + "  indistinguishable-rows \(duplicateRows)")
    if withheld > 0 {
      let parents = CGSModeRevelation.nativeParentRefreshes(
        in: published,
        nativePixelWidth: published.first(where: \.isNative)?.pixelWidth ?? 0,
        nativePixelHeight: published.first(where: \.isNative)?.pixelHeight ?? 0)
      print(
        "  native-width timings: "
          + parents.sorted(by: >).map { String(format: "%g", $0) }.joined(separator: ", ")
          + " Hz — revealed modes at any other rate are withheld")
    }
    for mode in revealed.sorted(by: {
      ($0.logicalWidth, $0.refreshHz) > ($1.logicalWidth, $1.refreshHz)
    }) {
      print(
        "  \(mode.logicalWidth)x\(mode.logicalHeight)"
          + "  fb \(mode.pixelWidth)x\(mode.pixelHeight)"
          + "  @\(String(format: "%g", mode.refreshHz))Hz"
          + "  id \(mode.ioModeID)")
    }
  }
case "synthstops":
  // The synthesized-size ladder exactly as the launch reapply computes it:
  // raw configurator rows, native from the native flag, and the stored-stop
  // resolution beside it. Built for the #186 pass, where the pane and the
  // launch path disagreed and nothing could print the launch path's view.
  guard let target = displayFilter else {
    print("synthstops requires --display <id>")
    exit(2)
  }
  let configurator = CoreGraphicsDisplayConfigurator()
  let rows = configurator.modes(for: target)
  print("rows: \(rows.count)")
  let native = rows.first(where: \.isNative)
  print("native: \(native.map { "\($0.logicalWidth)x\($0.logicalHeight) fb \($0.pixelWidth)x\($0.pixelHeight) @\($0.refreshHz)Hz" } ?? "NIL")")
  if let native {
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: native.logicalWidth, nativeLogicalHeight: native.logicalHeight,
      existingRows: rows,
      ceilingPixelWidth: VirtualDisplayIdentity.maxPixels.wide,
      ceilingPixelHeight: VirtualDisplayIdentity.maxPixels.high)
    for stop in stops {
      print("stop: \(stop.logicalWidth)x\(stop.logicalHeight) @\(stop.percentOfNative)%")
    }
    if stops.isEmpty { print("stop: NONE") }
  }
case "curated":
  // What the DEFAULT picker actually shows, after DisplayModeCatalog curation.
  //
  // Geometry is built and passed, so this mirrors the app's DENSITY floor
  // rather than the fraction-of-native fallback. The two disagree on real
  // panels (that is what the density floor is for), and without this the app
  // and the probe would print different curated lists for the same display,
  // which a hardware pass has no way to read as anything but a bug.
  //
  // The physical size comes off the discovery pass already made at startup, so
  // nothing extra is read and nothing new goes on the DDC wire.
  let cur = CoreGraphicsDisplayConfigurator()
  for display in online where displayFilter == nil || display.id == displayFilter {
    let all = cur.modes(for: display.id)
    guard let native = all.first(where: { $0.isNative }) else { continue }
    let facts = found.first { $0.display.id == display.id }?.facts
    let geometry = PanelGeometry(
      nativePixelWidth: native.pixelWidth, nativePixelHeight: native.pixelHeight,
      physicalWidthCm: facts?.physicalWidthCm,
      physicalHeightCm: facts?.physicalHeightCm,
      isVirtual: VirtualDisplayDetection.isVirtual(display.id) == true)
    let rows = DisplayModeCatalog.curated(
      all, nativePixelWidth: native.pixelWidth, nativePixelHeight: native.pixelHeight,
      geometry: geometry)
    let revealedRows = rows.filter { $0.mode.provenance == .coreGraphicsServices }
    print("\n\(display.name): \(all.count) modes -> \(rows.count) rows, \(revealedRows.count) of them revealed")
    if geometry.physicalWidthCm == nil || geometry.physicalHeightCm == nil {
      print("  no declared physical size (\(geometry.isVirtual ? "virtual display" : "not reported")): fraction-of-native floor in effect, not the density floor")
    }
    for row in rows {
      let m = row.mode
      print("  \(m.logicalWidth)x\(m.logicalHeight) fb \(m.pixelWidth)x\(m.pixelHeight) @\(Int(m.refreshHz))Hz id \(m.ioModeID) \(m.provenance) hidpi=\(m.isHiDPI)")
    }
    let groups = Dictionary(grouping: all) { "\($0.logicalWidth)x\($0.logicalHeight)" }
    for (size, group) in groups.sorted(by: { $0.key < $1.key }) {
      let cgOnly = group.filter { $0.provenance == .coreGraphics }
      let cgsOnly = group.filter { $0.provenance == .coreGraphicsServices }
      if !cgOnly.isEmpty && !cgsOnly.isEmpty {
        print("  COLLISION \(size): cg=\(cgOnly.count) cgs=\(cgsOnly.count)")
      }
    }
  }
case "modeapply":
  // Applies one mode BY ID at preview scope, through the real configurator, so
  // the revealed apply path and its post-commit verification are both exercised.
  // Preview scope self-reverts when this process exits.
  guard arguments.count >= 2, let wanted = Int32(arguments[1]) else {
    print("usage: candela-probe --display <id> modeapply <ioModeID> [holdSeconds=5]")
    exit(2)
  }
  let holdSeconds = arguments.count >= 3 ? UInt32(arguments[2]) ?? 5 : 5
  // Third arg picks the scope. Session scope OUTLIVES this process, so the
  // caller is responsible for putting the display back.
  let applyScope: DisplayConfigScope =
    (arguments.count >= 4 && arguments[3] == "session") ? .session : .preview
  guard let target = displayFilter else {
    print("modeapply requires --display <id>")
    exit(2)
  }
  let configurator = CoreGraphicsDisplayConfigurator()
  guard let mode = configurator.modes(for: target).first(where: { $0.ioModeID == wanted }) else {
    print("no mode with id \(wanted) on display \(target)")
    exit(3)
  }
  let before = configurator.currentMode(for: target)
  print("before: \(before.map { "\($0.logicalWidth)x\($0.logicalHeight) fb \($0.pixelWidth)x\($0.pixelHeight) id \($0.ioModeID) \(String(format: "%g", $0.refreshHz)) Hz" } ?? "unknown")")
  print("applying: \(mode.logicalWidth)x\(mode.logicalHeight) fb \(mode.pixelWidth)x\(mode.pixelHeight) id \(mode.ioModeID) provenance \(mode.provenance) \(String(format: "%g", mode.refreshHz)) Hz")
  do {
    try configurator.apply(mode, to: target, scope: applyScope)
    let after = configurator.currentMode(for: target)
    print("after:  \(after.map { "\($0.logicalWidth)x\($0.logicalHeight) fb \($0.pixelWidth)x\($0.pixelHeight) id \($0.ioModeID) \(String(format: "%g", $0.refreshHz)) Hz" } ?? "unknown")")
    print("scope: \(applyScope); holding \(holdSeconds)s...")
    sleep(holdSeconds)
    print("exiting: preview scope reverts now.")
  } catch {
    print("apply FAILED: \(error)")
    exit(4)
  }
case "identity":
  // Same inputs the app's live checkup passes. No I2C transaction is involved,
  // so a write-only panel answers exactly like one that reads.
  guard let target = displayFilter else {
    print("identity requires --display <id>")
    exit(2)
  }
  let identityConfigurator = CoreGraphicsDisplayConfigurator()
  let identityNative = identityConfigurator.nativePixels(for: target).map { ($0.width, $0.height) } ?? (0, 0)
  // The key the app files runs under, so the probe and a stored report name the
  // same display. DisplayConfigIdentity's key is a separate namespace for mode
  // state and would name a directory nothing writes.
  let identityKey: String
  if CGDisplayIsBuiltin(target) != 0 {
    identityKey = "builtIn"
  } else if let discovered = DisplayDiscovery.discover().first(where: { $0.display.id == target }) {
    identityKey = discovered.display.persistenceKey
  } else {
    print("display \(target) has no DDC service, so the app files no checkup runs under it")
    exit(5)
  }
  guard let identity = CheckupIdentityFacts.read(
    displayID: target, identityKey: identityKey, vendorID: CGDisplayVendorNumber(target),
    modelID: CGDisplayModelNumber(target), nativePixels: identityNative,
    maxRefreshHz: DisplayModeCatalog.distinctRates(identityConfigurator.modes(for: target)).max())
  else {
    // The display exposed no parsed EDID record. Distinct from a checkup
    // failure, and reported as such.
    print("no DisplayAttributes record for display \(target)")
    exit(3)
  }
  let identityEncoder = JSONEncoder()
  identityEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  guard let identityJSON = try? identityEncoder.encode(identity) else {
    print("the identity record for display \(target) could not be encoded")
    exit(4)
  }
  print(String(decoding: identityJSON, as: UTF8.self))
case "refreshsweep":
  // Applies every native-size rate at preview scope and grades on what
  // currentMode reports afterwards. This RECONFIGURES the display.
  guard let target = displayFilter else {
    print("refreshsweep requires --display <id>")
    exit(2)
  }
  let sweepRunner = CheckupLiveModeRunner(
    configurator: CoreGraphicsDisplayConfigurator(), displayID: target)
  let sweepClaims = await sweepRunner.runRefreshSweep()
  for claim in sweepClaims {
    print("\(claim.id): \(claim.verdict.kind): \(claim.verdict.text)")
  }
  if sweepClaims.isEmpty {
    print("no CoreGraphics modes at the native size on display \(target): nothing was swept")
  }
  // Preview scope reverts on exit, but restore explicitly and read the achieved
  // state back: a restore that reports success is not a restore that happened.
  let sweepRestored = await sweepRunner.restore()
  print("restore: \(sweepRestored ? "achieved, the display is back on its pre-run mode" : "NOT ACHIEVED, the display is not on its pre-run mode")")
  // A sweep that measured nothing is not a pass, and neither is one that left
  // the display somewhere else.
  let sweepAllObserved = !sweepClaims.isEmpty && sweepClaims.allSatisfy {
    if case .observed = $0.verdict { return true }
    return false
  }
  exit(sweepAllObserved && sweepRestored ? 0 : 4)
case "checkup":
  guard arguments.count == 3, arguments[1] == "validate" else {
    print("usage: candela-probe checkup validate <file>")
    exit(2)
  }
  let reportURL = URL(fileURLWithPath: arguments[2])
  // The directory is irrelevant to `load`, which reads the URL it is handed;
  // this is the same decoder and the same hash check the app's history uses.
  let reportEnvelope: CheckupReportEnvelope
  do {
    reportEnvelope = try CheckupStore(directory: URL(fileURLWithPath: "/")).load(url: reportURL)
  } catch {
    print("could not read \(reportURL.path) as a checkup report: \(error.localizedDescription)")
    exit(3)
  }
  if reportEnvelope.validate() {
    print("valid")
    print(reportEnvelope.report.summary.line)
  } else {
    print("INVALID: hash does not match the body")
    print(reportEnvelope.report.summary.line)
    exit(4)
  }
case "conform":
  // #82: does the platform still behave as this app assumes? Non-destructive
  // by default; --apply adds the checks that reconfigure hardware (a preview
  // mode apply, the rotation no-op calls, a same-value brightness write).
  // The exit code is the interface: 0 only when something passed and nothing
  // failed, so a run that demonstrated nothing exits non-zero.
  let applyDestructive = arguments.contains("--apply")
  let conformConfigurator = CoreGraphicsDisplayConfigurator()
  var report = await PlatformConformance.run(
    configurator: conformConfigurator,
    ddcPanels: found.map { (name: $0.display.name, writer: $0.writer) },
    applyDestructive: applyDestructive,
    limitTo: displayFilter
  )
  report.checks.append(conformApplyPreview(
    configurator: conformConfigurator, applyDestructive: applyDestructive, limit: displayFilter
  ))
  for line in report.lines() { print(line) }
  exit(report.exitCode)
case "regress":
  // The other half of `conform`: that command asks whether the platform still
  // behaves as this app assumes, this one asks whether the app still behaves
  // as its own rulings say it must, against the build that is running. Same
  // report type, same exit-code rule, separate baselines.
  switch Regress.parseOptions(Array(arguments.dropFirst())) {
  case let .failure(usage):
    print(usage.message)
    exit(2)
  case let .success(options):
    let regressDisplays = online.map { display in
      Regress.Display(
        id: display.id,
        name: display.name,
        title: display.title,
        persistenceKey: found.first { $0.display.id == display.id }?.display.persistenceKey,
        isBuiltIn: CGDisplayIsBuiltin(display.id) != 0
      )
    }
    let report = Regress.run(options: options, displays: regressDisplays)
    for line in report.lines(label: "regress") { print(line) }
    // Written after printing and before the exit code is consulted: a record
    // that could not be written is a hard failure with its reason, never a run
    // that reports its verdict and drops it.
    switch Regress.writeRecords(report: report, options: options, timestamp: Date()) {
    case let .failure(usage):
      // On stdout as well as stderr. Stdout is where a run says where its
      // record landed, so it is where it has to say when none did: a reader
      // watching that stream would otherwise see the report and no line about
      // the record at all, which is the shape of a run that was never asked
      // for one.
      print("record NOT written: \(usage.message)")
      FileHandle.standardError.write(Data("\(usage.message)\n".utf8))
      exit(2)
    case let .success(paths):
      for path in paths {
        print(options.commit == nil ? "wrote \(path) (no --commit, so the record names no build)" : "wrote \(path)")
      }
    }
    exit(report.exitCode)
  }
case "caps":
  requireDDCDisplays()
  for entry in found {
    guard let capabilities = await entry.writer.readCapabilityString() else {
      // Expected on the MAG 341C and every other write-only panel.
      print("\(entry.display.name): capabilities read FAILED -> unknown (volume slider stays enabled)")
      continue
    }
    print("\(entry.display.name): \(capabilities)")
    print("  VCP 0x62 (volume): \(CapabilityString.support(forVCP: VCP.audioSpeakerVolume, in: capabilities))")
  }
case "get":
  await ddcGet(code: VCP.brightness, label: "brightness")
case "set":
  requireDDCDisplays()
  guard arguments.count == 2, let value = UInt16(arguments[1]) else {
    print("usage: candela-probe set <0-100>")
    exit(2)
  }
  for entry in found {
    let ok = await entry.writer.write(command: VCP.brightness, value: value)
    print("\(entry.display.name): write \(value) -> \(ok ? "ok" : "FAILED")")
  }
case "ramp":
  // Sweeps VCP 0x10 in-process with Task.sleep pacing — no UI, no coalescer.
  // Isolates the monitor's DDC apply-path latency from everything app-side.
  requireDDCDisplays()
  guard arguments.count == 5,
        let from = Int(arguments[1]), let to = Int(arguments[2]),
        let step = Int(arguments[3]), step > 0,
        let intervalMs = Int(arguments[4]), intervalMs >= 0,
        (0 ... 100).contains(from), (0 ... 100).contains(to)
  else {
    print("usage: candela-probe ramp <from 0-100> <to 0-100> <step >0> <intervalMs>")
    exit(2)
  }
  for entry in found {
    print("\(entry.display.name): ramp \(from) -> \(to) step \(step) every \(intervalMs) ms")
    let start = ContinuousClock.now
    let direction = from <= to ? step : -step
    var value = from
    while true {
      let ok = await entry.writer.write(command: VCP.brightness, value: UInt16(value))
      let elapsed = start.duration(to: .now)
      print("  +\(elapsed) write \(value) -> \(ok ? "ok" : "FAILED")")
      if value == to { break }
      try? await Task.sleep(for: .milliseconds(intervalMs))
      value = from <= to ? min(value + direction, to) : max(value + direction, to)
    }
    print("\(entry.display.name): ramp done in \(start.duration(to: .now))")
  }
case "native":
  // DisplayServices (private, dlsym'd). Succeeds on Apple displays and — the
  // point of M3 — on an external display while macOS HDR owns its brightness.
  requireOnlineDisplays()
  switch arguments.count > 1 ? arguments[1] : nil {
  case "get":
    for display in online {
      let value = DisplayServices.getBrightness(for: display.id)
      print("\(display.name): \(value.map { "\($0)" } ?? "unavailable")")
    }
  case "set":
    guard arguments.count == 3, let value = Float(arguments[2]), (0 ... 1).contains(value) else {
      print("usage: candela-probe native set <0-1>")
      exit(2)
    }
    for display in online {
      let ok = DisplayServices.setBrightness(value, for: display.id)
      let readBack = DisplayServices.getBrightness(for: display.id)
      print("\(display.name): set \(value) -> \(ok ? "ok" : "FAILED"), read-back \(readBack.map { "\($0)" } ?? "unavailable")")
    }
  default:
    print("usage: candela-probe native [get|set <0-1>]")
    exit(2)
  }
case "hdr":
  requireOnlineDisplays()
  let service = MonitorPanelService()
  switch arguments.count > 1 ? arguments[1] : nil {
  case "status":
    for display in online {
      let supports = await service.supportsHDR(displayID: display.id)
      let enabled = await service.isHDREnabled(displayID: display.id)
      print("\(display.name): hasHDRModes=\(supports) preferHDRModes=\(enabled)")
    }
  case let sub where sub == "on" || sub == "off":
    let enabled = sub == "on"
    for display in online {
      guard await service.supportsHDR(displayID: display.id) else {
        print("\(display.name): skipped (hasHDRModes=false)")
        continue
      }
      let issued = await service.setHDR(displayID: display.id, enabled: enabled)
      print("\(display.name): setHDR(\(enabled)) -> \(issued ? "issued" : "FAILED (lock busy or unavailable)")")
      guard issued else { continue }
      // `setHDR` invalidates the cache rather than seeding it with the request
      // (#65), so a poll now reads the panel. The per-tick clear stays: what
      // `isHDREnabled` MEASURES is still cached for 2 s, which would otherwise
      // pin this loop to its first reading for the first two of its five
      // seconds.
      let start = ContinuousClock.now
      var settled = false
      while start.duration(to: .now) < .seconds(5) {
        try? await Task.sleep(for: .milliseconds(100))
        await service.displaysReconfigured()
        if await service.isHDREnabled(displayID: display.id) == enabled {
          print("  settled after \(start.duration(to: .now))")
          settled = true
          break
        }
      }
      if !settled {
        print("  NOT settled after 5 s (preferHDRModes still \(await service.isHDREnabled(displayID: display.id)))")
      }
    }
  default:
    print("usage: candela-probe hdr [status|on|off]")
    exit(2)
  }
case "gamma":
  // Public Quartz gamma — the software-dimming backend. NOTE: Quartz restores
  // this process's gamma the instant the process exits, so a one-shot set is
  // just a flash; we hold, then reset explicitly.
  requireOnlineDisplays()
  guard arguments.count >= 2 else {
    print("usage: candela-probe gamma <0-1> [holdSeconds=15] | gamma reset")
    exit(2)
  }
  if arguments[1] == "reset" {
    CGDisplayRestoreColorSyncSettings()
    print("gamma: restored ColorSync settings for all displays")
  } else {
    guard let scale = Float(arguments[1]), (0 ... 1).contains(scale) else {
      print("usage: candela-probe gamma <0-1> [holdSeconds=15] | gamma reset")
      exit(2)
    }
    let holdSeconds = arguments.count > 2 ? Double(arguments[2]) ?? 15 : 15
    print("gamma: scale \(scale), holding \(holdSeconds) s.")
    print("gamma: CAVEAT. Gamma set by this process is restored the moment the process exits;")
    print("       observe the display during the hold, not after.")
    for display in online {
      print("\(display.name): scale \(scale) -> \(applyGammaScale(scale, to: display.id) ? "ok" : "FAILED")")
    }
    try? await Task.sleep(for: .seconds(holdSeconds))
    CGDisplayRestoreColorSyncSettings()
    print("gamma: hold over, ColorSync settings restored")
  }
case "watch":
  // Echo-tolerance calibration: how fast, and in what increments, does the OS
  // move native brightness when something else (Control Center, media keys,
  // ambient light) drives it?
  requireOnlineDisplays()
  let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 10 : 10
  var last: [CGDirectDisplayID: Float] = [:]
  let start = ContinuousClock.now
  for display in online {
    let value = DisplayServices.getBrightness(for: display.id)
    print("+0 \(display.name): \(value.map { "\($0)" } ?? "unavailable")")
    if let value { last[display.id] = value }
  }
  while start.duration(to: .now) < .seconds(seconds) {
    try? await Task.sleep(for: .milliseconds(100))
    for display in online {
      guard let value = DisplayServices.getBrightness(for: display.id) else { continue }
      guard let previous = last[display.id] else {
        print("+\(start.duration(to: .now)) \(display.name): appeared \(value)")
        last[display.id] = value
        continue
      }
      if value != previous {
        print("+\(start.duration(to: .now)) \(display.name): \(previous) -> \(value) (delta \(value - previous))")
        last[display.id] = value
      }
    }
  }
  print("watch: done after \(start.duration(to: .now))")
case "volume", "contrast":
  let code = arguments[0] == "volume" ? VCP.audioSpeakerVolume : VCP.contrast
  switch arguments.count > 1 ? arguments[1] : nil {
  case "get":
    await ddcGet(code: code, label: arguments[0])
  case "set":
    guard arguments.count == 3, let value = UInt16(arguments[2]), value <= 100 else {
      print("usage: candela-probe \(arguments[0]) set <0-100>")
      exit(2)
    }
    await ddcSet(code: code, value: value, label: arguments[0])
  default:
    print("usage: candela-probe \(arguments[0]) [get|set <0-100>]")
    exit(2)
  }
case "mute":
  guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
    print("usage: candela-probe mute on|off")
    exit(2)
  }
  // VCP spec (and fork) wire values: 1 = mute, 2 = unmute.
  await ddcSet(code: VCP.audioMuteScreenBlank, value: arguments[1] == "on" ? 1 : 2, label: "mute")
case "vcp":
  // Fully generic prober — the escape hatch for remap experiments.
  switch arguments.count > 1 ? arguments[1] : nil {
  case "get":
    guard arguments.count == 3, let code = parseHexByte(arguments[2]) else {
      print("usage: candela-probe vcp get <hex code>")
      exit(2)
    }
    await ddcGet(code: code, label: String(format: "0x%02x", code))
  case "set":
    guard arguments.count == 4, let code = parseHexByte(arguments[2]), let value = UInt16(arguments[3]) else {
      print("usage: candela-probe vcp set <hex code> <0-65535>")
      exit(2)
    }
    await ddcSet(code: code, value: value, label: String(format: "0x%02x", code))
  default:
    print("usage: candela-probe vcp [get <hex>|set <hex> <value>]")
    exit(2)
  }
case "audio":
  guard arguments.count == 2, arguments[1] == "devices" else {
    print("usage: candela-probe audio devices")
    exit(2)
  }
  let provider = CoreAudioDeviceProvider()
  if let device = provider.defaultOutputDevice() {
    print("default output: \(device.name) [\(device.id)] canSetOwnVolume=\(device.canSetOwnVolume)")
    // The real tap rule checks ddcDisplaysExist FIRST, so with no DDC-capable
    // display the keys stay with macOS whatever the device reports.
    if found.isEmpty {
      print("volume keys stay with macOS regardless: no DDC-capable displays\(filterNote)")
    } else {
      print("volume keys would be \(device.canSetOwnVolume ? "RELEASED to macOS" : "WATCHED by Candela") outside name-matching mode")
    }
  } else {
    print("no default output device")
  }
default:
  print(usage)
  exit(2)
}
