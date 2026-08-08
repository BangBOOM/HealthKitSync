import SwiftUI

@main
struct HealthKitSyncApp: App {
    @State private var healthKit = HealthKitService()
    @State private var uploadHistory = UploadHistoryService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(healthKit)
                .environment(uploadHistory)
        }
    }
}
