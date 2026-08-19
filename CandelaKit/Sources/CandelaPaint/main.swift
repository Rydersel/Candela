import AppKit
import CandelaKit

// Draws one opaque window of an EXACTLY known luminance at an exactly known
// position, so a fit can be asked to recover a value that is already known.
//
// Why this exists: the fitting harness has only ever run on data whose true
// answer nobody knows, so a wrong answer and a right one look alike. A run
// where the answer is designed turns that into a check. It already earned
// itself once in reverse: a smoke run reported app priors of 0.857 and 0.714
// that were purely the optimiser's starting values.
//
// `kCGWindowOwnerName` comes from the process name, so copying this binary to
// several names is how one harness produces several distinct "apps".
//
// **Every geometry this prints is READ BACK, never the value that was asked
// for.** The harness's whole job is ground truth and its only assertion is on
// recovered luminance, so a window that landed somewhere other than where it
// was told to would leave an unpainted strip and no check anywhere would
// notice: the ground-truth ruling requires the tiles to cover the display
// completely, and a gap puts the wallpaper term (the input already known to be
// unreliable) back into a fit that exists to be free of it.

struct Options {
  var displayID: CGDirectDisplayID = CGMainDisplayID()
  var rect = CGRect(x: 0, y: 0, width: 400, height: 300)
  var luminance = 0.5
  var hold = 60.0
}

