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
            ContentView()
                .tint(Color(.accent))
        }
    }
}
