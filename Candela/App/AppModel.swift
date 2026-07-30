import CandelaKit
import CoreGraphics
import Observation

@MainActor @Observable
final class AppModel {
  struct DisplayState: Identifiable {
    let display: ExternalDisplay
    let controller: BrightnessController
    var id: CGDirectDisplayID { display.id }
  }

  private(set) var displays: [DisplayState] = []

  func refresh() async {
    displays = DisplayDiscovery.discover().map { entry in
      DisplayState(display: entry.display, controller: BrightnessController(writer: entry.writer))
    }
    for state in displays {
      await state.controller.refreshFromHardware()
    }
  }
}