func usage() -> Never {
  print("""
    candela-paint: draw a window of known luminance for ground-truth fitting

      --display <id>          display to draw on
      --rect x,y,w,h          display-local, top-left origin; w and h must be positive
      --luminance <0...1>     RELATIVE LUMINANCE, not an sRGB value
      --hold <seconds>        must be positive

    Exits non-zero when the achieved window frame does not match the requested
    rect, rather than reporting the geometry it asked for.
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
    options.displayID = id
  case "--rect":
    let parts = value().split(separator: ",").compactMap { Double($0) }
    // Width and height are checked here, not left to AppKit. A zero or
    // negative tile composites nothing while every line this tool prints still
    // says it painted, and the harness's only assertion is on recovered
    // luminance, so the run would report a coverage it never had.
    guard parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 else {
      usage()
    }
    options.rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
  case "--luminance":
    guard let value = Double(value()), value >= 0, value <= 1 else { usage() }
    options.luminance = value
  case "--hold":
    // Same reason: `--hold 0` terminated before anything was composited, and
    // printed that it was painting on the way out.
    guard let value = Double(value()), value.isFinite, value > 0 else { usage() }
    options.hold = value
  default: usage()
  }
}

/// Inverse sRGB EOTF. The measurement linearizes before weighting, and a grey
/// has R = G = B, so Rec. 709 collapses to the linear value itself: filling
/// with this encoded grey produces exactly the requested relative luminance.
func encodedGrey(forLuminance luminance: Double) -> Double {
  luminance <= 0.0031308
    ? luminance * 12.92
    : 1.055 * pow(luminance, 1.0 / 2.4) - 0.055
}

/// Display-local top-left to Cocoa's global bottom-left origin, and back.
///
/// Kept as a pair so the achieved frame is compared in the space the caller
/// asked in, rather than in the one AppKit answers in.
func globalFrame(forDisplayLocal rect: CGRect, on screen: NSScreen) -> CGRect {
  CGRect(
    x: screen.frame.minX + rect.origin.x,
    y: screen.frame.maxY - rect.origin.y - rect.height,
    width: rect.width, height: rect.height)
}

func displayLocalRect(forGlobal frame: CGRect, on screen: NSScreen) -> CGRect {
  CGRect(
    x: frame.minX - screen.frame.minX,
    y: screen.frame.maxY - frame.maxY,
    width: frame.width, height: frame.height)
}

func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
  NSScreen.screens.first {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      == displayID
  }
}

/// A window AppKit is not allowed to move.
///
/// `constrainFrameRect` keeps an ordinary window clear of the menu bar, and on
/// the built-in panel it measurably does: a tile asked for at 0,0 300x200 came
/// back at 0,38 [MEASURED 2026-08-18], leaving a full-width 38-point strip of
/// wallpaper the harness would have captured as content it did not paint. The
/// ground-truth ruling requires the tiles to cover the display COMPLETELY, so
/// the placement has to win over the constraint.
///
/// Raising the window level is the other way to escape it and is not available
/// here: see the `.normal` note below.
final class UnconstrainedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

guard let requestedScreen = screen(for: options.displayID) else {
  FileHandle.standardError.write(Data("no NSScreen for display \(options.displayID)\n".utf8))
  exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let frame = globalFrame(forDisplayLocal: options.rect, on: requestedScreen)

// **`contentRect: .zero` and then `setFrame`, deliberately.**
//
// The initialiser's `contentRect` is interpreted relative to the `screen:`
// argument, so handing it a GLOBAL frame together with a screen adds that
// screen's origin a second time. MEASURED 2026-08-18 by removing the
// `setFrame` and passing `frame` to the initialiser instead: a tile asked for
// at display-local 100,300 on the MAG landed at 3340,436, off the far edge of
// the tile row it was supposed to fill.
//
// An earlier version passed `frame` to both, where the `setFrame` corrected the
// initialiser and looked like a redundant line one tidy-up would remove.
// Starting from zero means the only geometry the window ever receives is the
// global one, and the call that applies it cannot be mistaken for duplication.
//
// A borderless window's frame and content rect are the same rectangle, so
// nothing here has to account for a title bar.
let window = UnconstrainedWindow(
  contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false,
  screen: requestedScreen)
let grey = encodedGrey(forLuminance: options.luminance)
// Calibrated sRGB, matching the colour space the capture pins, so the value
// that arrives is the value asked for rather than whatever the panel profile
// would have made of it.
window.backgroundColor = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
window.isOpaque = true
window.hasShadow = false
// `.normal`, and NOT a level above the menu bar, which is the obvious way to
// make a tile that nothing can cover. A window's level becomes its
// `kCGWindowLayer`, and `ExposureModel.includedLayers` is `0...25`: a level
// above the menu bar puts the tile OUTSIDE that range, where the model drops
// its contribution outright (the coverage escape hatch admits low layers only).
// The fit could then never recover the prior this tool exists to plant.
window.level = .normal
window.ignoresMouseEvents = true
window.setFrame(frame, display: true)
window.orderFrontRegardless()

// Let AppKit and the window server settle before reading. `constrainFrameRect`
// and any display re-fit happen on the way through, and a frame read in the
// same turn as the order-front can still be the one that was asked for.
RunLoop.current.run(until: Date().addingTimeInterval(0.25))

let achievedScreen = screen(for: options.displayID) ?? requestedScreen
let achieved = displayLocalRect(forGlobal: window.frame, on: achievedScreen)

func format(_ rect: CGRect) -> String {
  String(
    format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

print(
  "painting luminance \(options.luminance) (sRGB \(String(format: "%.4f", grey))) "
    + "on display \(options.displayID)")
print("  requested \(format(options.rect))")
print("  achieved  \(format(achieved))")
fflush(stdout)

// Half a point, which is finer than any constraining AppKit does and coarser
// than backing-store alignment on a 2x screen.
let tolerance = 0.5
let onRequestedDisplay =
  (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
  .uint32Value == options.displayID
guard onRequestedDisplay,
  abs(achieved.origin.x - options.rect.origin.x) <= tolerance,
  abs(achieved.origin.y - options.rect.origin.y) <= tolerance,
  abs(achieved.width - options.rect.width) <= tolerance,
  abs(achieved.height - options.rect.height) <= tolerance
else {
  // Loud and fatal. A tile that is up but in the wrong place is worse than one
  // that never appeared: the harness would capture it, the gap it left would
  // show wallpaper, and the fit would absorb that into the app priors it is
  // being asked to recover.
  FileHandle.standardError.write(
    Data(
      ("FRAME MISMATCH on display \(options.displayID): requested \(format(options.rect)), "
        + "achieved \(format(achieved))"
        + (onRequestedDisplay ? "" : " on a DIFFERENT display") + ".\n").utf8))
  exit(1)
}

Timer.scheduledTimer(withTimeInterval: options.hold, repeats: false) { _ in
  // The timer fires on the main run loop, so the isolation is real; Swift 6
  // cannot see that through the nonisolated closure type.
  MainActor.assumeIsolated { application.terminate(nil) }
}
application.run()
