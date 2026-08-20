import AppKit

// Posts a real media key (NX system-defined) event. Candela watches these
// through a head-insert event tap, which sees every event regardless of which
// app is frontmost, so this reaches the app even though the terminal has focus
// and a plain `keystroke` would not.
//
// usage: swift mediakey.swift <brightnessUp|brightnessDown|mute|volUp|volDown> [count]
//                             [--cmd] [--opt] [--ctrl] [--shift]
//
// The modifier flags exist for the routes only reachable WITH one:
// Cmd+BrightnessDown is the mirroring toggle (the panic press), and Option
// alone opens Displays settings.
//
// **Whether a synthetic modifier reaches the app is not assumed here.** A
// synthetic shift+option was measured NOT arriving as a fine brightness step on
// 2026-08-11: the step moved a full notch. So any leg depending on a modifier
// needs its own positive control first, and `--opt brightnessDown` opening
// System Settings is the cheap one. Without it, a panic press that did nothing
// cannot be told from a panic press that arrived as a plain brightness step.

let NX_KEYTYPE_SOUND_UP: Int32 = 0
let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
// The mute key toggles rather than sets, so a check that drives it reads the
// achieved state back instead of counting presses.
let NX_KEYTYPE_MUTE: Int32 = 7

let modifierNames: [String: NSEvent.ModifierFlags] = [
  "--cmd": .command, "--opt": .option, "--ctrl": .control, "--shift": .shift,
]
let extraModifiers: NSEvent.ModifierFlags = CommandLine.arguments
  .compactMap { modifierNames[$0] }
  .reduce(into: NSEvent.ModifierFlags()) { $0.formUnion($1) }

func post(_ keyCode: Int32, down: Bool) {
  // The low bits carry the key's own down/up state, not modifiers; the
  // requested modifiers are unioned on top of them.
  let state: NSEvent.ModifierFlags =
    down ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00)
  let flags = state.union(extraModifiers)
  let data1 = Int((keyCode << 16) | ((down ? 0xA : 0xB) << 8))
  guard
    let ev = NSEvent.otherEvent(
      with: .systemDefined,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      subtype: 8,
      data1: data1,
      data2: -1
    )
  else {
    print("could not build event")
    exit(1)
  }
  ev.cgEvent?.post(tap: .cghidEventTap)
}

let names: [String: Int32] = [
  "brightnessUp": NX_KEYTYPE_BRIGHTNESS_UP,
  "brightnessDown": NX_KEYTYPE_BRIGHTNESS_DOWN,
  "volUp": NX_KEYTYPE_SOUND_UP,
  "volDown": NX_KEYTYPE_SOUND_DOWN,
  "mute": NX_KEYTYPE_MUTE,
]

let args = CommandLine.arguments
guard args.count > 1, let key = names[args[1]] else {
  print(
    "usage: mediakey.swift <\(names.keys.sorted().joined(separator: "|"))> [count]"
      + " [--cmd] [--opt] [--ctrl] [--shift]")
  exit(1)
}
// The count is the first argument that parses as a number, so modifier flags
// may appear anywhere after the key name.
let count = args.dropFirst(2).compactMap(Int.init).first ?? 1
let posted = modifierNames.keys.filter(args.contains).sorted().joined(separator: " ")

for _ in 0..<count {
  post(key, down: true)
  post(key, down: false)
  usleep(120_000)
}
print("posted \(args[1]) x\(count)\(posted.isEmpty ? "" : " with \(posted)")")
