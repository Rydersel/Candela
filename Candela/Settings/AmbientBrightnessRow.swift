import AppKit
import CandelaKit
import Combine
import CoreGraphics
import SwiftUI

/// What the row shows. `.hidden` is a real state and not an error: a display
/// with no ambient light sensor gets no row at all, because a switch that
/// cannot do anything is worse than the absence of one.
enum AmbientRowState: Equatable {
  case hidden
  case shown(isOn: Bool)
}

/// macOS's own ambient auto-brightness, the switch System Settings calls
/// "Automatically adjust brightness".
///
/// Self-contained: it reads the built-in display out of the environment, so a
/// pane places it with a bare `AmbientBrightnessRow()` inside a card. It renders
/// nothing where the sensor is absent, so the card hosting it must read
/// correctly with the row gone.
///
/// macOS is the store. No Candela pref behind this and no mirror into one: the
/// state is read live, and the switch shows what macOS reports after a write,
/// never what was asked for.
@MainActor
struct AmbientBrightnessRow: View {
  @Environment(AppModel.self) private var model

  var compensation: AmbientLightCompensation = .live

  /// The last state MEASURED from macOS, or nil before the first read. Never a
  /// requested value.
  @State private var measured: Bool?

  /// How long to wait before confirming a write. The setter is believed
  /// synchronous; if it settles asynchronously instead, this is what stops the
  /// switch from publishing a stale read as the achieved state.
  private static let settleDelay = Duration.milliseconds(400)

  var body: some View {
    if let displayID = model.builtIn?.id,
       case let .shown(isOn) = Self.rowState(
         displayID: displayID,
         hasSensor: compensation.supports,
         isEnabled: { measured ?? compensation.isEnabled($0) }
       ) {
      SettingRow("When this is on, macOS changes the display's brightness to match the light in the room. It is the same setting as the one in System Settings.") {
        Toggle("Automatically adjust brightness", isOn: Binding(
          get: { isOn },
          set: { request($0, for: displayID) }
        ))
        .themedSwitch()
      }
      // macOS can move this setting underneath us with no notification, so
      // re-read on appear, on activation (the trip to System Settings and back)
      // and on an identity change (a replug hands the same panel a new ID).
      .onAppear { measured = compensation.isEnabled(displayID) }
      .onChange(of: displayID) { _, current in measured = compensation.isEnabled(current) }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        measured = compensation.isEnabled(displayID)
      }
    }
  }

  /// Whether the row appears, and what it shows when it does.
  ///
  /// No display and no readable state both hide it: neither leaves the switch
  /// anything true to show. Hidden, not greyed, because a greyed switch invites
  /// the question of how to un-grey it and here there is no answer.
  static func rowState(
    displayID: CGDirectDisplayID?,
    hasSensor: (CGDirectDisplayID) -> Bool,
    isEnabled: (CGDirectDisplayID) -> Bool?
  ) -> AmbientRowState {
    guard let displayID, hasSensor(displayID) else { return .hidden }
    guard let isOn = isEnabled(displayID) else { return .hidden }
    return .shown(isOn: isOn)
  }

  /// Asks macOS for a new setting and publishes what it reports afterwards.
  ///
  /// The immediate re-read is the achieved-state check and the delayed one is
  /// its safety net. Neither stores the requested value, so a write macOS
  /// declines leaves the switch where the hardware is, not where the click put
  /// it.
  private func request(_ enabled: Bool, for displayID: CGDirectDisplayID) {
    measured = compensation.setEnabled(enabled, for: displayID)
    Task {
      try? await Task.sleep(for: Self.settleDelay)
      measured = compensation.isEnabled(displayID)
    }
  }
}
