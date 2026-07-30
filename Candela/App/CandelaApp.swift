import SwiftUI

@main
struct CandelaApp: App {
  var body: some Scene {
    MenuBarExtra("Candela", systemImage: "sun.max") {
      Text("Candela scaffold")
        .padding()
    }
    .menuBarExtraStyle(.window)
  }
}
