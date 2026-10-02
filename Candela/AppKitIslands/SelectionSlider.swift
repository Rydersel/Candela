import AppKit
import SwiftUI

/// A stepped native slider that also reports reselecting its current stop.
///
/// The label and spoken value go on the slider's cell, which is the element
/// AppKit publishes (an `AXSlider` whose default value is the bare stop index).
/// SwiftUI modifiers on the representable never reach it, and neither does a
/// label set on the control alone; `PanelSizingTests` pins both.
struct SelectionSlider: NSViewRepresentable {
  @Binding var value: Double
  let stopCount: Int
  let accessibilityLabel: String
  let valueDescription: (Double) -> String
  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> Control {
    let slider = Control()
    slider.controlSize = .small
    slider.minValue = 0
    slider.maxValue = Double(stopCount - 1)
    slider.numberOfTickMarks = stopCount
    slider.allowsTickMarkValuesOnly = true
    slider.isContinuous = true
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.changed(_:))
    slider.didSelect = { [weak coordinator = context.coordinator] slider in
      coordinator?.changed(slider)
    }
    return slider
  }

  func updateNSView(_ slider: Control, context: Context) {
    context.coordinator.selection = $value
    slider.doubleValue = value
    slider.isEnabled = isEnabled
    let spoken = valueDescription(value)
    slider.setAccessibilityLabel(accessibilityLabel)
    slider.setAccessibilityValueDescription(spoken)
    slider.cell?.setAccessibilityLabel(accessibilityLabel)
    slider.cell?.setAccessibilityValueDescription(spoken)
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $value) }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<Double>
    init(selection: Binding<Double>) { self.selection = selection }
    @objc func changed(_ slider: NSSlider) { selection.wrappedValue = slider.doubleValue }
  }

  final class Control: NSSlider {
    var didSelect: ((NSSlider) -> Void)?
    override func mouseDown(with event: NSEvent) {
      super.mouseDown(with: event)
      guard isEnabled else { return }
      didSelect?(self)
    }
  }
}
