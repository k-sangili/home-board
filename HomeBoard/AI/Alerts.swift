import BoardCore
import Foundation

struct BoardAlert: Identifiable, Hashable {
    enum Severity: String, Codable { case urgent, headsUp = "heads_up" }

    var id: String { title }
    let severity: Severity
    let title: String
    let detail: String
    let symbol: String
}

/// Alerts the board raises on its own, without waiting on the network: doors and the garage
/// left open, and missing schoolwork. Claude adds anything else worth flagging.
@MainActor
enum AlertRules {
    static func alerts(home: HomeStore, school: [BoardItem], now: Date, schedule: Schedule = Schedule()) -> [BoardAlert] {
        var alerts: [BoardAlert] = []
        let hour = schedule.calendar.component(.hour, from: now)
        let isNight = hour >= 21 || hour < 6

        for door in home.doors {
            let minutes = home.insecureSince[door.id].map { Int(now.timeIntervalSince($0) / 60) } ?? 0
            let duration = minutes >= 1 ? " for \(minutes) min" : ""
            switch door.security {
            case .jammed:
                alerts.append(.init(severity: .urgent, title: "\(door.name) is jammed", detail: "Check the lock", symbol: "lock.trianglebadge.exclamationmark.fill"))
            case .open where door.kind == .garage:
                alerts.append(.init(severity: isNight || minutes >= 15 ? .urgent : .headsUp,
                                    title: "\(door.name) open\(duration)", detail: "Close it from the Home panel",
                                    symbol: "door.garage.open"))
            case .open where isNight || minutes >= 60:
                alerts.append(.init(severity: isNight ? .urgent : .headsUp,
                                    title: "\(door.name) unlocked\(duration)", detail: "Lock it from the Home panel",
                                    symbol: "lock.open.fill"))
            default:
                if !door.isReachable {
                    alerts.append(.init(severity: .headsUp, title: "Can't reach \(door.name)", detail: "Its state may be out of date",
                                        symbol: "wifi.exclamationmark"))
                }
            }
        }

        let cutoff = schedule.day(-30, from: now)
        let missing = school.filter { $0.isMissing && $0.start >= cutoff }
        for (kid, items) in Dictionary(grouping: missing, by: { $0.kid ?? "School" }).sorted(by: { $0.key < $1.key }) {
            let titles = items.map { [$0.course, $0.title].compactMap { $0 }.joined(separator: ": ") }
            alerts.append(.init(severity: .headsUp,
                                title: "\(kid): \(items.count) missing assignment\(items.count == 1 ? "" : "s")",
                                detail: titles.joined(separator: " · "), symbol: "exclamationmark.triangle.fill"))
        }
        return alerts.sorted { ($0.severity == .urgent ? 0 : 1) < ($1.severity == .urgent ? 0 : 1) }
    }
}
