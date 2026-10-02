import CandelaKit
import Foundation
import Observation

@MainActor @Observable
final class EndTimeSelection {
  // A refused apply's error describes the moment it was refused; a new choice
  // falls back to live validation rather than keeping a stale refusal.
  var deadline: Date { didSet { errorMessage = nil } }
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
  static func string(_ deadline: Date, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
    deadline.formatted(EnglishDates.style(
      date: calendar.isDate(deadline, inSameDayAs: now) ? .omitted : .abbreviated,
      time: .shortened, calendar: calendar, clockFrom: locale))
  }
}

extension AppModel {
  func chooseKeepAwakeEndTime() {
    endTimePicker.present(title: "Keep Display Awake", detail: "Choose when the display can sleep again.",
                         actionTitle: "Keep Awake", currentDeadline: keepAwake.expiresAt) { [weak self] deadline in
      guard let self else { return "\(AppInfo.productName) is no longer available." }
      return self.applyKeepAwake(until: deadline, to: self.keepAwake)
    }
  }

  /// No reset gate: no reset touches Keep Awake, and the panel's switch and
  /// slider are not gated either. The dialog's confirm closure is nothing but
  /// this call, so a test of this seam covers the dialog's behaviour.
  func applyKeepAwake(until deadline: Date, to keepAwake: KeepAwake) -> String? {
    KeepAwakeDuration.start(keepAwake, until: deadline)
      ? nil : "macOS could not keep the display awake. Try again."
  }

  func chooseDimmingPauseEndTime(for key: String, name: String) {
    endTimePicker.present(title: "Pause Dimming", detail: "Choose when dimming resumes on \(name).",
                         actionTitle: "Pause Dimming", currentDeadline: oledCare.dimmingPauseDeadline(for: key)) { [weak self] deadline in
      guard let self else { return "Candela is no longer available." }
      return self.applyDimmingPause(until: deadline, for: key)
    }
  }

  func applyDimmingPause(until deadline: Date, for key: String) -> String? {
    // The coordinator's scope, not `isResetting`: that latch is also up while
    // a different display resets.
    if oledCare.isResetBlockingDimmingPause(for: key) { return "Wait for the settings reset to finish." }
    guard !isSafeMode,
          displays.contains(where: { $0.display.persistenceKey == key }),
          oledCare.isEnrolled(key) else {
      return "This display is no longer available for dimming pause."
    }
    return oledCare.pauseDimming(for: key, until: deadline) ? nil : "Choose a future end time and try again."
  }
}
