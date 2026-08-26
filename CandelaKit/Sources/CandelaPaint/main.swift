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

/// What the window is filled with.
///
/// The two arms are not interchangeable. `luminance` is the ground-truth
/// fitting input and goes through the inverse sRGB EOTF; `srgb` carries the
/// dead-pixel protocol's field values, which are already the encoded numbers
/// the panel is meant to receive, so no transfer function is applied to them.
///
/// `checkup` is rendered by the engine, so the tool draws exactly the image the
/// app puts on glass rather than a second reading of the protocol.
enum Field {
  case luminance(Double)
  case srgb(red: Int, green: Int, blue: Int, patternName: String?)
  case checkup(CheckupFieldKind)
}

enum LevelChoice: String {
  case normal
  case shielding
}

/// One planted defect: a filled rect drawn over the field.
///
/// DEVICE PIXELS, display-local, top-left origin. A stuck pixel is a device
/// pixel, and the same rect written in points covers a different count of them
/// per panel scale, which is the one thing a sensitivity control cannot afford
/// to be vague about.
struct Defect {
  var pixelRect: CGRect
  var red: Int
  var green: Int
  var blue: Int
}

/// A defect resolved into the content view's coordinate space.
struct PlacedDefect {
  var viewRect: NSRect
  var color: NSColor
}

/// The protocol's five fields, as encoded sRGB.
let patterns: [String: (red: Int, green: Int, blue: Int)] = [
  "black": (0, 0, 0), "red": (255, 0, 0), "green": (0, 255, 0),
  "blue": (0, 0, 255), "white": (255, 255, 255),
]

/// The protocol's hard cap on one static field at shielding level. A full-field
/// white that nothing can cover and nothing dims is the worst case this tool can
/// put on an OLED, so the hold is bounded rather than trusted to the caller.
let shieldingHoldCap = 60.0

/// The tile size a run gets when it names neither `--rect` nor `--fullscreen`.
let defaultRect = CGRect(x: 0, y: 0, width: 400, height: 300)

struct Options {
  var displayID: CGDirectDisplayID = CGMainDisplayID()
  /// Nil until resolution: `--fullscreen` needs the target display's frame,
  /// which does not exist during parsing.
  var rect: CGRect?
  var fullscreen = false
  var field: Field = .luminance(0.5)
  var level: LevelChoice = .normal
  var hold = 60.0
  var defects: [Defect] = []
  /// Only meaningful with `--field`, and checked to be so before anything is drawn.
  var plant: CheckupPlant?
}

func usage() -> Never {
  print("""
    candela-paint: draw a window of known luminance, or a known flat field

      --display <id>          display to draw on
      --rect x,y,w,h          display-local, top-left origin; w and h must be positive
      --fullscreen            cover the whole display; not combinable with --rect
      --luminance <0...1>     RELATIVE LUMINANCE, not an sRGB value
      --color R,G,B           encoded sRGB, integers 0...255
      --pattern <name>        black, red, green, blue or white; sugar for --color
      --field <kind>          a checkup field drawn by the engine: black, red,
                              green, blue, gray7, gray50, ramp, white or witness
      --plant x,y,size        square plant in DEVICE PIXELS, top-left origin;
                              needs --field, and a field that carries a plant
      --level <name>          normal (default) or shielding; shielding caps --hold
                              at \(Int(shieldingHoldCap))s
      --defect X,Y,W,H,R,G,B  planted defect rect in DEVICE PIXELS, display-local,
                              top-left origin; repeatable
      --hold <seconds>        must be positive

    Exactly one of --luminance, --color, --pattern and --field may be given.

    Exits non-zero when the achieved window frame does not match the requested
    rect, rather than reporting the geometry it asked for.
    """)
  exit(2)
}

/// A setup error the usage text cannot explain by itself: two flags that
/// contradict each other, or a defect that would paint nothing.
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

