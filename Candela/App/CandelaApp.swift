import CandelaKit
import SwiftUI

@main
struct CandelaApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra("Candela", systemImage: "sun.max") {
      PanelView()
        .environment(model)
    }
    .menuBarExtraStyle(.window)
  }
}
