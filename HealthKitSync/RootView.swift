import SwiftUI

struct RootView: View {
    @Environment(HealthKitService.self) private var healthKit
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.scenePhase) private var scenePhase
    @State private var network = NetworkStatus()

    var body: some View {
        TabView {
            NavigationStack {
                Group {
                    if healthKit.hasRequestedAuthorization {
                        WorkoutListView()
                    } else {
                        AuthorizationView()
                    }
                }
            }.tabItem { Label("健康同步", systemImage: "heart.text.clipboard") }
            NavigationStack { PersonalRecordsView() }.tabItem { Label("记录", systemImage: "square.and.pencil") }
            NavigationStack { PersonalSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task {
            network.start()
            try? records.configure(PersonalSettings.load().recordConfiguration())
            await records.sync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { assistant.suspend() }
            if phase == .active {
                assistant.clearPreviousDayIfNeeded()
                Task { await records.sync() }
            }
        }
        .task {
            while !Task.isCancelled {
                let now = Date()
                guard let tomorrow = RecordDate.calendar.date(byAdding: .day, value: 1, to: RecordDate.calendar.startOfDay(for: now)) else { return }
                do { try await Task.sleep(for: .seconds(max(1, tomorrow.timeIntervalSince(now)))) }
                catch { return }
                assistant.clearPreviousDayIfNeeded()
            }
        }
        .onChange(of: network.isOnline) { _, online in
            if online, scenePhase == .active { Task { await records.sync() } }
        }
        .onDisappear { network.stop() }
    }
}
