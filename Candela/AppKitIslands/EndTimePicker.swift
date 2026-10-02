import AppKit
import CandelaKit
import SwiftUI

/// One dialog shared by Keep Awake and per-display dimming pauses.
@MainActor
final class EndTimePicker: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var selection: EndTimeSelection?
  private var presentation = 0

  func present(title: String, detail: String, actionTitle: String,
               currentDeadline: Date?, apply: @escaping (Date) -> String?) {
    dismiss()
    let token = presentation
    PanelMenu.endTracking()
    // End status-menu tracking before asking a window to take focus.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.presentation == token else { return }
      let selection = EndTimeSelection(currentDeadline: currentDeadline, apply: apply)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = title
      window.appearance = NSAppearance(named: .darkAqua)
      window.titlebarAppearsTransparent = true
      window.backgroundColor = NSColor(srgbRed: 0.035, green: 0.035, blue: 0.06, alpha: 1)
      window.isRestorable = false
      window.isReleasedWhenClosed = false
      window.delegate = self
      let content = NSHostingView(rootView: EndTimePickerView(
        selection: selection, detail: detail, actionTitle: actionTitle,
        cancel: { [weak self] in self?.dismiss() },
        confirm: { [weak self] in
          if selection.confirm() { self?.dismiss() }
        }))
      window.contentView = content
      window.setContentSize(content.fittingSize)
      self.selection = selection
      self.window = window
      window.center()
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }

  func dismiss() {
    presentation += 1
    selection?.cancel()
    selection = nil
    window?.close()
    window = nil
  }

  func windowWillClose(_ notification: Notification) {
    selection?.cancel()
    selection = nil
    window = nil
    presentation += 1
  }
}

struct EndTimePickerView: View {
  @Bindable var selection: EndTimeSelection
  let detail: String
  let actionTitle: String
  let cancel: () -> Void
  let confirm: () -> Void

  @State private var draft: EndTimeDraft
  @State private var showsCalendar = false
  @State private var dateHovered = false
  @State private var clock = Date()
  @FocusState private var focusedField: Field?
  private enum Field { case hour, minute }
  private let accent = SettingsAccent.display(isBuiltIn: false, ordinal: 0)

  init(selection: EndTimeSelection, detail: String, actionTitle: String,
       cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
    self.selection = selection
    self.detail = detail
    self.actionTitle = actionTitle
    self.cancel = cancel
    self.confirm = confirm
    _draft = State(initialValue: EndTimeDraft(date: selection.deadline, calendar: EnglishDates.calendar()))
  }

