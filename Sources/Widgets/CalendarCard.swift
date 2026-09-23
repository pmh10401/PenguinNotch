import SwiftUI

struct CalendarMonth {
    let start: Date
    let days: [Date]
    let calendar: Calendar

    init(containing date: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        let start = calendar.dateInterval(of: .month, for: date)!.start
        self.start = start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        days = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }

    static func snapshot(now: Date = Date()) -> ProviderSnapshot {
        let date = now.formatted(Date.FormatStyle().month(.defaultDigits).day().locale(L10n.locale))
        return ProviderSnapshot(id: "widget-calendar", displayName: L10n.t("Calendar"), glyph: .calendar,
                                fidelity: .official, status: .ok,
                                windows: [LimitWindow(id: "date", label: L10n.t("Today"), usedText: date)],
                                kind: .calendar)
    }

    static func dayOffset(from now: Date, to date: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }

    static func isoDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Calendar-day distance from today. One day is singular; zero stays "Today".
    static func dayDistanceText(_ offset: Int) -> String {
        switch offset {
        case 0: return L10n.t("Today")
        case 1: return L10n.t("In 1 day")
        case -1: return L10n.t("1 day ago")
        case let day where day > 1: return L10n.t("In \(day) days")
        default: return L10n.t("\(-offset) days ago")
        }
    }

    static func yearProgressText(week: Int, daysLeft: Int) -> String {
        if daysLeft == 1 {
            return L10n.t("Week \(week) · 1 day left this year")
        }
        return L10n.t("Week \(week) · \(daysLeft) days left this year")
    }
}

struct CalendarCard: View {
    let now: Date
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var color: Color? = nil
    @State private var monthOffset = 0
    @State private var selectedDate: Date?
    @State private var copiedDate: String?
    @Environment(\.penguinnotchAccentColor) private var accent
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        let firstWeekday = calendar.firstWeekday
        calendar.locale = L10n.locale
        calendar.firstWeekday = firstWeekday
        return calendar
    }
    private var month: CalendarMonth {
        let start = calendar.dateInterval(of: .month, for: now)!.start
        return CalendarMonth(containing: calendar.date(byAdding: .month, value: monthOffset, to: start)!,
                             calendar: calendar)
    }

    var body: some View {
        let calendar = self.calendar
        let month = self.month
        let selectedDate = self.selectedDate ?? now
        let offset = CalendarMonth.dayOffset(from: now, to: selectedDate, calendar: calendar)
        let isoDate = CalendarMonth.isoDate(selectedDate, timeZone: calendar.timeZone)
        TooltipShell(height: NotchLayout.calendarCardHeight, direction: direction, tailOffset: tailOffset) {
            VStack(spacing: 8) {
                Text(now.formatted(Date.FormatStyle().weekday(.wide).month().day().locale(L10n.locale)))
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                HStack {
                    Text(month.start.formatted(Date.FormatStyle().year().month(.wide).locale(L10n.locale)))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel(L10n.t("Previous month"))
                    Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel(L10n.t("Next month"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(color ?? accent)
                Grid(horizontalSpacing: 1, verticalSpacing: 3) {
                    GridRow {
                        ForEach(0..<7, id: \.self) { index in
                            let weekday = (calendar.firstWeekday - 1 + index) % 7
                            Text(calendar.veryShortStandaloneWeekdaySymbols[weekday])
                                .font(.system(size: 10)).foregroundStyle(secondaryInk)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(calendar.weekdaySymbols[weekday])
                        }
                    }
                    ForEach(0..<6, id: \.self) { week in
                        GridRow {
                            ForEach(Array(month.days.dropFirst(week * 7).prefix(7)), id: \.self) { date in
                                let today = calendar.isDate(date, inSameDayAs: now)
                                let selected = calendar.isDate(date, inSameDayAs: selectedDate)
                                Button { self.selectedDate = date } label: {
                                    Text("\(calendar.component(.day, from: date))")
                                        .font(.system(size: 12, weight: today || selected ? .bold : .regular))
                                        .foregroundStyle(selected ? Color.white : Palette.textPrimary)
                                        .frame(maxWidth: .infinity).frame(height: 23)
                                        .background {
                                            if selected { Circle().fill(color ?? accent) }
                                            else if today { Circle().stroke(color ?? accent, lineWidth: 1) }
                                        }
                                }
                                .opacity(calendar.isDate(date, equalTo: month.start, toGranularity: .month) ? 1 : 0.35)
                                .accessibilityLabel(date.formatted(date: .complete, time: .omitted)
                                                    + (today ? ", " + L10n.t("Today") : ""))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                HStack {
                    Text(selectedDate.formatted(Date.FormatStyle().month().day().locale(L10n.locale)))
                    Spacer()
                    Text(CalendarMonth.dayDistanceText(offset))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                if let year = calendar.dateInterval(of: .year, for: now) {
                    let remaining = max(0, CalendarMonth.dayOffset(from: now, to: year.end, calendar: calendar) - 1)
                    Text(CalendarMonth.yearProgressText(week: calendar.component(.weekOfYear, from: now),
                                                        daysLeft: remaining))
                        .font(.system(size: 10)).foregroundStyle(secondaryInk)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                HStack {
                    Button(L10n.t("Today")) { monthOffset = 0; self.selectedDate = nil }
                    Spacer()
                    Button(copiedDate == isoDate ? L10n.t("Copied") : L10n.t("Copy date")) {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(isoDate, forType: .string) { copiedDate = isoDate }
                    }
                    .help(isoDate)
                    Spacer()
                    Button(L10n.t("Open Calendar")) {
                        NSWorkspace.shared.open(URL(string: "ical://")!)
                    }
                }
                .font(.system(size: 11)).buttonStyle(.plain)
                .foregroundStyle(color ?? accent)
            }
        }
    }
}
