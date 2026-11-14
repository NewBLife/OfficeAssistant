import SwiftUI
import OfficeCore

@MainActor struct TaskCalendarView: View {
    let items: [TaskItem]
    let store: TaskStore
    let now: Date
    let displayTimeZoneID: String
    let locale: Locale
    let groups: GroupStore?
    let openMeeting: ((UUID, EvidenceReference?) -> Void)?
    let edit: (TaskItem) -> Void

    @State private var displayedMonth: Date
    @State private var selectedDay: Date

    init(items: [TaskItem], store: TaskStore, now: Date, displayTimeZoneID: String,
         locale: Locale, groups: GroupStore?, openMeeting: ((UUID, EvidenceReference?) -> Void)?,
         edit: @escaping (TaskItem) -> Void) {
        self.items = items; self.store = store; self.now = now
        self.displayTimeZoneID = displayTimeZoneID; self.locale = locale
        self.groups = groups; self.openMeeting = openMeeting; self.edit = edit
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: displayTimeZoneID) ?? .current
        _displayedMonth = State(initialValue: calendar.dateInterval(of: .month, for: now)?.start ?? now)
        _selectedDay = State(initialValue: calendar.startOfDay(for: now))
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: displayTimeZoneID) ?? .current
        result.locale = locale
        result.firstWeekday = Calendar.current.firstWeekday
        return result
    }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth }
    private var firstOffset: Int { (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7 }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0 }
    private var selectedItems: [TaskItem] {
        items.filter { TaskRules.isDue($0, on: selectedDay, displayTimeZoneID: displayTimeZoneID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 12) {
                HStack {
                    Text(format(monthStart, template: "yMMMM"))
                        .font(.title3.bold())
                    Spacer()
                    Button("今天") { jumpToToday() }
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上个月")
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("下个月")
                }
                let weekdays = calendar.veryShortStandaloneWeekdaySymbols
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<7, id: \.self) { offset in
                        Text(weekdays[(calendar.firstWeekday - 1 + offset) % 7])
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<(firstOffset + dayCount), id: \.self) { index in
                        if index < firstOffset {
                            Color.clear.frame(height: 58)
                        } else if let day = calendar.date(byAdding: .day, value: index - firstOffset, to: monthStart) {
                            dayCell(day)
                        }
                    }
                }
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))

            Text(format(selectedDay, template: "yMMMMdEEEE"))
                .font(.headline)
            if selectedItems.isEmpty {
                ContentUnavailableView("当天没有待办", systemImage: "calendar", description: Text("选择其他日期，查看已安排的事项。"))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                TaskListView(items: selectedItems, store: store, now: now,
                             openMeeting: openMeeting, groups: groups, edit: edit)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let count = items.filter { TaskRules.isDue($0, on: day, displayTimeZoneID: displayTimeZoneID) }.count
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        return Button { selectedDay = day } label: {
            VStack(spacing: 5) {
                Text("\(calendar.component(.day, from: day))").fontWeight(isSelected ? .bold : .regular)
                if count > 0 {
                    Text("\(count) 项").font(.caption2)
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                } else { Text(" ").font(.caption2) }
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isSelected ? Color.accentColor : Color.accentColor.opacity(count > 0 ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(format(day, template: "yMMMMd"))，\(count) 项待办")
    }

    private func moveMonth(_ amount: Int) {
        guard let month = calendar.date(byAdding: .month, value: amount, to: monthStart) else { return }
        displayedMonth = month
        selectedDay = month
    }

    private func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
        return formatter.string(from: date)
    }

    private func jumpToToday() {
        displayedMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        selectedDay = calendar.startOfDay(for: now)
    }
}
