import SwiftUI

@main
struct HealthKitSyncApp: App {
    @State private var healthKit = HealthKitService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(healthKit)
        }
    }
}

