import SwiftUI

/// Ask Claude about the day. Select the text field and hold the Siri button on the remote to
/// dictate, or type.
struct AskView: View {
    @Environment(BoardStore.self) private var school
    @Environment(HomeStore.self) private var home
    @Environment(WeatherStore.self) private var weather
    @Environment(Assistant.self) private var assistant
    let now: Date
    @State private var question = ""

    private let suggestions = [
        "What's due tomorrow?",
        "Is the house locked up?",
        "Do the kids need jackets today?",
        "What's happening this weekend?",
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 20) {
                PanelTitle(text: "Ask", symbol: "sparkles")
                TextField("Ask about school, home or the weather", text: $question)
                    .font(Theme.font(26, .medium))
                    .onSubmit { send(question) }
                Text("Select the box, then hold the Siri button on the remote and speak.")
                    .font(Theme.font(18, .medium))
                    .foregroundStyle(Theme.secondary)
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .font(Theme.font(22, .semibold))
                }
                if !assistant.exchanges.isEmpty {
                    Button("New conversation", systemImage: "arrow.counterclockwise") { assistant.resetConversation() }
                        .font(Theme.font(20, .semibold))
                }
                Spacer()
            }
            .frame(width: 640)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if assistant.exchanges.isEmpty {
                            Text(assistant.isConfigured ? "Answers appear here." : "Add an Anthropic API key to HomeConfig.json to ask questions.")
                                .font(Theme.font(24, .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(assistant.exchanges) { exchange in
                            ExchangeView(exchange: exchange).id(exchange.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.exchanges.last?.answer) {
                    if let last = assistant.exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .panelStyle()
        }
    }

    private func send(_ text: String) {
        question = ""
        let alerts = AlertRules.alerts(home: home, school: school.items, now: now)
        let context = BoardContext.build(now: .now, weather: weather, school: school, home: home, alerts: alerts)
        Task { await assistant.ask(text, context: context) }
    }
}

private struct ExchangeView: View {
    let exchange: Assistant.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exchange.question)
                .font(Theme.font(22, .bold))
                .foregroundStyle(Theme.secondary)
            if let answer = exchange.answer {
                Text(answer)
                    .font(Theme.font(30, .semibold))
                    .foregroundStyle(exchange.failed ? Theme.deadline : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Thinking…").font(Theme.font(24, .medium)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}
