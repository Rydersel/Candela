import Foundation
import Testing

@Suite("Custom date and time input")
struct EndTimeDraftTests {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "America/Chicago")!
    value.locale = Locale(identifier: "en_US")
    value.firstWeekday = 1
    return value
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test func noonAndMidnightAndChangingTheDayKeepTheChosenClockTime() {
    var draft = EndTimeDraft(date: date(2026, 9, 30, 0, 45), calendar: calendar, uses24HourClock: false)
    #expect(draft.hour == "12" && draft.period == .am)
    #expect(draft.date == date(2026, 9, 30, 0, 45))
    draft.period = .pm
    #expect(draft.date == date(2026, 9, 30, 12, 45))
    draft.day = date(2026, 10, 1)
    #expect(draft.date == date(2026, 10, 1, 12, 45))
    draft.hour = "1"
    #expect(draft.date == date(2026, 10, 1, 13, 45))
  }

  @Test func twentyFourHourPreferencesDoNotDependOnTheAmPmSelection() {
    var draft = EndTimeDraft(date: date(2026, 9, 30, 23, 59), calendar: calendar, uses24HourClock: true)
    #expect(draft.hour == "23" && draft.date == date(2026, 9, 30, 23, 59))
    draft.period = .am
    #expect(draft.date == date(2026, 9, 30, 23, 59))
    draft.hour = "0"; draft.minute = "0"
    #expect(draft.date == date(2026, 9, 30, 0, 0))
  }

  @Test(arguments: ["", "0", "13", "-1", "123", "abc"])
  func invalidTwelveHourInputCannotRetainAConfirmableOldDate(input: String) {
    var draft = EndTimeDraft(date: date(2026, 9, 30), calendar: calendar, uses24HourClock: false)
    draft.hour = input
    #expect(draft.date == nil && draft.inputError == .hour)
  }

  @Test(arguments: ["", "60", "-1", "123", "abc"])
  func invalidMinutesCannotRetainAConfirmableOldDate(input: String) {
    var draft = EndTimeDraft(date: date(2026, 9, 30), calendar: calendar)
    draft.minute = input
    #expect(draft.date == nil && draft.inputError == .minute)
  }

  @Test func missingDaylightSavingTimeIsRejectedInsteadOfChangingTheDate() {
    var draft = EndTimeDraft(date: date(2026, 3, 8, 1), calendar: calendar, uses24HourClock: true)
    draft.hour = "2"; draft.minute = "30"
    #expect(draft.date == nil && draft.inputError == .unavailableTime)
    draft.hour = "3"
    #expect(draft.date == date(2026, 3, 8, 3, 30))
  }

  @Test func reopeningARepeatedHourKeepsTheExistingOccurrence() {
    let second = calendar.date(bySettingHour: 1, minute: 30, second: 0, of: date(2026, 11, 1),
                               matchingPolicy: .strict, repeatedTimePolicy: .last)!
    let draft = EndTimeDraft(date: second, calendar: calendar)
    #expect(draft.date == second)
  }

  @Test func localizedDigitsAndMinutePrecisionAreSupported() {
    var draft = EndTimeDraft(date: date(2026, 9, 30, 13, 10).addingTimeInterval(42), calendar: calendar,
                            uses24HourClock: true)
    draft.hour = "١٤"; draft.minute = "٢٥"
    #expect(draft.date == date(2026, 9, 30, 14, 25))
  }

  /// Confirming an unchanged dialog must not shorten the hold, and a deadline
  /// inside the current minute must not reopen already in the past.
  @Test func reopeningAnExistingDeadlineKeepsItsSeconds() {
    let existing = date(2026, 9, 30, 13, 10).addingTimeInterval(42)
    var draft = EndTimeDraft(date: existing, calendar: calendar, uses24HourClock: true)
    #expect(draft.date == existing)
    draft.minute = "11"
    #expect(draft.date == date(2026, 9, 30, 13, 11))
    draft.day = date(2026, 10, 1); draft.minute = "10"
    #expect(draft.date == date(2026, 10, 1, 13, 10))
  }

  /// The calendar here is en_US, so only the separate locale argument can
  /// produce the 24 hour result.
  @Test(arguments: [("en_US", false, "01"), ("de_DE", true, "13")])
  func theLocaleDecidesTheHourCycle(identifier: String, uses24: Bool, hour: String) {
    let draft = EndTimeDraft(date: date(2026, 9, 30, 13, 5), calendar: calendar,
                             locale: Locale(identifier: identifier))
    #expect(draft.uses24HourClock == uses24)
    #expect(draft.hour == hour)
    #expect(draft.period == .pm)
    #expect(draft.date == date(2026, 9, 30, 13, 5))
  }

  @Test func monthGridHonorsFirstWeekdayLeapYearsAndYearBoundaries() {
    let september = EndTimeCalendarMonth(containing: date(2026, 9, 30), calendar: calendar)
    #expect(september.days.prefix(2).allSatisfy { $0 == nil })
    #expect(september.days.compactMap { $0 }.count == 30)
    #expect(september.weekdaySymbols.first == "Sun")
    var mondayFirst = calendar; mondayFirst.firstWeekday = 2
    let monday = EndTimeCalendarMonth(containing: date(2026, 9, 30), calendar: mondayFirst)
    #expect(monday.days.first! == nil && monday.days[1] == date(2026, 9, 1, 0))
    #expect(monday.weekdaySymbols.first == "Mon")
    #expect(EndTimeCalendarMonth(containing: date(2028, 2, 10), calendar: calendar).days.compactMap { $0 }.count == 29)
    let january = EndTimeCalendarMonth(containing: date(2026, 12, 31), calendar: calendar).moving(by: 1)
    #expect(january.start == date(2027, 1, 1, 0))
    #expect(january.moving(by: -1).start == date(2026, 12, 1, 0))
  }

  /// The dialog's copy is English, so the date inside it must be too; only the
  /// clock follows the system's hour cycle.
  @Test func endTimeTextIsEnglishOnAGermanSystem() {
    var german = Calendar(identifier: .gregorian)
    german.timeZone = TimeZone(identifier: "Europe/Berlin")!
    german.locale = Locale(identifier: "de_DE")
    let deadline = german.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14))!
    let now = german.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9))!
    let text = EndTimeText.string(deadline, now: now, calendar: german, locale: Locale(identifier: "de_DE"))
    #expect(text.contains("Oct"))
    #expect(!text.contains("Okt"))
    #expect(text.contains("14:00"))
    #expect(!text.contains("PM"))
    let sameDay = EndTimeText.string(deadline, now: deadline.addingTimeInterval(-3_600),
                                     calendar: german, locale: Locale(identifier: "de_DE"))
    #expect(sameDay == "14:00")
  }

  /// The calendar popover's headers and spoken day names come from this
  /// calendar, so it carries English names and keeps the week's first day.
  @Test func englishCalendarKeepsTheFirstWeekday() {
    var german = Calendar(identifier: .gregorian)
    german.locale = Locale(identifier: "de_DE")
    german.firstWeekday = 2
    let english = EnglishDates.calendar(german, clockFrom: Locale(identifier: "de_DE"))
    #expect(english.firstWeekday == 2)
    let month = EndTimeCalendarMonth(containing: date(2026, 10, 3), calendar: english)
    #expect(month.weekdaySymbols.first == "Mon")
    #expect(english.monthSymbols[9] == "October")
    let header = date(2026, 10, 3).formatted(EnglishDates.style(calendar: english).month(.wide).year())
    #expect(header == "October 2026")
  }
}
