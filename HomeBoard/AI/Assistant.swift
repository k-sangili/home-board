import BoardCore
import Foundation
import Observation

/// What Claude sees: a compact, readable snapshot of weather, school and the house.
struct BoardContext: Encodable {
    struct Weather: Encodable {
        var now: String
        var nextHours: [String]
        var nextDays: [String]
    }
    struct School: Encodable {
        var missing: [String]
        var today: [String]
        var tomorrow: [String]
        var laterThisWeek: [String]
    }
    struct Home: Encodable {
        var doors: [String]
        var climate: [String]
        var lightsOn: [String]
        var scenes: [String]
        var cameras: [String]
    }

    var now: String
    var location: String
    var weather: Weather?
    var school: School
    var home: Home?
    var alertsAlreadyShown: [String]

    @MainActor
    static func build(now: Date, weather: WeatherStore, school: BoardStore, home: HomeStore, alerts: [BoardAlert]) -> BoardContext {
        let schedule = Schedule()
        let unit = "°\(weather.unitSymbol)"

        func describe(_ item: BoardItem) -> String {
            var text = [item.kid, item.course].compactMap { $0 }.joined(separator: " ")
            switch item.kind {
            case .test: text += " TEST"
            case .homework: text += " homework"
            case .deadline: text += " DUE"
            case .noSchool: text += " NO SCHOOL"
            default: break
            }
            text += ": \(item.title)"
            if !item.isAllDay { text += " at \(item.start.formatted(date: .omitted, time: .shortened))" }
            return text
        }
        func items(_ offset: Int) -> [BoardItem] {
            schedule.items(on: schedule.day(offset, from: now), from: school.items).filter { !$0.isMissing }
        }

        let cutoff = schedule.day(-30, from: now)
        let schoolContext = School(
            missing: school.items.filter { $0.isMissing && $0.start >= cutoff }
                .map { describe($0) + " (was due \($0.start.formatted(.dateTime.weekday().month().day())))" },
            today: items(0).map(describe),
            tomorrow: items(1).map(describe),
            laterThisWeek: (2..<7).flatMap { offset in
                items(offset).map { "\(schedule.day(offset, from: now).formatted(.dateTime.weekday(.wide))): \(describe($0))" }
            }
        )

        var weatherContext: Weather?
        if let current = weather.now {
            weatherContext = Weather(
                now: "\(Int(current.temperature.rounded()))\(unit), \(WeatherCode.description(current.code)), feels like \(Int(current.feelsLike.rounded()))\(unit)",
                nextHours: weather.upcomingHours(12, from: now).map {
                    "\($0.time.formatted(.dateTime.hour())): \(Int($0.temperature.rounded()))\(unit), \(WeatherCode.description($0.code)), \($0.precipitation)% rain"
                },
                nextDays: weather.days.prefix(5).map {
                    "\($0.date.formatted(.dateTime.weekday(.wide))): \(WeatherCode.description($0.code)), \(Int($0.low.rounded()))–\(Int($0.high.rounded()))\(unit), \($0.precipitation)% rain"
                }
            )
        }

        var homeContext: Home?
        if home.status == .ready || home.status == .demo {
            func state(_ door: HomeDevice) -> String {
                let open = door.kind == .garage ? "open" : "unlocked"
                let closed = door.kind == .garage ? "closed" : "locked"
                switch door.security {
                case .secure: return closed
                case .open:
                    let minutes = home.insecureSince[door.id].map { Int(now.timeIntervalSince($0) / 60) } ?? 0
                    return minutes > 0 ? "\(open) for \(minutes) min" : open
                case .moving: return "moving"
                case .jammed: return "jammed"
                default: return "unknown"
                }
            }
            homeContext = Home(
                doors: home.doors.map { "\($0.name): \(state($0))\($0.isReachable ? "" : " (unreachable)")" },
                climate: home.climate.map { device in
                    var text = "\(device.name)"
                    if let t = device.temperature { text += " \(degrees(t, home.config))" }
                    if let target = device.target { text += ", set to \(degrees(target, home.config))" }
                    if let activity = device.activity { text += ", \(activity.lowercased())" }
                    return text
                },
                lightsOn: home.lights.filter { $0.isOn == true }.map(\.name),
                scenes: home.scenes.map(\.name),
                cameras: home.cameras.map(\.name)
            )
        }

        return BoardContext(
            now: now.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
            location: weather.config.location.name,
            weather: weatherContext,
            school: schoolContext,
            home: homeContext,
            alertsAlreadyShown: alerts.map(\.title)
        )
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// The Claude side of the board: the briefing at the top of the dashboard, extra alerts, and
/// answers to questions asked on the Ask tab. Claude only reads; it never controls the house.
@MainActor
@Observable
final class Assistant {
    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    private(set) var briefing: String?
    private(set) var alerts: [BoardAlert] = []
    private(set) var briefingTime: Date?
    private(set) var isBriefing = false
    private(set) var problem: String?
    private(set) var exchanges: [Exchange] = []
    private(set) var isAnswering = false

    let config: HomeConfig
    @ObservationIgnored private var history: [[String: Any]] = []
    @ObservationIgnored private var lastQuestion: Date?

    init(config: HomeConfig = .load()) {
        self.config = config
    }

    var isConfigured: Bool { config.hasAPIKey }

    private var client: ClaudeClient? {
        guard let key = config.anthropicAPIKey, config.hasAPIKey else { return nil }
        return ClaudeClient(apiKey: key, model: config.model ?? "claude-opus-5-5", effort: config.effort ?? "low")
    }

    /// Writes a briefing once the other data has had a moment to load, then refreshes it on the
    /// configured interval during the day.
    func start(context: @escaping @MainActor () -> BoardContext) async {
        if Launch.isDemo && !isConfigured {
            loadDemo()
            return
        }
        try? await Task.sleep(for: .seconds(8))
        while !Task.isCancelled {
            let hour = Calendar.current.component(.hour, from: .now)
            if briefingTime == nil || (6..<22).contains(hour) {
                await refreshBriefing(context())
            }
            try? await Task.sleep(for: .seconds((config.briefingMinutes ?? 60) * 60))
        }
    }

    // MARK: - Briefing

    private static let briefingSystem = """
        You write the short briefing shown at the top of a family's kitchen TV dashboard. \
        People glance at it from across the room, so be brief and concrete.

        You get a JSON snapshot of the weather, the kids' school calendar (homework, tests, \
        deadlines, events, missing work) and the house (doors, climate, lights).

        briefing: two or three short sentences, under 60 words, plain text, no markdown or emoji. \
        Greet for the time of day. Lead with what changes plans in the next day: rain or cold \
        around school drop-off and pickup, tests and things due (by kid name), no-school days. \
        After about 5 pm, focus on tonight and tomorrow morning. Leave out anything that is fine \
        or routine.

        alerts: at most three things someone should act on in the next few hours that are not \
        in alertsAlreadyShown, such as "Jackets for the walk to school" or "Leo's chorus \
        permission slip is due tomorrow". Each title under 45 characters, detail under 80. \
        Use urgent only for something that will go wrong without action today. Return an empty \
        list when nothing qualifies.
        """

    private static let briefingSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "briefing": ["type": "string"],
            "alerts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "severity": ["type": "string", "enum": ["urgent", "heads_up"]],
                        "title": ["type": "string"],
                        "detail": ["type": "string"],
                    ],
                    "required": ["severity", "title", "detail"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["briefing", "alerts"],
        "additionalProperties": false,
    ]

    private struct BriefingReply: Decodable {
        struct Alert: Decodable {
            let severity: BoardAlert.Severity
            let title: String
            let detail: String
        }
        let briefing: String
        let alerts: [Alert]
    }

    func refreshBriefing(_ context: BoardContext) async {
        guard let client, !isBriefing else { return }
        isBriefing = true
        defer { isBriefing = false }
        do {
            let reply = try await client.send(
                system: Self.briefingSystem,
                messages: [["role": "user", "content": context.json]],
                schema: Self.briefingSchema
            )
            let parsed = try JSONDecoder().decode(BriefingReply.self, from: Data(reply.text.utf8))
            briefing = parsed.briefing
            alerts = parsed.alerts.map {
                BoardAlert(severity: $0.severity, title: $0.title, detail: $0.detail, symbol: "sparkles")
            }
            briefingTime = .now
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Questions

    private static let askSystem = """
        You answer questions from a family standing at their kitchen TV. Each question comes \
        with a JSON snapshot of the weather, the kids' school calendar and the house; answer \
        from it. Reply in one to three short sentences of plain text, no markdown, readable \
        from across the room. If the snapshot doesn't have the answer, say so briefly. You \
        can't control anything: for locks, the garage, lights or the thermostat, point them \
        to the Home tab.
        """

    func ask(_ question: String, context: BoardContext) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        // A new conversation after 10 quiet minutes: the next person is probably asking something unrelated.
        if let last = lastQuestion, Date.now.timeIntervalSince(last) > 600 { resetConversation() }
        lastQuestion = .now
        exchanges.append(Exchange(question: question))
        let index = exchanges.count - 1

        guard let client else {
            exchanges[index].answer = "Add an Anthropic API key to HomeConfig.json to ask questions."
            exchanges[index].failed = true
            return
        }
        isAnswering = true
        defer { isAnswering = false }
        let message: [String: Any] = ["role": "user", "content": "Current snapshot:\n\(context.json)\n\nQuestion: \(question)"]
        do {
            let reply = try await client.send(system: Self.askSystem, messages: history + [message])
            history += [message, ["role": "assistant", "content": reply.content]]
            exchanges[index].answer = reply.text
        } catch {
            exchanges[index].answer = error.localizedDescription
            exchanges[index].failed = true
        }
    }

    func resetConversation() {
        history = []
        exchanges = []
    }

    // MARK: - Demo

    private func loadDemo() {
        briefing = "Good morning! Rain moves in around 2 pm, so pack umbrellas for pickup. Maya has her Math Unit 2 test Thursday, and Leo's safety program opt-out is due Wednesday."
        alerts = [
            BoardAlert(severity: .headsUp, title: "Umbrellas for school pickup", detail: "70% chance of rain at 3 pm", symbol: "sparkles"),
            BoardAlert(severity: .headsUp, title: "Maya: study for Thursday's test", detail: "Math Unit 2 Test is in two days", symbol: "sparkles"),
        ]
        briefingTime = .now
    }
}
