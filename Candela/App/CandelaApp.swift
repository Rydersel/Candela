import SwiftUI
import CandelaKit

@main
struct CandelaApp: App {
  var body: some Scene {
    MenuBarExtra("Candela", systemImage: "sun.max") {
      Text("Candela scaffold — VCP 0x\(String(CandelaKit.VCP.brightness, radix: 16))")
        .padding()
    }
    .menuBarExtraStyle(.window)
  }
}
