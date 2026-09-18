import SwiftUI

struct RecordResultCard: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    let item: ChatItem
    let showDate: (String) -> Void
    @State private var selectedDate: String?

    private var result: [String: Any]? {
        guard let encoded = item.result, let snapshot = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else { return nil }
        if let id = snapshot["operationID"] as? String, let current = try? records.operationResult(id) { return current }
        return snapshot
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                let status = result["status"] as? String
                let visualization = decode(RecordVisualization.self, result["visualization"])
                let entries = decode([QueryEntry].self, result["entries"]) ?? []
                Label(title(status), systemImage: status == "deleted" ? "trash.circle" : status == "saved" ? "checkmark.circle.fill" : "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(status == "saved" ? Color.green : Color.accentColor)
                if let from = result["from"] as? String, let to = result["to"] as? String { Text("\(from) — \(to)").font(.caption).foregroundStyle(.secondary) }
                if let visualization {
                    ForEach(visualization.series) { series in
                        VStack(alignment: .leading, spacing: 12) {
                            Label { Text(series.activity.title).font(.subheadline) } icon: { RecordKindIcon(kind: series.activity) }
                            RecordChartView(series: series, presentation: visualization.presentation, selectedDate: $selectedDate)
                        }
                    }
                    if let selectedDate {
                        RecordDetailRows(rows: entries.filter { $0.performedOn == selectedDate }.map(\.row)) { row in
                            Task { await assistant.selectRecord(row, records: records) }
                        }.disabled(assistant.isBusy)
                    }
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(entry.activity.title); Spacer(); Text(RecordStatistics.amount(entry.amount, kind: entry.activity)) }
                            Text(entry.performedOn).font(.caption).foregroundStyle(.secondary)
                            Button("查看当天记录") { showDate(entry.performedOn) }.font(.caption)
                        }
                    }
                    if let totals = result["totals"] as? [String: Double] {
                        ForEach(RecordKind.allCases) { kind in
                            if let amount = totals[kind.rawValue] { Text("\(kind.title)：\(RecordStatistics.amount(amount, kind: kind))").font(.subheadline) }
                        }
                    }
                    if entries.isEmpty, result["from"] != nil { Text("这段时间没有记录").foregroundStyle(.secondary) }
                }
                if let queried = result["queriedAt"] as? String { Text("查询于 \(displayTime(queried)) · 快照").font(.caption2).foregroundStyle(.secondary) }
                if let cached = result["cachedAt"] as? String { Text("数据更新于 \(displayTime(cached))").font(.caption2).foregroundStyle(.secondary) }
                if let error = result["error"] as? String, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                if let error = result["syncError"] as? String, !error.isEmpty { Text("使用本地缓存：\(error)").font(.caption).foregroundStyle(.orange) }
                if let from = result["from"] as? String, let to = result["to"] as? String {
                    Button("刷新查询") {
                        let kind = (result["activity"] as? String).flatMap(RecordKind.init(rawValue:))
                        let style = (result["presentation"] as? String).flatMap(RecordPresentation.init(rawValue:)) ?? .list
                        let text = "重新查询 \(from) 至 \(to) 的\(kind?.title ?? "俯卧撑和平板支撑")记录，使用\(style.title)显示。"
                        let query = RecordQueryRequest(from: from, to: to, activity: kind, presentation: style)
                        Task { await assistant.send(records: records, textOverride: text, queryOverride: query) }
                    }.font(.subheadline).disabled(assistant.isBusy)
                }
            } else {
                Label("工具未完成", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Text(item.text).font(.caption)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private func title(_ status: String?) -> String {
        switch status { case "saved": "已保存"; case "pending": "已存本机 · 待同步"; case "deleted": "已删除"; case "failed": "保存失败"; default: "查询结果" }
    }
    private func displayTime(_ raw: String) -> String {
        ISO8601DateFormatter().date(from: raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
    }
}
