// Reads the accessibility label of every button in Candela's settings window,
// and whether that button is still operable.
//
// Why this exists rather than an osascript one-liner: AppleScript's `description`
// property is NOT AXDescription. System Events falls back to the ROLE
// description, so an unlabelled button answers "button" and a scroll area
// answers "scroll area" — plausible strings that are not labels and are not
// empty. Enumerating attribute NAMES is no better: the list omits
// AXDescription even where it has a value. Only a direct read of the attribute
// separates absent from present-but-empty, which is the whole question.
//
// SwiftUI publishes a control's label as AXDescription and leaves AXTitle absent
// on every control in this app, working ones included. Both are printed so a
// reading is never mistaken for the other.
//
// Built-in control: the window's own close/zoom/minimize buttons carry no
// AXDescription and must print (absent). If they do not, the reader is wrong and
// every other line is worthless.
//
//   swift axlabel.swift            # every button in the settings window
//   swift axlabel.swift Quit       # only buttons whose label contains "Quit"
import AppKit
import ApplicationServices
import Foundation

func string(_ element: AXUIElement, _ attribute: String) -> String {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
  if status == .attributeUnsupported || status == .noValue { return "(absent)" }
  guard status == .success else { return "(error \(status.rawValue))" }
  guard let text = value as? String else { return "(non-string)" }
  return text.isEmpty ? "(empty)" : text
}

func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
  else { return false }
  return value as? Bool == true
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
        let kids = value as? [AXUIElement] else { return [] }
  return kids
}

func walk(_ element: AXUIElement, depth: Int, filter: String?) {
  guard depth <= 12 else { return }
  if string(element, kAXRoleAttribute as String) == "AXButton" {
    let label = string(element, kAXDescriptionAttribute as String)
    if filter == nil || label.localizedCaseInsensitiveContains(filter!) {
      var actions: CFArray?
      AXUIElementCopyActionNames(element, &actions)
      let canPress = ((actions as? [String]) ?? []).contains("AXPress")
      var names: CFArray?
      AXUIElementCopyAttributeNames(element, &names)
      let focusable = ((names as? [String]) ?? []).contains("AXFocused")
      print("  AXDescription=[\(label)]  AXTitle=[\(string(element, kAXTitleAttribute as String))]"
        + "  AXPress=\(canPress) focusable=\(focusable)"
        + " enabled=\(bool(element, kAXEnabledAttribute as String))")
    }
  }
  for kid in children(element) { walk(kid, depth: depth + 1, filter: filter) }
}

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

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

// Select by exclusion, never by size or index. Exclude the two decoys BY NAME
// rather than by a "Candela " prefix: the settings window is normally named for
// its current pane, but it was measured reporting "Candela Settings" (the scene
// default, before the configurator re-asserts the pane name), and a prefix rule
// throws it away exactly then.
let decoys = ["Candela Gamma Activity Enforcer", "Candela OLED Care Overlay"]
let settings = windows.first { window in
  let name = string(window, kAXTitleAttribute as String)
  return !decoys.contains { name.hasPrefix($0) }
}
guard let settings else {
  print("no settings window: only decoy windows are open")
  exit(1)
}

print("window [\(string(settings, kAXTitleAttribute as String))]")
walk(settings, depth: 0, filter: filter)
