// Reads and presses arbitrary elements of Candela's settings window, for the
// parts of a pass `ax.sh` cannot reach: a countdown banner's Keep button (a
// SwiftUI button, whose label is AXDescription and whose AXTitle is absent),
// and a LabeledContent readout such as OLED care's "Last pair", whose value is
// a sibling static text rather than a control value.
//
// Written in Swift rather than as another osascript verb for the reason
// `axlabel.swift` was: AppleScript's `description` is NOT AXDescription (System
// Events falls back to the ROLE description, so an unlabelled button answers
// "button"), and enumerating attribute names omits AXDescription even where it
// has a value. Only a direct attribute read separates absent from
// present-but-empty.
//
//   swift axprobe.swift dump [filter]   every element, tree order, one per line
//   swift axprobe.swift press <label>   press the ONE element matching <label>
//
// `dump` prints role, AXTitle, AXDescription and AXValue for every element, so
// a LabeledContent readout is the line after its label and `grep -A2` reaches
// it. `press` refuses on zero matches and on more than one, listing what it
// saw: a selector that matches nothing reports every control missing, which
// reads exactly like a real defect in the app.
//
// Built-in control, same as `axlabel.swift`: the window's own close/zoom
// buttons carry no AXDescription and print (absent). If they do not, the reader
// is wrong and every other line is worthless.
import AppKit
import ApplicationServices
import Foundation

func string(_ element: AXUIElement, _ attribute: String) -> String {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
  if status == .attributeUnsupported || status == .noValue { return "(absent)" }
  guard status == .success else { return "(error \(status.rawValue))" }
  if let text = value as? String { return text.isEmpty ? "(empty)" : text }
  if let number = value as? NSNumber { return number.stringValue }
  return "(non-string)"
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
        let kids = value as? [AXUIElement] else { return [] }
  return kids
}

func actions(_ element: AXUIElement) -> [String] {
  var value: CFArray?
  AXUIElementCopyActionNames(element, &value)
  return (value as? [String]) ?? []
}

/// Both label attributes, because this app publishes control labels as
/// AXDescription and leaves AXTitle absent, while AppKit windows and menu items
/// do the opposite. A matcher that read only one would discriminate nothing on
/// half the tree.
func labels(_ element: AXUIElement) -> [String] {
  [string(element, kAXDescriptionAttribute as String), string(element, kAXTitleAttribute as String)]
    .filter { $0 != "(absent)" && $0 != "(empty)" && $0 != "(non-string)" }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, ["dump", "press"].contains(arguments[1]) else {
  print("usage: axprobe.swift dump [filter] | axprobe.swift press <label>")
  exit(2)
}
let verb = arguments[1]
let argument: String? = arguments.count > 2 ? arguments[2] : nil
if verb == "press" && argument == nil {
  print("usage: axprobe.swift press <label>")
  exit(2)
}

guard let app = NSWorkspace.shared.runningApplications
  .first(where: { $0.bundleIdentifier == "com.rydersel.Candela" })
else {
  print("Candela is not running")
  exit(1)
}
guard AXIsProcessTrusted() else {
  print("no Accessibility grant for this shell: every read below would be empty")
  exit(1)
}

var windowValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(
  AXUIElementCreateApplication(app.processIdentifier),
  kAXWindowsAttribute as CFString, &windowValue
) == .success, let windows = windowValue as? [AXUIElement] else {
  print("no windows: open Settings first")
  exit(1)
}

// Select by exclusion, never by size and never by index. Candela also owns a
// 1x1 gamma enforcer window and a full-screen OLED care overlay, both of which
// come and go and shift every index. Exclude those two BY NAME rather than by a
// "Candela " prefix: the settings window is normally named for its current pane
// but was measured reporting "Candela Settings", and a prefix rule throws the
// real window away exactly then.
let decoys = ["Candela Gamma Activity Enforcer", "Candela OLED Care Overlay"]

// Filter to real windows FIRST. Measured 2026-08-18 with the settings window
// closed: AXWindows on this app answers with two elements whose AXRole is
// AXApplication, both titled "Candela". They pass any title-based exclusion,
// and binding one walks the entire application tree, so a run would report
// controls from everywhere and nowhere. The role check is what turns that into
// the honest answer, which is that no settings window is open.
let realWindows = windows.filter { string($0, kAXRoleAttribute as String) == "AXWindow" }
let candidates = realWindows.filter { window in
  let name = string(window, kAXTitleAttribute as String)
  return !decoys.contains { name.hasPrefix($0) }
}
guard candidates.count == 1, let settings = candidates.first else {
  if realWindows.isEmpty {
    print("no settings window: open Settings first (AXWindows held \(windows.count) non-window elements)")
    exit(1)
  }
  print("axprobe: settings window not uniquely identified: \(candidates.count) candidates.")
  for window in realWindows { print("  [\(string(window, kAXTitleAttribute as String))]") }
  exit(1)
}
print("window [\(string(settings, kAXTitleAttribute as String))]")

var pressable: [AXUIElement] = []

func walk(_ element: AXUIElement, depth: Int) {
  guard depth <= 24 else { return }
  let role = string(element, kAXRoleAttribute as String)
  let title = string(element, kAXTitleAttribute as String)
  let description = string(element, kAXDescriptionAttribute as String)
  let value = string(element, kAXValueAttribute as String)
  let line = "\(String(repeating: " ", count: depth))\(role)"
    + " AXTitle=[\(title)] AXDescription=[\(description)] AXValue=[\(value)]"
  switch verb {
  case "dump":
    if argument == nil || line.localizedCaseInsensitiveContains(argument!) { print(line) }
  default:
    if actions(element).contains("AXPress"),
       labels(element).contains(where: { $0.localizedCaseInsensitiveContains(argument!) })
    {
      pressable.append(element)
      print("candidate:\(line)")
    }
  }
  for kid in children(element) { walk(kid, depth: depth + 1) }
}

walk(settings, depth: 0)

if verb == "press" {
  guard pressable.count == 1 else {
    print("press: \(pressable.count) elements match [\(argument!)]; refusing rather than guessing")
    exit(1)
  }
  let result = AXUIElementPerformAction(pressable[0], kAXPressAction as CFString)
  guard result == .success else {
    print("press: AXPress failed (\(result.rawValue))")
    exit(1)
  }
  print("pressed [\(argument!)]")
}
