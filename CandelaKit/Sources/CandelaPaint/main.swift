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
      --rect x,y,w,h          display-local, top-left origin
      --luminance <0...1>     RELATIVE LUMINANCE, not an sRGB value
      --hold <seconds>
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
    guard parts.count == 4 else { usage() }
    options.rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
  case "--luminance":
    guard let value = Double(value()), value >= 0, value <= 1 else { usage() }
    options.luminance = value
  case "--hold":
    guard let value = Double(value()) else { usage() }
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

guard
  let screen = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      == options.displayID
  })
else {
  FileHandle.standardError.write(Data("no NSScreen for display \(options.displayID)\n".utf8))
  exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Display-local top-left to Cocoa's global bottom-left origin.
let frame = CGRect(
  x: screen.frame.minX + options.rect.origin.x,
  y: screen.frame.maxY - options.rect.origin.y - options.rect.height,
  width: options.rect.width, height: options.rect.height)

let window = NSWindow(
  contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
let grey = encodedGrey(forLuminance: options.luminance)
// Calibrated sRGB, matching the colour space the capture pins, so the value
// that arrives is the value asked for rather than whatever the panel profile
// would have made of it.
window.backgroundColor = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
window.isOpaque = true
window.hasShadow = false
window.level = .normal
window.ignoresMouseEvents = true
window.setFrame(frame, display: true)
window.orderFrontRegardless()

print(
  "painting luminance \(options.luminance) (sRGB \(String(format: "%.4f", grey))) "
    + "at \(Int(options.rect.origin.x)),\(Int(options.rect.origin.y)) "
    + "\(Int(options.rect.width))x\(Int(options.rect.height)) on display \(options.displayID)")

Timer.scheduledTimer(withTimeInterval: options.hold, repeats: false) { _ in
  // The timer fires on the main run loop, so the isolation is real; Swift 6
  // cannot see that through the nonisolated closure type.
  MainActor.assumeIsolated { application.terminate(nil) }
}
application.run()
