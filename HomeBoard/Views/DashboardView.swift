import BoardCore
import SwiftUI

/// The Home tab: clock and weather, Claude's briefing with alerts, then weather, school and
/// house panels side by side.
struct DashboardView: View {
    @Environment(BoardStore.self) private var school
    @Environment(HomeStore.self) private var home
    @Environment(WeatherStore.self) private var weather
    @Environment(Assistant.self) private var assistant
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DashHeader(now: now)
            BriefingCard(alerts: AlertRules.alerts(home: home, school: school.items, now: now) + assistant.alerts)
            HStack(alignment: .top, spacing: 24) {
                WeatherPanel(now: now).frame(width: 470)
                SchoolPanel(now: now)
                HomePanel(now: now).frame(width: 660)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            DashFooter()
        }
    }
}

// MARK: - Header

private struct DashHeader: View {
    @Environment(WeatherStore.self) private var weather
    let now: Date

    var body: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide)))
                    .font(Theme.font(28, .semibold))
                    .foregroundStyle(Theme.today)
                Text(now.formatted(.dateTime.month(.wide).day()))
                    .font(Theme.font(56, .bold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            if let current = weather.now {
                HStack(spacing: 16) {
                    Image(systemName: WeatherCode.symbol(current.code, isDay: current.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 54))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(current.temperature.rounded()))°")
                            .font(Theme.font(56, .bold))
                            .foregroundStyle(Theme.text)
                        Text("\(WeatherCode.description(current.code)) · feels \(Int(current.feelsLike.rounded()))°")
                            .font(Theme.font(20, .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.trailing, 24)
            }
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(Theme.font(56, .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
    }
}

// MARK: - Briefing

private struct BriefingCard: View {
    @Environment(Assistant.self) private var assistant
    let alerts: [BoardAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.today)
                    .padding(.top, 4)
                Text(text)
                    .font(Theme.font(30, .semibold))
                    .foregroundStyle(assistant.briefing == nil ? Theme.secondary : Theme.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !alerts.isEmpty {
                HStack(spacing: 14) {
                    ForEach(alerts.prefix(4)) { AlertChip(alert: $0) }
                    if alerts.count > 4 {
                        Text("+\(alerts.count - 4) more").font(Theme.font(20, .semibold)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Theme.panel))
    }

    private var text: String {
        if let briefing = assistant.briefing { return briefing }
        if !assistant.isConfigured { return "Add an Anthropic API key to HomeConfig.json for a daily briefing." }
        if let problem = assistant.problem { return problem }
        return "Writing today's briefing…"
    }
}

private struct AlertChip: View {
    let alert: BoardAlert

    private var color: Color { alert.severity == .urgent ? Theme.test : Theme.deadline }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(alert.title)
                    .font(Theme.font(20, .bold))
                    .foregroundStyle(Theme.text)
                Text(alert.detail)
                    .font(Theme.font(16, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
        }
        .font(Theme.font(22, .bold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(alert.severity == .urgent ? 0.9 : 0), lineWidth: 2))
    }
}

// MARK: - Panels

struct PanelTitle: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(Theme.font(22, .heavy))
            .foregroundStyle(Theme.secondary)
    }
}

private struct WeatherPanel: View {
    @Environment(WeatherStore.self) private var weather
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(text: "Weather", symbol: "cloud.sun.fill")
            if weather.days.isEmpty {
                Text(weather.problem ?? "Loading…")
                    .font(Theme.font(20, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 0) {
                ForEach(weather.upcomingHours(6, from: now)) { hour in
                    VStack(spacing: 8) {
                        Text(hour.time.formatted(.dateTime.hour()))
                            .font(Theme.font(17, .semibold))
                            .foregroundStyle(Theme.secondary)
                        Image(systemName: WeatherCode.symbol(hour.code))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 28))
                            .frame(height: 32)
                        Text("\(Int(hour.temperature.rounded()))°")
                            .font(Theme.font(22, .bold))
                            .foregroundStyle(Theme.text)
                        Text(hour.precipitation >= 10 ? "\(hour.precipitation)%" : " ")
                            .font(Theme.font(15, .bold))
                            .foregroundStyle(Color(hex: "#6CB6FF"))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 10) {
                let low = weather.days.prefix(5).map(\.low).min() ?? 0
                let high = weather.days.prefix(5).map(\.high).max() ?? 1
                ForEach(weather.days.prefix(5)) { day in
                    DayRow(day: day, isToday: Calendar.current.isDate(day.date, inSameDayAs: now), range: low...max(high, low + 1))
                }
            }
            if let today = weather.days.first {
                HStack(spacing: 20) {
                    Label(today.sunrise.formatted(date: .omitted, time: .shortened), systemImage: "sunrise.fill")
                    Label(today.sunset.formatted(date: .omitted, time: .shortened), systemImage: "sunset.fill")
                }
                .font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .panelStyle()
    }
}

private struct DayRow: View {
    let day: WeatherStore.Day
    let isToday: Bool
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 12) {
            Text(isToday ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                .font(Theme.font(20, .bold))
                .foregroundStyle(isToday ? Theme.today : Theme.text)
                .frame(width: 70, alignment: .leading)
            Image(systemName: WeatherCode.symbol(day.code))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(width: 34)
            Text(day.precipitation >= 20 ? "\(day.precipitation)%" : "")
                .font(Theme.font(15, .bold))
                .foregroundStyle(Color(hex: "#6CB6FF"))
                .frame(width: 46, alignment: .leading)
            Text("\(Int(day.low.rounded()))°")
                .font(Theme.font(19, .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, alignment: .trailing)
            GeometryReader { geo in
                let span = range.upperBound - range.lowerBound
                let start = (day.low - range.lowerBound) / span * geo.size.width
                let width = max((day.high - day.low) / span * geo.size.width, 8)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: "#6CB6FF"), Theme.today], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width)
                        .offset(x: start)
                }
            }
            .frame(height: 8)
            Text("\(Int(day.high.rounded()))°")
                .font(Theme.font(19, .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, alignment: .leading)
        }
    }
}

/// Today's school items for each kid (tomorrow's after 3 pm), with missing work first.
private struct SchoolPanel: View {
    @Environment(BoardStore.self) private var school
    let now: Date
    private let schedule = Schedule()

    private var showsTomorrow: Bool { schedule.calendar.component(.hour, from: now) >= 15 }

    var body: some View {
        let day = schedule.day(showsTomorrow ? 1 : 0, from: schedule.calendar.startOfDay(for: now))
        let items = schedule.items(on: day, from: school.items).filter { !$0.isMissing }
        let noSchool = items.first { $0.kind == .noSchool }
        let visible = items.filter { $0.kind != .noSchool }

        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(text: showsTomorrow ? "School Tomorrow" : "School Today", symbol: "graduationcap.fill")
            if let noSchool {
                Label(noSchool.title, systemImage: "sun.max.fill")
                    .font(Theme.font(22, .bold))
                    .foregroundStyle(Theme.noSchool)
            }
            if visible.isEmpty && noSchool == nil {
                Text("Nothing scheduled")
                    .font(Theme.font(22, .medium))
                    .foregroundStyle(Theme.secondary.opacity(0.7))
            }
            ForEach(visible.prefix(4)) { ItemCard(item: $0) }
            if visible.count > 4 {
                Text("+\(visible.count - 4) more on the School tab")
                    .font(Theme.font(18, .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .panelStyle()
    }
}

private struct DashFooter: View {
    @Environment(BoardStore.self) private var school
    @Environment(HomeStore.self) private var home
    @Environment(WeatherStore.self) private var weather
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(spacing: 20) {
            if Launch.isDemo {
                Text("DEMO DATA").font(Theme.font(16, .heavy)).foregroundStyle(Theme.deadline)
            }
            if let problem = weather.problem ?? school.problems.first {
                Label(problem, systemImage: "wifi.exclamationmark")
                    .lineLimit(1)
                    .foregroundStyle(Theme.deadline)
            } else if let time = assistant.briefingTime {
                Text("Briefing \(time.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Text("Weather: Open-Meteo")
            Text("Menu: tabs")
        }
        .font(Theme.font(16, .medium))
        .foregroundStyle(Theme.secondary)
    }
}

extension View {
    func panelStyle() -> some View {
        padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 24).fill(Theme.panel))
    }
}
