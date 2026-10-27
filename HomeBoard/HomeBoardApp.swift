import SwiftUI
import UIKit

@main
struct HomeBoardApp: App {
    @State private var school = BoardStore()
    @State private var home = HomeStore()
    @State private var weather = WeatherStore()
    @State private var assistant = Assistant()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(school)
                .environment(home)
                .environment(weather)
                .environment(assistant)
                .preferredColorScheme(.dark)
                // A wall display: never let the Apple TV screensaver kick in while the board is open.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