  var body: some View {
    // Read unconditionally so the tick re-validates even while an error shows.
    let _ = clock
    VStack(alignment: .leading, spacing: 20) {
      Text(detail)
        .font(.callout)
        .foregroundStyle(SettingsTheme.bodyColor)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          fieldLabel("Date")
          Button { showsCalendar.toggle() } label: {
            HStack(spacing: 12) {
              Text(draft.day.formatted(EnglishDates.style(date: .long, calendar: draft.calendar)))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SettingsTheme.titleColor)
              Spacer(minLength: 8)
              Image(systemName: "calendar")
                .font(.system(size: 15))
                .foregroundStyle(SettingsTheme.bodyColor)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 6)
              .fill(Color.white.opacity(dateHovered ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SettingsTheme.cardStroke, lineWidth: 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { dateHovered = $0 }
          .accessibilityLabel("End date")
          .accessibilityValue(draft.day.formatted(EnglishDates.style(date: .complete, calendar: draft.calendar)))
          .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
            EndTimeCalendarView(day: $draft.day, calendar: draft.calendar) { showsCalendar = false }
              .environment(\.settingsAccent, accent)
              .environment(\.colorScheme, .dark)
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          fieldLabel("Time")
          HStack(spacing: 8) {
            timeField("Hour", text: $draft.hour, field: .hour)
            Text(":").font(.system(size: 20)).foregroundStyle(SettingsTheme.bodyColor)
              .accessibilityHidden(true)
            timeField("Minute", text: $draft.minute, field: .minute)
            if !draft.uses24HourClock {
              periodControl.padding(.leading, 8)
            }
            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius).fill(SettingsTheme.cardFill))
      .overlay(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius).stroke(SettingsTheme.cardStroke, lineWidth: 1))
      VStack(alignment: .leading, spacing: 16) {
        Text(validationMessage ?? "Ends \(EndTimeText.string(draft.date ?? selection.deadline, now: clock, calendar: draft.calendar))")
          .font(.callout)
          .foregroundStyle(validationMessage == nil ? SettingsTheme.bodyColor : SettingsTheme.dangerTint)
          .fixedSize(horizontal: false, vertical: true)
          .frame(height: 36, alignment: .topLeading)
        HStack(spacing: 10) {
          Spacer()
          Button("Cancel", action: cancel)
            .buttonStyle(SettingsSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
          Button(actionTitle, action: confirmDraft)
            .buttonStyle(SettingsPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirmDraft)
        }
      }
    }
    // Not a TimelineView: in a key window one costs a full window layout every
    // display cycle whatever its schedule [MEASURED 2026-10-01]. A chosen time
    // passing while the dialog is open still has to grey the action.
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        clock = Date()
      }
    }
    .padding(24)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
    .background(Color(red: 0.035, green: 0.035, blue: 0.06))
    .environment(\.settingsAccent, accent)
    .environment(\.colorScheme, .dark)
    .onChange(of: draft) { _, value in
      if let date = value.date { selection.deadline = date }
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text).font(.callout.weight(.medium)).foregroundStyle(SettingsTheme.titleColor)
  }

  private func timeField(_ title: String, text: Binding<String>, field: Field) -> some View {
    TextField(title, text: text)
      .textFieldStyle(.plain)
      .font(.system(size: 20, weight: .medium).monospacedDigit())
      .multilineTextAlignment(.center)
      .foregroundStyle(SettingsTheme.titleColor)
      .frame(width: 64, height: 44)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
      .overlay(RoundedRectangle(cornerRadius: 6)
        .stroke(focusedField == field ? accent.accent : SettingsTheme.cardStroke,
                lineWidth: focusedField == field ? 2 : 1))
      .focused($focusedField, equals: field)
      .accessibilityLabel("End time \(title.lowercased())")
  }

  private var periodControl: some View {
    HStack(spacing: 2) {
      ForEach(EndTimeDraft.Period.allCases, id: \.self) { period in
        let selected = draft.period == period
        Button { draft.period = period } label: {
          Text(periodSymbol(period))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Color.white : SettingsTheme.bodyColor)
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 4)
              .fill(selected ? accent.accent.opacity(0.75) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(periodSymbol(period))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
      }
    }
    .padding(3)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(SettingsTheme.cardStroke, lineWidth: 1))
  }

  // English only, like every other label; the locale decides only whether the
  // control is shown at all.
  private func periodSymbol(_ period: EndTimeDraft.Period) -> String {
    period == .am ? "AM" : "PM"
  }

  private var validationMessage: String? {
    switch draft.inputError {
    case .hour: return draft.uses24HourClock ? "Enter an hour from 0 to 23." : "Enter an hour from 1 to 12."
    case .minute: return "Enter minutes from 0 to 59."
    case .unavailableTime: return "That time isn't available on this date. Choose another time."
    case nil: break
    }
    if let error = selection.errorMessage { return error }
    return canConfirmDraft ? nil : "Choose a future time within the next year."
  }

  private var canConfirmDraft: Bool {
    draft.date.map { selection.canConfirm(deadline: $0) } ?? false
  }

  private func confirmDraft() {
    guard let date = draft.date else { return }
    selection.deadline = date
    guard selection.canConfirm else { return }
    confirm()
  }
}

struct EndTimeCalendarView: View {
  @Binding var day: Date
  let calendar: Calendar
  let selected: () -> Void
  @State private var visibleMonth: Date
  @State private var focusedDay: Date?
  @FocusState private var hasKeyboardFocus: Bool
  @Environment(\.settingsAccent) private var accent
  private let today: Date
  private let lastDay: Date

