import Foundation

enum RecordKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case pushups, plank
    var id: String { rawValue }
    var title: String { self == .pushups ? "俯卧撑" : "平板支撑" }
    var unit: String { self == .pushups ? "reps" : "seconds" }
    var unitLabel: String { self == .pushups ? "个" : "秒" }
    var metricKind: String { self == .pushups ? "count" : "duration" }
    var icon: String { self == .pushups ? "figure.strengthtraining.functional" : "timer" }
    func validate(_ value: Double) throws {
        guard value.isFinite, value > 0, value <= 1_000_000,
              self != .pushups || value.rounded() == value else { throw RecordError.message("\(title)请输入有效的正\(self == .pushups ? "整数" : "数")") }
    }
}

enum RecordDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }
    static func key(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])), self.key(date) == key else { return nil }
        return date
    }
}

struct FitnessActivity: Codable, Identifiable, Sendable {
    let id: String
    let slug: String
    let label: String
    let metricKind: String
    let unit: String
    let createdAt: String
    var kind: RecordKind? {
        RecordKind.allCases.first { kind in
            let aliases = kind == .pushups ? ["pushups", "push-ups", "push-up", "俯卧撑"] : ["plank", "平板支撑"]
            return metricKind == kind.metricKind && unit == kind.unit && (label == kind.title || aliases.contains(slug.lowercased()))
        }
    }
}

struct FitnessEntry: Codable, Identifiable, Sendable {
    let id: String
    let batchId: String
    let activityId: String
    var performedOn: String
    var amount: Double
    let isEstimated: Bool
    let rawText: String
    let createdAt: String
    var updatedAt: String
}

struct RecordIntent: Codable, Sendable, Equatable {
    let activity: RecordKind
    let amount: Double
    let performedOn: String
    func validate() throws {
        try activity.validate(amount)
        guard RecordDate.date(performedOn) != nil else { throw RecordError.message("日期无效") }
    }
}

struct RecordRow: Identifiable {
    let id: String
    let kind: RecordKind
    let amount: Double
    let performedOn: String
    let status: String
    let canEdit: Bool
    let error: String?
}

struct RecordConfiguration: Sendable {
    let endpoint: URL
    let token: String
    let accessClientID: String
    let accessClientSecret: String
}

struct WriteResponse: Codable, Sendable {
    let entries: [FitnessEntry]?
    let entry: FitnessEntry?
    let activitiesCreated: [FitnessActivity]?
    var allEntries: [FitnessEntry] { entries ?? entry.map { [$0] } ?? [] }
}

struct RecordOperation: Codable, Identifiable, Sendable {
    enum State: String, Codable { case pending, inFlight, complete, blocked }
    let id: String
    let sourceID: String
    var intents: [RecordIntent]
    let rawText: String
    let targetID: String?
    var body: Data?
    var state: State = .pending
    var response: WriteResponse?
    var error: String?
    var path: String { targetID.map { "api/entries/" + $0 } ?? "api/records" }
    var method: String { targetID == nil ? "POST" : "PATCH" }
}

struct RecordSnapshot: Codable {
    var activities: [FitnessActivity] = []
    var entries: [FitnessEntry] = []
    var operations: [RecordOperation] = []
    var refreshedAt: Date?
}

enum RecordError: LocalizedError {
    case message(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .http(let status, let message): "HTTP \(status)：\(message)"
        }
    }
}