var options = Options()
/// Which field flags were seen, so a contradiction can name them back.
var fieldFlags: [String] = []
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
  case "--fullscreen":
    options.fullscreen = true
  case "--luminance":
    fieldFlags.append(flag)
    guard let value = Double(value()), value >= 0, value <= 1 else { usage() }
    options.field = .luminance(value)
  case "--color":
    fieldFlags.append(flag)
    let parts = value().split(separator: ",").compactMap { Int($0) }
    guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { usage() }
    options.field = .srgb(red: parts[0], green: parts[1], blue: parts[2], patternName: nil)
  case "--pattern":
    fieldFlags.append(flag)
    let name = value()
    guard let pattern = patterns[name] else { usage() }
    options.field = .srgb(
      red: pattern.red, green: pattern.green, blue: pattern.blue, patternName: name)
  case "--field":
    fieldFlags.append(flag)
    guard let kind = CheckupFieldKind(rawValue: value()) else { usage() }
    options.field = .checkup(kind)
  case "--plant":
    let parts = value().split(separator: ",").compactMap { Int($0) }
    // Same guard as --rect and --defect, for the same reason: a zero-sized or
    // off-field plant paints nothing while the summary line still records one.
    guard parts.count == 3, parts[0] >= 0, parts[1] >= 0, parts[2] > 0 else { usage() }
    options.plant = CheckupPlant(x: parts[0], y: parts[1], size: parts[2])
  case "--level":
    guard let choice = LevelChoice(rawValue: value()) else { usage() }
    options.level = choice
  case "--defect":
    let parts = value().split(separator: ",").compactMap { Double($0) }
    // Width and height checked for the same reason `--rect` checks them, and the
    // channels checked because a defect the field's own colour cannot be
    // distinguished from is a control that always reads "nothing visible".
    guard parts.count == 7, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0,
      parts[4...6].allSatisfy({ $0 >= 0 && $0 <= 255 && $0 == $0.rounded() })
    else { usage() }
    options.defects.append(
      Defect(
        pixelRect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
        red: Int(parts[4]), green: Int(parts[5]), blue: Int(parts[6])))
  case "--hold":
    // Same reason: `--hold 0` terminated before anything was composited, and
    // printed that it was painting on the way out.
    guard let value = Double(value()), value.isFinite, value > 0 else { usage() }
    options.hold = value
  default: usage()
  }
}

