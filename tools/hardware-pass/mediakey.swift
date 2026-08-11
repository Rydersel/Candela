import AppKit

// Posts a real media key (NX system-defined) event. Candela watches these
// through a head-insert event tap, which sees every event regardless of which
// app is frontmost, so this reaches the app even though the terminal has focus
// and a plain `keystroke` would not.
//
// usage: swift mediakey.swift <brightnessUp|brightnessDown|volUp|volDown> [count]

let NX_KEYTYPE_SOUND_UP: Int32 = 0
let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3

func post(_ keyCode: Int32, down: Bool) {
  let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00)
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
]

let args = CommandLine.arguments
guard args.count > 1, let key = names[args[1]] else {
  print("usage: mediakey.swift <\(names.keys.sorted().joined(separator: "|"))> [count]")
  exit(1)
}
let count = args.count > 2 ? (Int(args[2]) ?? 1) : 1

for _ in 0..<count {
  post(key, down: true)
  post(key, down: false)
  usleep(120_000)
}
print("posted \(args[1]) x\(count)")