  init(day: Binding<Date>, calendar: Calendar, now: Date = Date(), selected: @escaping () -> Void) {
    _day = day
    self.calendar = calendar
    self.selected = selected
    self.today = calendar.startOfDay(for: now)
    self.lastDay = calendar.startOfDay(for: now.addingTimeInterval(TimedControlDeadline.maximumInterval))
    _visibleMonth = State(initialValue: EndTimeCalendarMonth(containing: day.wrappedValue, calendar: calendar).start)
  }

  private var month: EndTimeCalendarMonth { EndTimeCalendarMonth(containing: visibleMonth, calendar: calendar) }

  var body: some View {
    VStack(spacing: 16) {
      HStack {
        Text(visibleMonth.formatted(EnglishDates.style(calendar: calendar).month(.wide).year()))
          .font(.system(size: 14, weight: .semibold)).foregroundStyle(SettingsTheme.titleColor)
        Spacer()
        monthButton("Previous month", symbol: "chevron.left", direction: -1)
        monthButton("Next month", symbol: "chevron.right", direction: 1)
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
        ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsTheme.bodyColor)
            .frame(height: 24).accessibilityHidden(true)
        }
        ForEach(Array(month.days.enumerated()), id: \.offset) { _, date in
          if let date { dayButton(date) }
          else { Color.clear.frame(height: 36).accessibilityHidden(true) }
        }
      }
    }
    .padding(16)
    .frame(width: 320)
    .background(Color(red: 0.035, green: 0.035, blue: 0.06))
    .focusable()
    .focusEffectDisabled()
    .focused($hasKeyboardFocus)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Choose end date")
    .onAppear {
      focusedDay = day >= today && day <= lastDay ? calendar.startOfDay(for: day) : today
      hasKeyboardFocus = true
    }
    .onKeyPress(.return) { chooseFocusedDay(); return .handled }
    .onKeyPress(.space) { chooseFocusedDay(); return .handled }
    .onMoveCommand { direction in
      let offset: Int
      switch direction {
      case .left: offset = -1
      case .right: offset = 1
      case .up: offset = -7
      case .down: offset = 7
      @unknown default: return
      }
      guard let next = calendar.date(byAdding: .day, value: offset, to: focusedDay ?? day),
            next >= today, next <= lastDay else { return }
      visibleMonth = EndTimeCalendarMonth(containing: next, calendar: calendar).start
      focusedDay = next
    }
  }

  private func monthButton(_ label: String, symbol: String, direction: Int) -> some View {
    let next = month.moving(by: direction).start
    let first = EndTimeCalendarMonth(containing: today, calendar: calendar).start
    let last = EndTimeCalendarMonth(containing: lastDay, calendar: calendar).start
    return Button {
      visibleMonth = next
      focusedDay = max(next, today)
      hasKeyboardFocus = true
    } label: {
      Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        .settingsText(SettingsTheme.bodyColor)
        .frame(width: 30, height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
    }
    .buttonStyle(.plain)
    .disabled(next < first || next > last)
    .accessibilityLabel(label)
  }

  private func chooseFocusedDay() {
    guard let date = focusedDay, date >= today, date <= lastDay else { return }
    day = date
    selected()
  }

  private func dayButton(_ date: Date) -> some View {
    let isSelected = calendar.isDate(date, inSameDayAs: day)
    let isToday = calendar.isDate(date, inSameDayAs: today)
    return Button { day = date; selected() } label: {
      Text("\(calendar.component(.day, from: date))")
        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
        .settingsText(isSelected ? .white : SettingsTheme.titleColor)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? accent.accent.opacity(0.75) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5)
          .stroke(focusedDay == date ? accent.accent : (isToday && !isSelected ? accent.accent.opacity(0.7) : .clear),
                  lineWidth: focusedDay == date ? 2 : 1))
    }
    .buttonStyle(.plain)
    .disabled(date < today || date > lastDay)
    .accessibilityLabel(date.formatted(EnglishDates.style(date: .complete, calendar: calendar)))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
