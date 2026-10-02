import CandelaKit
import Foundation
import Observation

@MainActor @Observable
final class EndTimeSelection {
  var deadline: Date
  private(set) var errorMessage: String?
  private var finished = false
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var apply: ((Date) -> String?)?

  init(currentDeadline: Date?, now: @escaping () -> Date = Date.init,
       apply: @escaping (Date) -> String?) {
    self.now = now
    self.apply = apply
    let instant = now()
    // Fresh selections should not conceal seconds in a minutes-only picker.
    let nextHour = Date(timeIntervalSince1970:
      ceil(instant.addingTimeInterval(3_600).timeIntervalSince1970 / 60) * 60)
    deadline = currentDeadline.flatMap {
      TimedControlDeadline.isValid($0, now: instant) ? $0 : nil
    } ?? nextHour
  }

  var canConfirm: Bool { canConfirm(deadline: deadline) }

  func canConfirm(deadline: Date) -> Bool {
    !finished && TimedControlDeadline.isValid(deadline, now: now())
  }

  func confirm() -> Bool {
    guard !finished, let apply else { return false }
    guard canConfirm else {
      errorMessage = "Choose a future time within the next year."
      return false
    }
    if let error = apply(deadline) {
      errorMessage = error
      return false
    }
    errorMessage = nil
    finished = true
    self.apply = nil
    return true
  }

  func cancel() {
    finished = true
    apply = nil
  }
}

/// Distinguish a later date from the same clock time today.
enum EndTimeText {
  static func string(_ deadline: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    deadline.formatted(date: calendar.isDate(deadline, inSameDayAs: now) ? .omitted : .abbreviated,
                       time: .shortened)
  }
}

extension AppModel {
  func chooseKeepAwakeEndTime() {
    endTimePicker.present(title: "Keep Display Awake", detail: "Choose when the display can sleep again.",
                         actionTitle: "Keep Awake", currentDeadline: keepAwake.expiresAt) { [weak self] deadline in
      guard let self, !self.isResetting else { return "Wait for the settings reset to finish." }
      return self.keepAwake.start(until: deadline) ? nil : "macOS could not keep the display awake. Try again."
    }
  }

  func chooseDimmingPauseEndTime(for key: String, name: String) {
    endTimePicker.present(title: "Pause Dimming", detail: name,
                         actionTitle: "Pause Dimming", currentDeadline: oledCare.dimmingPauseDeadline(for: key)) { [weak self] deadline in
      guard let self else { return "Candela is no longer available." }
      return self.applyDimmingPause(until: deadline, for: key)
    }
  }

  func applyDimmingPause(until deadline: Date, for key: String) -> String? {
    guard !isResetting, !isSafeMode,
          displays.contains(where: { $0.display.persistenceKey == key }),
          oledCare.isEnrolled(key) else {
      return "This display is no longer available for dimming pause."
    }
    return oledCare.pauseDimming(for: key, until: deadline) ? nil : "Choose a future end time and try again."
  }
}
