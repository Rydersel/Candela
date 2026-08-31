import AppKit
import CandelaKit

// Draws one opaque window of an exactly known luminance at an exactly known
// position, so the fit can be asked to recover an answer already known. Every
// other fitting run is on data whose true answer nobody knows: one smoke run
// reported app priors of 0.857 and 0.714 that were only the optimiser's
// starting values.
//
// `kCGWindowOwnerName` comes from the process name, so copying this binary to
// several names is how one harness produces several distinct "apps".
//
// Every geometry printed here is read back, never the requested value: tiles
// must cover the display completely, and a gap feeds the unreliable wallpaper
// term back into a fit that exists to be free of it.

/// What the window is filled with. `luminance` goes through the inverse sRGB
/// EOTF; `srgb` carries the dead-pixel protocol's field values, already encoded,
/// so no transfer function is applied. `checkup` is rendered by the engine, so
/// the tool draws the same image the app puts on glass.
enum Field {
  case luminance(Double)
  case srgb(red: Int, green: Int, blue: Int, patternName: String?)
  case checkup(CheckupFieldKind)
}

enum LevelChoice: String {
  case normal
  case shielding
}

/// One planted defect: a filled rect over the field, in DEVICE PIXELS,
/// display-local, top-left origin. A stuck pixel is a device pixel, and the same
/// rect in points covers a different count of them per panel scale.
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

/// The protocol's flat fields, as encoded sRGB.
let patterns: [String: (red: Int, green: Int, blue: Int)] = [
  "black": (0, 0, 0), "red": (255, 0, 0), "green": (0, 255, 0),
  "blue": (0, 0, 255), "white": (255, 255, 255),
]

/// Hard cap on one static field at shielding level: full-field white that
/// nothing covers and nothing dims is the worst case this tool can put on an OLED.
let shieldingHoldCap = 60.0

/// The tile size a run gets when it names neither `--rect` nor `--fullscreen`.
let defaultRect = CGRect(x: 0, y: 0, width: 400, height: 300)

