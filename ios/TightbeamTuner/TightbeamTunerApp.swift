import SwiftUI
import UIKit

@main
struct TightbeamTunerApp: App {
    init() {
        // Navigation titles are drawn by UIKit; give them the Nordic text color.
        let text = UIColor(resource: .nordicText)
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: text]
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains(WIb6SafeAreaCaptureFixtureConfiguration.launchArgument) {
                WIb6SafeAreaCaptureFixtureView(arguments: ProcessInfo.processInfo.arguments)
                    .tint(Color(.accent))
            } else if ProcessInfo.processInfo.arguments.contains(WI721CaptureFixtureConfiguration.launchArgument) {
                WI721CaptureFixtureView(arguments: ProcessInfo.processInfo.arguments)
                    .tint(Color(.accent))
            } else {
                ContentView()
                    .tint(Color(.accent))
            }
#else
            ContentView()
                .tint(Color(.accent))
#endif
        }
    }
}
