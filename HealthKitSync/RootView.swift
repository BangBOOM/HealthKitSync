import SwiftUI

struct RootView: View {
    @Environment(HealthKitService.self) private var healthKit
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.scenePhase) private var scenePhase
    @State private var network = NetworkStatus()
    @State private var tab = MainTab.records
    @State private var trendDate: String?

    private enum MainTab { case records, trends, health, settings }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                PersonalRecordsView(showDate: { day in trendDate = day; tab = .trends }, openSettings: { tab = .settings })
            }.tabItem { Label("记录", systemImage: "bubble.left.and.bubble.right") }.tag(MainTab.records)
            NavigationStack {
                TrendsView(requestedDate: $trendDate, openChat: { tab = .records })
            }.tabItem { Label("趋势", systemImage: "chart.bar.xaxis") }.tag(MainTab.trends)
            NavigationStack {
                Group {
                    if healthKit.hasRequestedAuthorization {
                        WorkoutListView()
                    } else {
                        AuthorizationView()
                    }
                }
            }.tabItem { Label("健康同步", systemImage: "heart.text.clipboard") }.tag(MainTab.health)
            NavigationStack { PersonalSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(MainTab.settings)
        }
        .background {
            if let bridge = assistant.bridge {
                AgentWebView(webView: bridge.webView).id(ObjectIdentifier(bridge)).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
            }
        }
        .task {
            network.start()
            try? records.configure(PersonalSettings.load().recordConfiguration())
            await assistant.loadConversation(records: records)
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
