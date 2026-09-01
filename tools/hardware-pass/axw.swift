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
// Why a third AX tool: `axprobe.swift` walks every non-decoy window and the
// first match wins, so with a checkup or keep/revert window open beside settings
// it reads or presses inside the wrong one while reporting success, and `ax.sh`
// binds nothing in that state and reports every control missing. Naming the
// window is the fix. Prefix match, because the settings window is named for its
// current pane and the field window's title carries a suffix.
//
// Matches AXDescription or AXTitle, never AXStaticText, for the measured reasons
// the other tools carry: SwiftUI labels controls via AXDescription and AppKit
// via AXTitle, and multi-line static text publishes description-less AXButton
// children that are not controls. `press` takes `--nth N` in dump order because
// a flow page can carry one description twice; the default is the first match,
// so prefer an exact, unique description.
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
// Role filter: AXWindows also returns AXApplication elements titled "Candela",
// and binding one walks the whole application tree instead of a window.
let wins = ((wv as? [AXUIElement]) ?? []).filter { str($0, kAXRoleAttribute as String) == "AXWindow" }
guard let win = wins.first(where: { (str($0, kAXTitleAttribute as String) ?? "").hasPrefix(wantTitle) }) else {
  // List what is open, so a mistyped or stale title does not read as a defect in the app.
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
