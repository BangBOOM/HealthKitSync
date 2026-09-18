import SwiftUI

struct TrendsView: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @Binding var requestedDate: String?
    let openChat: () -> Void
    @State private var activity: RecordKind = .pushups
    @State private var presentation: RecordPresentation = .heatmap
    @State private var month = RecordStatistics.month(containing: Date()).start
    @State private var selectedDate: String?

    private var range: (start: Date, end: Date) { RecordStatistics.month(containing: month) }
    private var series: RecordSeries {
        (try? RecordStatistics.series(rows: records.rows, from: RecordDate.key(range.start), to: RecordDate.key(range.end), activity: activity)) ?? RecordSeries(activity: activity, days: [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("运动", selection: $activity) {
                    ForEach(RecordKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.pickerStyle(.segmented)
                HStack {
                    Button("上个月", systemImage: "chevron.left") { moveMonth(-1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                    Spacer()
                    Text(String(RecordDate.key(month).prefix(7)).replacingOccurrences(of: "-", with: " / ")).font(.headline.monospacedDigit())
                    Spacer()
                    Button("下个月", systemImage: "chevron.right") { moveMonth(1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                        .disabled(month >= RecordStatistics.month(containing: Date()).start)
                    Button("本月") { month = RecordStatistics.month(containing: Date()).start; selectedDate = nil }.font(.subheadline)
                }
                Picker("图表", selection: $presentation) {
                    Text("热力图").tag(RecordPresentation.heatmap)
                    Text("柱状图").tag(RecordPresentation.bar)
                }.pickerStyle(.segmented)
                RecordChartView(series: series, presentation: presentation, selectedDate: $selectedDate)
                if let selectedDate {
                    Divider()
                    Text("\(selectedDate) 明细").font(.headline)
                    RecordDetailRows(rows: records.rows.filter { $0.kind == activity && $0.performedOn == selectedDate }) { row in
                        Task {
                            await assistant.selectRecord(row, records: records)
                            if assistant.selectedRecord?.id == row.id { openChat() }
                        }
                    }.disabled(assistant.isBusy)
                    if assistant.isBusy { Text("助手正在处理，请稍后选择记录").font(.caption).foregroundStyle(.secondary) }
                }
                RecordSyncStatus(horizontalPadding: 0)
                if records.endpointID.isEmpty { Text("请在设置中连接 heatmap 数据服务。").font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }
        .navigationTitle("趋势").navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await records.sync() }
        .onAppear { consumeDate() }
        .onChange(of: requestedDate) { _, _ in consumeDate() }
    }

    private func moveMonth(_ offset: Int) {
        guard let next = RecordDate.calendar.date(byAdding: .month, value: offset, to: month) else { return }
        month = next; selectedDate = nil
    }
    private func consumeDate() {
        guard let requestedDate, let date = RecordDate.date(requestedDate) else { return }
        month = RecordStatistics.month(containing: date).start
        selectedDate = requestedDate
        self.requestedDate = nil
    }
}
