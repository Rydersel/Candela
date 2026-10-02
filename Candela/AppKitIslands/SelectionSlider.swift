import AppKit
import SwiftUI

/// A stepped native slider that also reports reselecting its current stop.
struct SelectionSlider: NSViewRepresentable {
  @Binding var value: Double
  let stopCount: Int
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
    slider.setAccessibilityLabel("Keep awake duration")
    return slider
  }

  func updateNSView(_ slider: Control, context: Context) {
    context.coordinator.selection = $value
    slider.doubleValue = value
    slider.isEnabled = isEnabled
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
