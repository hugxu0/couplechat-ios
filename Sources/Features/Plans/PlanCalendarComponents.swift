import SwiftUI

struct PlanCalendarView: View {
    @Binding var selectedDate: Date
    @Binding var monthMode: Bool
    let events: [CalendarEvent]
    let onMoveMonth: (Int) -> Void
    let onEdit: (CalendarEvent) -> Void
    let onToggle: (CalendarEvent) -> Void
    let onDelete: (CalendarEvent) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: DS.Spacing.section) {
                calendarPanel.frame(maxWidth: 390)
                agendaPanel.frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.section) {
                calendarPanel
                agendaPanel
            }
        }
    }

    private var calendarPanel: some View {
        VStack(spacing: DS.Spacing.gap) {
            HStack {
                Button { onMoveMonth(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("上个月")
                Spacer()
                Button { monthMode.toggle() } label: {
                    VStack(spacing: 1) {
                        Text(selectedDate.monthTitle)
                            .font(DS.Typo.cardTitle)
                        Text(monthMode ? "收起月历" : "展开月历")
                            .font(DS.Typo.micro)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onMoveMonth(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .accessibilityLabel("下个月")
            }
            .foregroundStyle(DS.Palette.textPrimary)

            weekdayHeader
            if monthMode { monthGrid } else { weekStrip }
        }
        .padding(DS.Spacing.card)
        .dsCard()
    }

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { value in
                Text(value)
                    .font(DS.Typo.micro.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var weekStrip: some View {
        HStack(spacing: 2) {
            ForEach(selectedDate.weekDates, id: \.self) { date in
                dateButton(date, dimsOtherMonth: false)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
            ForEach(selectedDate.monthGridDates, id: \.self) { date in
                dateButton(date, dimsOtherMonth: !Calendar.current.isDate(date, equalTo: selectedDate, toGranularity: .month))
            }
        }
    }

    private func dateButton(_ date: Date, dimsOtherMonth: Bool) -> some View {
        let selected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let today = Calendar.current.isDateInToday(date)
        let dateEvents = events
            .filter { Calendar.current.isDate($0.startDate, inSameDayAs: date) }
            .sorted { $0.startAt < $1.startAt }
        let hasEvent = !dateEvents.isEmpty
        let annotation = today
            ? (dateEvents.first.map { "今天 · \($0.title)" } ?? "今天")
            : (dateEvents.first?.title ?? " ")
        return Button {
            selectedDate = date
            Haptics.selection()
        } label: {
            VStack(spacing: 2) {
                Text(date.dayNumber)
                    .font(DS.Typo.secondary.monospacedDigit().weight(selected ? .bold : .medium))
                Text(annotation)
                    .font(DS.Typo.micro.weight(today ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .foregroundStyle(selected
                        ? Color.white.opacity(0.9)
                        : (today ? DS.Palette.purple : (hasEvent ? DS.Palette.textSecondary : .clear)))
            }
            .foregroundStyle(selected ? .white : DS.Palette.textPrimary.opacity(dimsOtherMonth ? 0.34 : 1))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? DS.Palette.purple : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if today && !selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Palette.purple.opacity(0.48), lineWidth: 1.2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.accessibleDateLabel + (today ? "，今天" : "") + (hasEvent ? "，日程：\(dateEvents[0].title)" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var agendaPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            Text("当天安排")
                .font(DS.Typo.sectionLabel)
                .foregroundStyle(DS.Palette.textSecondary)
            if selectedEvents.isEmpty {
                AppEmptyState("这一天还没有安排", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(selectedEvents) { event in
                    CalendarAgendaRow(
                        event: event,
                        onEdit: { onEdit(event) },
                        onToggle: { onToggle(event) },
                        onDelete: { onDelete(event) })
                }
            }
        }
    }

    private var selectedEvents: [CalendarEvent] {
        events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: selectedDate) }
            .sorted { $0.startAt < $1.startAt }
    }
}

private struct CalendarAgendaRow: View {
    let event: CalendarEvent
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.gap) {
            Button(action: onToggle) {
                Image(systemName: event.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(event.isDone ? DS.Palette.green : DS.Palette.purple)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(event.isDone ? "标记未完成" : "标记完成")
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(DS.Typo.cardTitle)
                    .strikethrough(event.isDone)
                    .foregroundStyle(event.isDone ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                Text(event.timeLabel)
                    .font(DS.Typo.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Menu {
                Button("编辑", systemImage: "pencil", action: onEdit)
                Button(event.isDone ? "标记未完成" : "标记完成", systemImage: "checkmark.circle", action: onToggle)
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(DS.Spacing.gap)
        .dsCard(radius: DS.Radius.tile)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile))
        .onTapGesture(perform: onEdit)
        .opacity(event.isDone ? 0.68 : 1)
    }
}

private extension Date {
    var monthTitle: String { formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))) }
    var dayNumber: String { formatted(.dateTime.day()) }
    var accessibleDateLabel: String { formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))) }

    var weekDates: [Date] {
        let calendar = Calendar.mondayFirst
        let start = calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? self
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var monthGridDates: [Date] {
        let calendar = Calendar.mondayFirst
        let startOfMonth = calendar.dateInterval(of: .month, for: self)?.start ?? self
        let start = calendar.dateInterval(of: .weekOfYear, for: startOfMonth)?.start ?? startOfMonth
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

private extension Calendar {
    static var mondayFirst: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }
}

private extension CalendarEvent {
    var timeLabel: String {
        if isAllDay { return "全天" }
        let start = startDate.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
        guard let endDate else { return start }
        let end = endDate.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
        return "\(start) – \(end)"
    }
}
