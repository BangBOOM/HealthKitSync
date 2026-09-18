import SwiftUI

@main
struct HealthKitSyncApp: App {
    @State private var healthKit = HealthKitService()
    @State private var uploadHistory = UploadHistoryService()
    @State private var records = RecordStore()
    @State private var assistant = AssistantStore()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--agent-probe") {
                    AgentProbeView()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .environment(healthKit)
                .environment(uploadHistory)
                .environment(records)
                .environment(assistant)
        }
    }
}