if fieldFlags.count > 1 {
  // Loud, not last-one-wins. Both spellings would be in the run log and only
  // one of them would be on the glass.
  fail(
    "exactly one of --luminance, --color, --pattern and --field may be given; got "
      + fieldFlags.joined(separator: " "))
}
var checkupKind: CheckupFieldKind?
if case .checkup(let kind) = options.field { checkupKind = kind }
if options.plant != nil, checkupKind == nil {
  fail("--plant needs --field: nothing else this tool draws carries a plant")
}
if let checkupKind, options.plant != nil, !checkupKind.carriesPlant {
  fail("the \(checkupKind.rawValue) field carries no plant, so --plant would draw nothing")
}
if checkupKind != nil, !options.defects.isEmpty {
  fail("--field and --defect contradict each other: the field image covers the whole window, so a defect rect would be painted over")
}
if options.fullscreen, options.rect != nil {
  fail("--fullscreen and --rect contradict each other; give one of them")
}
if options.level == .shielding, options.hold > shieldingHoldCap {
  print("hold clamped to \(shieldingHoldCap)s: the cap on a static shielding-level field")
  options.hold = shieldingHoldCap
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

func format(_ rect: CGRect) -> String {
  String(
    format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
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

/// Paints the field and any planted defects over it.
///
/// Flipped, so a defect's display-local top-left rect reaches the view by a
/// translation alone. The vertical flip is where an off-by-one lands, and a
/// defect one row out of place is still a defect the eye finds, so the mistake
/// would survive the human check unnoticed.
final class FieldView: NSView {
  var fieldColor: NSColor = .black
  var defects: [PlacedDefect] = []

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    fieldColor.setFill()
    bounds.fill()
    for defect in defects {
      defect.color.setFill()
      defect.viewRect.fill()
    }
  }
}

/// Interpolation off: a plant is a few device pixels square and a smoothed edge
/// hides it. Unflipped, so the plant's y is the y `CheckupField` drew it at.
final class CheckupFieldView: NSView {
  var image: CGImage?

  override func draw(_ dirtyRect: NSRect) {
    guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
    context.interpolationQuality = .none
    context.draw(image, in: bounds)
  }
}

guard let requestedScreen = screen(for: options.displayID) else {
  FileHandle.standardError.write(Data("no NSScreen for display \(options.displayID)\n".utf8))
  exit(1)
}

// `--fullscreen` resolves here and not at parse time, because it is the target
// display's frame and no display was known yet.
let requestedRect =
  options.rect
  ?? (options.fullscreen
    ? CGRect(origin: .zero, size: requestedScreen.frame.size)
    : defaultRect)

// Device pixels to points. `backingScaleFactor` is the panel's real
// point-to-pixel ratio; `CGDisplayPixelsWide` reports the CURRENT MODE's
// logical width, which is a different number on every scaled mode.
let pixelScale = requestedScreen.backingScaleFactor

let fieldColor: NSColor
let fieldDescription: String
switch options.field {
case .luminance(let luminance):
  let grey = encodedGrey(forLuminance: luminance)
  // Calibrated sRGB, matching the colour space the capture pins, so the value
  // that arrives is the value asked for rather than whatever the panel profile
  // would have made of it.
  fieldColor = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
  fieldDescription = "luminance \(luminance) (sRGB \(String(format: "%.4f", grey)))"
case .srgb(let red, let green, let blue, let patternName):
  fieldColor = NSColor(
    srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: 1)
  fieldDescription =
    "sRGB \(red),\(green),\(blue)" + (patternName.map { " (pattern \($0))" } ?? "")
case .checkup(let kind):
  // Only visible in the instant before the first draw. Black rather than a guess
  // at the field's fill: a flash of nearly-right reads as the field itself.
  fieldColor = .black
  fieldDescription = "checkup field \(kind.rawValue)"
}

let placedDefects = options.defects.map { defect -> PlacedDefect in
  let local = CGRect(
    x: defect.pixelRect.origin.x / pixelScale, y: defect.pixelRect.origin.y / pixelScale,
    width: defect.pixelRect.width / pixelScale, height: defect.pixelRect.height / pixelScale)
  // A defect off the field paints nothing while the summary line still records
  // one, and the reader answers "no defect visible": the exact response the
  // planted defect exists to tell apart from a clean panel.
  guard local.intersects(requestedRect) else {
    fail(
      "defect \(format(defect.pixelRect)) px (\(format(local)) pt) lands outside the field "
        + "\(format(requestedRect))")
  }
  return PlacedDefect(
    viewRect: local.offsetBy(dx: -requestedRect.origin.x, dy: -requestedRect.origin.y),
    color: NSColor(
      srgbRed: Double(defect.red) / 255, green: Double(defect.green) / 255,
      blue: Double(defect.blue) / 255, alpha: 1))
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let frame = globalFrame(forDisplayLocal: requestedRect, on: requestedScreen)

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
window.backgroundColor = fieldColor
window.isOpaque = true
window.hasShadow = false
switch options.level {
case .normal:
  // `.normal`, and NOT a level above the menu bar, which is the obvious way to
  // make a tile that nothing can cover. A window's level becomes its
  // `kCGWindowLayer`, and `ExposureModel.includedLayers` is `0...25`: a level
  // above the menu bar puts the tile OUTSIDE that range, where the model drops
  // its contribution outright (the coverage escape hatch admits low layers only).
  // The fit could then never recover the prior this tool exists to plant.
  window.level = .normal
case .shielding:
  // For the dead-pixel protocol ONLY, where nothing may cover the field and
  // nobody is fitting it. Same consequence as above, read the other way: a
  // shielding-level window sits outside `ExposureModel.includedLayers`
  // (`0...25`), so its emission is never booked as wear. That is why the hold
  // is capped rather than left to the exposure model to notice.
  window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
  window.collectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
  ]
}
window.ignoresMouseEvents = true
window.setFrame(frame, display: true)
// Installed only when there is something to draw, and only AFTER the frame is
// set so the view's bounds are the field's from its first draw. The luminance
// path's colour was measured as a window background and stays one, so the
// fitting runs composite through exactly the code they were validated on.
if !placedDefects.isEmpty {
  let view = FieldView(frame: NSRect(origin: .zero, size: requestedRect.size))
  view.fieldColor = fieldColor
  view.defects = placedDefects
  window.contentView = view
}

/// Printed with the readback lines when a checkup field was drawn, so the run
/// log records which field and which plant were on the glass.
var checkupFieldLine: String?
if let checkupKind {
  // Device pixels: rect times backing scale is the only ratio that puts one image
  // pixel on one panel pixel. `CGDisplayPixelsWide` is the mode's logical width.
  let fieldPixelWidth = Int((requestedRect.width * pixelScale).rounded())
  let fieldPixelHeight = Int((requestedRect.height * pixelScale).rounded())
  // An off-field plant paints nothing while the summary still records one, so
  // "no plant visible" would look like a panel that hid it.
  if let plant = options.plant,
    plant.x + plant.size > fieldPixelWidth || plant.y + plant.size > fieldPixelHeight
  {
    fail(
      "plant \(plant.x),\(plant.y),\(plant.size) lands outside the "
        + "\(fieldPixelWidth)x\(fieldPixelHeight) pixel field")
  }
  guard
    let image = CheckupField.image(
      kind: checkupKind, pixelWidth: fieldPixelWidth, pixelHeight: fieldPixelHeight,
      plant: options.plant)
  else {
    fail(
      "could not render the \(checkupKind.rawValue) field at "
        + "\(fieldPixelWidth)x\(fieldPixelHeight) device pixels")
  }
  let view = CheckupFieldView(frame: NSRect(origin: .zero, size: requestedRect.size))
  view.image = image
  window.contentView = view
  let plantText = options.plant.map { "\($0.x),\($0.y),\($0.size)" } ?? "none"
  checkupFieldLine =
    "field: \(checkupKind.rawValue) \(fieldPixelWidth)x\(fieldPixelHeight) plant: \(plantText)"
}
window.orderFrontRegardless()

// Let AppKit and the window server settle before reading. `constrainFrameRect`
// and any display re-fit happen on the way through, and a frame read in the
// same turn as the order-front can still be the one that was asked for.
RunLoop.current.run(until: Date().addingTimeInterval(0.25))

let achievedScreen = screen(for: options.displayID) ?? requestedScreen
let achieved = displayLocalRect(forGlobal: window.frame, on: achievedScreen)

// One line carrying everything the run log needs to reconstruct what was on the
// glass: which panel, which field, which level, how long, and every planted
// defect. A defect nobody can find afterwards is a control nobody can trust.
let defectSummary =
  options.defects.isEmpty
  ? "none"
  : options.defects.map {
    "\(format($0.pixelRect))px rgb(\($0.red),\($0.green),\($0.blue))"
  }.joined(separator: "; ")

print(
  "painting \(fieldDescription) on display \(options.displayID), "
    + "level \(options.level.rawValue), hold \(options.hold)s, defects \(defectSummary)")
if let checkupFieldLine { print(checkupFieldLine) }
print("  requested \(format(requestedRect))" + (options.fullscreen ? " (fullscreen)" : ""))
print("  achieved  \(format(achieved))")
fflush(stdout)

// Half a point, which is finer than any constraining AppKit does and coarser
// than backing-store alignment on a 2x screen.
let tolerance = 0.5
let onRequestedDisplay =
  (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
  .uint32Value == options.displayID
guard onRequestedDisplay,
  abs(achieved.origin.x - requestedRect.origin.x) <= tolerance,
  abs(achieved.origin.y - requestedRect.origin.y) <= tolerance,
  abs(achieved.width - requestedRect.width) <= tolerance,
  abs(achieved.height - requestedRect.height) <= tolerance
else {
  // Loud and fatal. A tile that is up but in the wrong place is worse than one
  // that never appeared: the harness would capture it, the gap it left would
  // show wallpaper, and the fit would absorb that into the app priors it is
  // being asked to recover.
  FileHandle.standardError.write(
    Data(
      ("FRAME MISMATCH on display \(options.displayID): requested \(format(requestedRect)), "
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
