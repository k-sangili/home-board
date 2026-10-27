import SwiftUI

/// Tabs across the top (Menu on the Siri Remote brings them back): the home dashboard,
/// SchoolBoard's week/month board, cameras, and Ask. Returns to the dashboard after 5 idle minutes.
struct RootView: View {
    enum Tab { case home, school, cameras, ask }

    @Environment(BoardStore.self) private var school
    @Environment(HomeStore.self) private var home
    @Environment(WeatherStore.self) private var weather
    @Environment(Assistant.self) private var assistant
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .home
    @State private var tabChanged = Date.now
    @State private var now = Date.now

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            TabView(selection: $tab) {
                DashboardView(now: now)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)
                BoardView()
                    .tabItem { Label("School", systemImage: "graduationcap.fill") }
                    .tag(Tab.school)
                CamerasView()
                    .tabItem { Label("Cameras", systemImage: "video.fill") }
                    .tag(Tab.cameras)
                AskView(now: now)
                    .tabItem { Label("Ask", systemImage: "sparkles") }
                    .tag(Tab.ask)
            }

            // Dim overnight so the TV isn't a night-light (the School tab dims itself).
            Color.black.opacity(isNight && tab != .school ? 0.55 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .task { await school.start() }
        .task { await weather.start() }
        .task { home.start() }
        .task {
            await assistant.start { [school, home, weather] in
                let now = Date.now
                let alerts = AlertRules.alerts(home: home, school: school.items, now: now)
                return BoardContext.build(now: now, weather: weather, school: school, home: home, alerts: alerts)
            }
        }
        .task { await tick() }
        .onChange(of: tab) { tabChanged = .now }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await school.refresh() }
            Task { await weather.refresh() }
        }
    }

    private var isNight: Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= 21 || hour < 6
    }

    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            now = .now
            if tab != .home && now.timeIntervalSince(tabChanged) > 300 {
                tab = .home
            }
        }
    }
}
