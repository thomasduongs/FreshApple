import SwiftUI

@main
struct FreshAppleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    init() { BackgroundRefresh.register() }
    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { BackgroundRefresh.schedule() }
            }
    }
}
