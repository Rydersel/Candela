import CandelaKit
import SwiftUI

struct PanelView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.displays.isEmpty {
        Text("No controllable displays")
          .foregroundStyle(.secondary)
      }
      ForEach(model.displays) { state in
        VStack(alignment: .leading, spacing: 8) {
          Text(state.display.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
          DisplaySliderRow(controller: state.controller)
        }
      }
    }
    .padding(14)
    .frame(width: 280)
    .task { await model.refresh() }
  }
}

/// Bridges the controller (source of truth) to the slider's binding.
/// setBrightness is synchronous and coalesces hardware writes, so drag
/// streams are safe to feed directly.
private struct DisplaySliderRow: View {
  let controller: BrightnessController

  var body: some View {
    CandelaSlider(value: Binding(
      get: { controller.brightness },
      set: { controller.setBrightness($0) }
    ))
  }
}
