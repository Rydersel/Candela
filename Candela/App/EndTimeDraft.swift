import Foundation

/// Text stays editable, including empty or invalid input, without applying a timer.
struct EndTimeDraft: Equatable {
  enum Period: CaseIterable { case am, pm }
  enum InputError { case hour, minute, unavailableTime }

  var day: Date
  var hour: String
  var minute: String
  var period: Period
  let uses24HourClock: Bool
  let calendar: Calendar
  private let originalDate: Date

  init(date: Date, calendar: Calendar = .current, locale: Locale = .current,
       uses24HourClock: Bool? = nil) {
    self.calendar = calendar
    self.originalDate = date
    self.day = calendar.startOfDay(for: date)
    let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
    self.uses24HourClock = uses24HourClock ?? !(format.contains("h") || format.contains("K"))
    let hours = calendar.component(.hour, from: date)
    self.period = hours >= 12 ? .pm : .am
    self.hour = String(format: "%02d", self.uses24HourClock ? hours : (hours % 12 == 0 ? 12 : hours % 12))
    self.minute = String(format: "%02d", calendar.component(.minute, from: date))
  }

  var inputError: InputError? {
    guard let hours = number(hour), (uses24HourClock ? 0...23 : 1...12).contains(hours) else { return .hour }
    guard let minutes = number(minute), (0...59).contains(minutes) else { return .minute }
    return date == nil ? .unavailableTime : nil
  }

  var date: Date? {
    guard let hours = number(hour), (uses24HourClock ? 0...23 : 1...12).contains(hours),
          let minutes = number(minute), (0...59).contains(minutes) else { return nil }
    let clockHour = uses24HourClock ? hours : hours % 12 + (period == .pm ? 12 : 0)
    // Retain the chosen occurrence when reopening a deadline in a repeated hour.
    if calendar.isDate(day, inSameDayAs: originalDate),
       calendar.component(.hour, from: originalDate) == clockHour,
       calendar.component(.minute, from: originalDate) == minutes {
      return calendar.dateInterval(of: .minute, for: originalDate)?.start
    }
    guard let result = calendar.date(bySettingHour: clockHour, minute: minutes, second: 0, of: day,
                                    matchingPolicy: .strict, repeatedTimePolicy: .first),
          calendar.isDate(result, inSameDayAs: day),
          calendar.component(.hour, from: result) == clockHour,
          calendar.component(.minute, from: result) == minutes else { return nil }
    return result
  }

  private func number(_ text: String) -> Int? {
    let digits = text.trimmingCharacters(in: .whitespaces)
    guard (1...2).contains(digits.count) else { return nil }
    var value = 0
    for digit in digits {
      guard let number = digit.wholeNumberValue, (0...9).contains(number) else { return nil }
      value = value * 10 + number
    }
    return value
  }
}

struct EndTimeCalendarMonth {
  let start: Date
  let calendar: Calendar

  init(containing date: Date, calendar: Calendar) {
    self.calendar = calendar
    self.start = calendar.dateInterval(of: .month, for: date)!.start
  }

  var days: [Date?] {
    let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    let count = calendar.range(of: .day, in: .month, for: start)!.count
    return Array(repeating: nil, count: leading) + (0..<count).map {
      calendar.date(byAdding: .day, value: $0, to: start)
    }
  }

  var weekdaySymbols: [String] {
    let symbols = calendar.shortStandaloneWeekdaySymbols
    let offset = calendar.firstWeekday - 1
    return Array(symbols[offset...] + symbols[..<offset])
  }

  func moving(by months: Int) -> Self {
    Self(containing: calendar.date(byAdding: .month, value: months, to: start)!, calendar: calendar)
  }
}
