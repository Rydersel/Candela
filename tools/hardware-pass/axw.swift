// Drives one NAMED window of Candela over the accessibility API, for the passes
// where the app has several windows open at once.
//
//   swift axw.swift <windowTitlePrefix> dump [filter]
//   swift axw.swift <windowTitlePrefix> press <desc> [--nth N]
//   swift axw.swift <windowTitlePrefix> value <desc>
//   swift axw.swift <windowTitlePrefix> inc <desc>
//   swift axw.swift <windowTitlePrefix> dec <desc>
//   swift axw.swift <windowTitlePrefix> frame <desc>
//
// Why a third AX tool. `axprobe.swift` binds every window that is not a NAMED
// decoy and walks them all, so the first match wins whenever more than one
// window is legitimately open: the checkup flow ("Candela Checkup", "Candela
// Checkup Field") and the keep/revert confirmation windows ("Display
// resolution", "Display orientation", "Display mirroring") all coexist with
// settings, and a run then reads or presses inside the wrong one while every
// call reports success. `ax.sh` is worse off in that state: its exclusion list
// does not name those windows, so it binds nothing and reports every control
// missing, which reads exactly like a real defect in the app. Naming the window
// on the command line is the fix, and it also reaches windows no exclusion list
// will ever admit. A prefix match, not equality, because the settings window is
// named for its current pane and the field window's title carries a suffix.
//
// Matching is on AXDescription or AXTitle and never on AXStaticText, for the
// two measured reasons the other tools carry: SwiftUI publishes a control's
// label as AXDescription here and leaves AXTitle absent, while AppKit windows
// and menu items do the opposite, and multi-line static text publishes
// synthesized AXButton children with no description that are not controls.
// Unlike `axprobe.swift press`, which refuses an ambiguous match, `press` here
// takes `--nth N` in tree order (the order `dump` prints), because a flow page
// can legitimately carry one description more than once; the default is the
// first match, so an unnoticed ambiguity still presses something. Prefer an
// exact, unique description.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
let usage = """
usage: axw.swift <windowTitlePrefix> dump [filter]
       axw.swift <windowTitlePrefix> press <desc> [--nth N]
       axw.swift <windowTitlePrefix> value|inc|dec|frame <desc>
"""
guard args.count >= 3 else {
  print(usage)
  exit(2)
}
let wantTitle = args[1]
let cmd = args[2]
guard cmd == "dump" || args.count >= 4 else {
  print(usage)
  exit(2)
}

func str(_ el: AXUIElement, _ attr: String) -> String? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
  if let s = v as? String { return s }
  if let n = v as? NSNumber { return n.stringValue }
  return v.map { "\($0)" }
}

func children(_ el: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
        let a = v as? [AXUIElement] else { return [] }
  return a
}

guard let app = NSRunningApplication
  .runningApplications(withBundleIdentifier: "com.rydersel.Candela").first
else {
  print("no app")
  exit(1)
}

let ax = AXUIElementCreateApplication(app.processIdentifier)
var wv: CFTypeRef?
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wv)
// Filter on the role first: AXWindows on this app also answers with
// AXApplication elements titled "Candela", and binding one walks the entire
// application tree instead of a window.
let wins = ((wv as? [AXUIElement]) ?? []).filter { str($0, kAXRoleAttribute as String) == "AXWindow" }
guard let win = wins.first(where: { (str($0, kAXTitleAttribute as String) ?? "").hasPrefix(wantTitle) }) else {
  // List what IS open: a title that matches nothing otherwise reports every
  // control missing, which looks like a defect in the app rather than a
  // mistyped or stale window name.
  print("no window titled '\(wantTitle)'; open: \(wins.map { str($0, kAXTitleAttribute as String) ?? "(unnamed)" })")
  exit(1)
}

var found: [AXUIElement] = []

func walk(_ el: AXUIElement, _ depth: Int) {
  let role = str(el, kAXRoleAttribute as String) ?? "?"
  let title = str(el, kAXTitleAttribute as String) ?? ""
  let desc = str(el, kAXDescriptionAttribute as String) ?? ""
  let value = str(el, kAXValueAttribute as String) ?? ""
  let enabled = str(el, kAXEnabledAttribute as String) ?? ""
  let line = "\(role) title=[\(title)] desc=[\(desc)] value=[\(value.prefix(90))] enabled=\(enabled)"
  switch cmd {
  case "dump":
    if args.count < 4 || line.localizedCaseInsensitiveContains(args[3]) {
      print(String(repeating: " ", count: depth) + line)
    }
  case "press", "value", "inc", "dec", "frame":
    if (desc == args[3] || title == args[3]) && role != "AXStaticText" { found.append(el) }
  default:
    break
  }
  for c in children(el) { walk(c, depth + 1) }
}

walk(win, 0)

if cmd == "press" {
  var nth = 0
  if let i = args.firstIndex(of: "--nth"), i + 1 < args.count { nth = Int(args[i + 1]) ?? 0 }
  guard found.count > nth else {
    print("press: \(found.count) match(es) for [\(args[3])]")
    exit(1)
  }
  let r = AXUIElementPerformAction(found[nth], kAXPressAction as CFString)
  print("pressed [\(args[3])] #\(nth) -> \(r.rawValue)")
} else if cmd == "inc" || cmd == "dec" {
  guard let f = found.first else {
    print("no match for [\(args[3])]")
    exit(1)
  }
  let r = AXUIElementPerformAction(f, (cmd == "inc" ? kAXIncrementAction : kAXDecrementAction) as CFString)
  print("\(cmd) [\(args[3])] -> \(r.rawValue) value=\(str(f, kAXValueAttribute as String) ?? "?")")
} else if cmd == "frame" {
  // Global top-left origin coordinates, the frame a posted CGEvent click needs.
  for f in found {
    var pv: CFTypeRef?
    var sv: CFTypeRef?
    AXUIElementCopyAttributeValue(f, kAXPositionAttribute as CFString, &pv)
    AXUIElementCopyAttributeValue(f, kAXSizeAttribute as CFString, &sv)
    var pt = CGPoint.zero
    var sz = CGSize.zero
    if let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &pt) }
    if let sv { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
    print("\(Int(pt.x)) \(Int(pt.y)) \(Int(sz.width)) \(Int(sz.height))")
  }
} else if cmd == "value" {
  for f in found { print(str(f, kAXValueAttribute as String) ?? "(no value)") }
}
