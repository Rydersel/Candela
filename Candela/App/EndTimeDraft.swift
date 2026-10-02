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
    // Quoted runs are literal text: German's pattern is HH 'Uhr', whose h is not a field.
    let fields = format.split(separator: "'", omittingEmptySubsequences: false)
      .enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined()
    self.uses24HourClock = uses24HourClock ?? !(fields.contains("h") || fields.contains("K"))
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
    // An unchanged reopen returns the deadline exactly: that keeps the chosen
    // occurrence of a repeated hour, and keeps the seconds a minute-only field
    // cannot show, so confirming as-is never shortens the hold.
    if calendar.isDate(day, inSameDayAs: originalDate),
       calendar.component(.hour, from: originalDate) == clockHour,
       calendar.component(.minute, from: originalDate) == minutes {
      return originalDate
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

/// Dates in English whatever the system language, because the app ships in
/// English only and the words around them are English. The 12- or 24-hour
/// clock and the first day of the week still follow the person's own settings.
enum EnglishDates {
  static func locale(clockFrom locale: Locale = .current) -> Locale {
    var names = Locale.Components(locale: Locale(identifier: "en_US"))
    names.hourCycle = locale.hourCycle
    return Locale(components: names)
  }

  static func calendar(_ base: Calendar = .current, clockFrom locale: Locale = .current) -> Calendar {
    var calendar = base
    calendar.locale = self.locale(clockFrom: locale)
    // A locale change resets the week's start to the new locale's.
    calendar.firstWeekday = base.firstWeekday
    return calendar
  }

  static func style(
    date: Date.FormatStyle.DateStyle? = nil, time: Date.FormatStyle.TimeStyle? = nil,
    calendar: Calendar = .current, clockFrom locale: Locale = .current
  ) -> Date.FormatStyle {
    Date.FormatStyle(date: date, time: time, locale: self.locale(clockFrom: locale),
                     calendar: calendar, timeZone: calendar.timeZone)
  }
}