struct Options {
  var displayID: CGDirectDisplayID = CGMainDisplayID()
  /// Nil until resolved: `--fullscreen` needs a display frame, unknown at parse time.
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
    // A zero or negative tile composites nothing while every line still says it
    // painted, and the only assertion is on recovered luminance.
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
    // A zero-sized or off-field plant paints nothing while the summary records one.
    guard parts.count == 3, parts[0] >= 0, parts[1] >= 0, parts[2] > 0 else { usage() }
    options.plant = CheckupPlant(x: parts[0], y: parts[1], size: parts[2])
  case "--level":
    guard let choice = LevelChoice(rawValue: value()) else { usage() }
    options.level = choice
  case "--defect":
    let parts = value().split(separator: ",").compactMap { Double($0) }
    // Size checked as in `--rect`; channels checked because a defect the field's
    // own colour hides is a control that always reads "nothing visible".
    guard parts.count == 7, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0,
      parts[4...6].allSatisfy({ $0 >= 0 && $0 <= 255 && $0 == $0.rounded() })
    else { usage() }
    options.defects.append(
      Defect(
        pixelRect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
        red: Int(parts[4]), green: Int(parts[5]), blue: Int(parts[6])))
  case "--hold":
    // `--hold 0` exited before compositing anything, printing that it was painting.
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

/// Inverse sRGB EOTF. A grey has R = G = B, so Rec. 709 collapses to the linear
/// value: this encoded grey produces exactly the requested relative luminance.
func encodedGrey(forLuminance luminance: Double) -> Double {
  luminance <= 0.0031308
    ? luminance * 12.92
    : 1.055 * pow(luminance, 1.0 / 2.4) - 0.055
}

/// Display-local top-left to Cocoa's global bottom-left origin, and back. Paired
/// so the achieved frame is compared in the space the caller asked in.
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
/// `constrainFrameRect` keeps an ordinary window clear of the menu bar: a tile
/// asked for at 0,0 300x200 came back at 0,38 [MEASURED 2026-08-18], leaving a
/// wallpaper strip the harness would capture as content it did not paint. Tiles
/// must cover the display completely, so placement wins over the constraint.
/// Raising the window level is the other escape, unavailable here (see `.normal`).
final class UnconstrainedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// Paints the field and any planted defects over it. Flipped, so a defect's
/// display-local top-left rect reaches the view by translation alone: a defect
/// one row out of place still reads as a defect, so a flip error would survive
/// the human check.
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

// Resolved here: no display was known at parse time.
let requestedRect =
  options.rect
  ?? (options.fullscreen
    ? CGRect(origin: .zero, size: requestedScreen.frame.size)
    : defaultRect)

// Device pixels to points. `backingScaleFactor` is the panel's real ratio;
// `CGDisplayPixelsWide` reports the current mode's logical width instead.
let pixelScale = requestedScreen.backingScaleFactor

let fieldColor: NSColor
let fieldDescription: String
switch options.field {
case .luminance(let luminance):
  let grey = encodedGrey(forLuminance: luminance)
  // Calibrated sRGB, matching the colour space the capture pins, so the panel
  // profile cannot reinterpret the value.
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
  // A defect off the field paints nothing while the summary records one, and the
  // reader answers "no defect visible": what the plant exists to rule out.
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

// `contentRect: .zero` then `setFrame`, deliberately. The initialiser's
// `contentRect` is relative to the `screen:` argument, so a global frame passed
// there adds the screen origin twice. MEASURED 2026-08-18: a tile asked for at
// display-local 100,300 on the MAG landed at 3340,436. Starting from zero keeps
// `setFrame` the only place geometry enters, so it cannot look redundant.
// A borderless window's frame and content rect are the same rectangle.
let window = UnconstrainedWindow(
  contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false,
  screen: requestedScreen)
window.backgroundColor = fieldColor
window.isOpaque = true
window.hasShadow = false
switch options.level {
case .normal:
  // `.normal`, not a level above the menu bar: a window's level becomes its
  // `kCGWindowLayer`, and a tile outside `ExposureModel.includedLayers` has its
  // contribution dropped, so the fit could never recover the planted prior.
  window.level = .normal
case .shielding:
  // Dead-pixel protocol only, where nothing may cover the field and nobody is
  // fitting it. A shielding-level window sits outside
  // `ExposureModel.includedLayers`, so its emission is never booked as wear,
  // which is why the hold is capped here instead.
  window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
  window.collectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
  ]
}
window.ignoresMouseEvents = true
window.setFrame(frame, display: true)
// Only when there is something to draw, and after the frame is set so the view's
// bounds are the field's from its first draw. The luminance path's colour was
// measured as a window background and stays one.
if !placedDefects.isEmpty {
  let view = FieldView(frame: NSRect(origin: .zero, size: requestedRect.size))
  view.fieldColor = fieldColor
  view.defects = placedDefects
  window.contentView = view
}

/// Which field and plant were on the glass, printed with the readback lines.
var checkupFieldLine: String?
if let checkupKind {
  // Rect times backing scale is the only ratio putting one image pixel on one
  // panel pixel.
  let fieldPixelWidth = Int((requestedRect.width * pixelScale).rounded())
  let fieldPixelHeight = Int((requestedRect.height * pixelScale).rounded())
  // "No plant visible" must not be able to mean the plant was never painted.
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

// Let the window server settle first: a frame read in the same turn as the
// order-front can still be the one that was asked for.
RunLoop.current.run(until: Date().addingTimeInterval(0.25))

let achievedScreen = screen(for: options.displayID) ?? requestedScreen
let achieved = displayLocalRect(forGlobal: window.frame, on: achievedScreen)

// A defect nobody can find in the run log afterwards is a control nobody can trust.
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
  // A tile up in the wrong place is worse than one that never appeared: the
  // harness captures it, the gap it left shows wallpaper, and the fit absorbs
  // that into the app priors it is meant to recover.
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
