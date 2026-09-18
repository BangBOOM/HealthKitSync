import Foundation

enum RecordPresentation: String, Codable, CaseIterable {
    case list, heatmap, bar
    var title: String { switch self { case .list: "明细"; case .heatmap: "热力图"; case .bar: "柱状图" } }
}

struct RecordDay: Codable, Identifiable {
    let date: String
    let amount: Double
    let count: Int
    let pending: Bool
    var id: String { date }
}

struct RecordSeries: Codable, Identifiable {
    let activity: RecordKind
    let days: [RecordDay]
    var id: String { activity.rawValue }
    var total: Double { days.reduce(0) { $0 + $1.amount } }
    var recordedDays: Int { days.filter { $0.count > 0 }.count }
    var hasPending: Bool { days.contains { $0.pending } }
    var maximum: Double { days.map(\.amount).max() ?? 0 }
    func level(_ day: RecordDay) -> Int {
        guard day.count > 0, maximum > 0 else { return 0 }
        return min(4, max(1, Int(ceil(day.amount / maximum * 4))))
    }
}

struct RecordVisualization: Codable {
    let from: String
    let to: String
    let presentation: RecordPresentation
    let series: [RecordSeries]
}

struct QueryEntry: Codable, Identifiable {
    let id: String
    let activity: RecordKind
    let amount: Double
    let performedOn: String
    let status: String?
    init(_ row: RecordRow) {
        id = row.id; activity = row.kind; amount = row.amount; performedOn = row.performedOn; status = row.status
    }
    var row: RecordRow {
        RecordRow(id: id, kind: activity, amount: amount, performedOn: performedOn, status: status ?? "已同步", canEdit: false, error: nil)
    }
}

enum RecordStatistics {
    static func series(rows: [RecordRow], from: String, to: String, activity: RecordKind) throws -> RecordSeries {
        guard let start = RecordDate.date(from), let end = RecordDate.date(to), start <= end else { throw RecordError.message("查询日期范围无效") }
        let grouped = Dictionary(grouping: rows.filter { $0.kind == activity && $0.performedOn >= from && $0.performedOn <= to }, by: \.performedOn)
        var days: [RecordDay] = []
        var date = start
        while date <= end {
            let key = RecordDate.key(date)
            let entries = grouped[key] ?? []
            days.append(RecordDay(date: key, amount: entries.reduce(0) { $0 + $1.amount }, count: entries.count, pending: entries.contains { $0.status != "已同步" }))
            guard let next = RecordDate.calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return RecordSeries(activity: activity, days: days)
    }

    static func month(containing date: Date) -> (start: Date, end: Date) {
        let interval = RecordDate.calendar.dateInterval(of: .month, for: date)!
        return (interval.start, RecordDate.calendar.date(byAdding: .day, value: -1, to: interval.end)!)
    }

    static func amount(_ amount: Double, kind: RecordKind, compact: Bool = false) -> String {
        if kind == .pushups { return amount.formatted(.number.precision(.fractionLength(0))) + (compact ? "" : " 个") }
        let minutes = Int(amount / 60)
        let seconds = amount - Double(minutes * 60)
        let text = seconds.formatted(.number.precision(.fractionLength(0...2)))
        if compact { return minutes > 0 ? "\(minutes)′\(text)″" : "\(text)″" }
        return minutes > 0 ? "\(minutes) 分 \(text) 秒" : "\(text) 秒"
    }
}
