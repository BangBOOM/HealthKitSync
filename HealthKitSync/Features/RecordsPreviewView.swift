#if DEBUG
import SwiftUI

/// Offline visual fixture; disposable storage, no production writes or model requests.
struct RecordsPreviewView: View {
    @State private var records = RecordStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("RecordsPreview-" + UUID().uuidString), transport: PreviewRecordTransport())
    @State private var assistant = AssistantStore()
    @State private var tab = 0
    @State private var date: String?
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { PersonalRecordsView(showDate: { date = $0; tab = 1 }, openSettings: {}) }
                .tabItem { Label("记录", systemImage: "bubble.left.and.bubble.right") }.tag(0)
            NavigationStack { TrendsView(requestedDate: $date, openChat: { tab = 0 }) }
                .tabItem { Label("趋势", systemImage: "chart.bar.xaxis") }.tag(1)
        }
        .environment(records).environment(assistant)
        .task {
            do {
                try records.configure(RecordConfiguration(endpoint: URL(string: "https://visual-fixture.invalid")!, token: "", accessClientID: "", accessClientSecret: ""))
                let today = RecordDate.key(Date())
                for offset in [0, 1, 3, 4, 7, 10, 15, 21, 28] {
                    let day = RecordDate.key(RecordDate.calendar.date(byAdding: .day, value: -offset, to: Date())!)
                    _ = try records.add([RecordIntent(activity: .pushups, amount: Double(20 + offset * 2), performedOn: day), RecordIntent(activity: .plank, amount: Double(90 + offset * 10), performedOn: day)], rawText: "视觉测试", sourceID: "preview-\(offset)")
                }
                await assistant.loadConversation(records: records)
                let start = RecordDate.key(RecordDate.calendar.date(byAdding: .day, value: -6, to: Date())!)
                assistant.previewResult(try records.query(from: start, to: today, presentation: .heatmap))
            } catch { assertionFailure(error.localizedDescription) }
        }
    }
}
private struct PreviewRecordTransport: RecordTransport {
    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}
#endif
