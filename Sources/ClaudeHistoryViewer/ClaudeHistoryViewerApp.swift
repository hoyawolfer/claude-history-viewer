import SwiftUI

@main
struct ClaudeHistoryViewerApp: App {
    var body: some Scene {
        WindowGroup("Claude History Viewer") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
