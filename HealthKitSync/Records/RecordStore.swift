import Foundation
import CryptoKit
import Observation

@MainActor
@Observable
final class RecordStore {
    private(set) var snapshot = RecordSnapshot()
    private(set) var isSyncing = false
    private(set) var syncStatus = ""
    var canCancelSync: Bool { syncTask != nil }
    private(set) var error: String?
    private(set) var endpointID = ""
    @ObservationIgnored private var configuration: RecordConfiguration?
    @ObservationIgnored private let transport: any RecordTransport
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var storageError: String?
    @ObservationIgnored private var activeReads = 0
    @ObservationIgnored private var syncAgain = false
    private var syncTask: Task<Void, Never>?

    init(directory: URL? = nil, transport: any RecordTransport = HTTPRecordTransport()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PersonalRecords")
        self.transport = transport
    }

    func configure(_ configuration: RecordConfiguration?) throws {
        guard !isSyncing, activeReads == 0 else { throw RecordError.message("记录正在同步，请稍后修改连接设置") }
        self.configuration = configuration
        let nextID = configuration.map { Self.digest($0.endpoint.absoluteString) } ?? ""
        guard nextID != endpointID else { return }
        endpointID = nextID
        snapshot = RecordSnapshot()
        error = nil
        storageError = nil
        file = nextID.isEmpty ? nil : directory.appendingPathComponent(nextID + ".json")
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do { snapshot = try JSONDecoder().decode(RecordSnapshot.self, from: Data(contentsOf: file)) }
        catch { storageError = "本地记录读取失败，已保留原文件：\(error.localizedDescription)"; self.error = storageError }
    }

    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func persist(_ next: RecordSnapshot) throws {
        if let storageError { throw RecordError.message(storageError) }
        guard let file else { throw RecordError.message("请先配置 heatmap 数据服务") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        snapshot = next
    }

    var rows: [RecordRow] {
        let activities = Dictionary(snapshot.activities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let locked = Dictionary(snapshot.operations.filter { $0.targetID != nil && $0.state != .complete }.map { ($0.targetID!, $0) }, uniquingKeysWith: { _, last in last })
        let remote = snapshot.entries.compactMap { entry -> RecordRow? in
            guard let kind = activities[entry.activityId]?.kind else { return nil }
            let operation = locked[entry.id]
            return RecordRow(id: entry.id, kind: kind, amount: entry.amount, performedOn: entry.performedOn, status: operation?.state == .blocked ? "修改失败" : operation != nil ? "修改结果待核对" : "已同步", canEdit: operation == nil && !isSyncing, error: operation?.error)
        }
        let pending = snapshot.operations.filter { $0.state != .complete && $0.targetID == nil }.flatMap { operation in
            operation.intents.enumerated().filter { !(operation.deletedIndices ?? []).contains($0.offset) }.map { index, intent in
                RecordRow(id: operation.id + ":" + String(index), kind: intent.activity, amount: intent.amount, performedOn: intent.performedOn, status: operation.state == .blocked ? "同步失败" : operation.state == .inFlight ? "保存结果待核对" : "待同步", canEdit: operation.state == .pending && operation.body == nil && !isSyncing, error: operation.error)
            }
        }
        return (remote + pending).sorted { $0.performedOn > $1.performedOn || ($0.performedOn == $1.performedOn && $0.id > $1.id) }
    }

    func add(_ intents: [RecordIntent], rawText: String, sourceID: String) throws -> String {
        guard !intents.isEmpty, intents.count <= 20 else { throw RecordError.message("每次记录 1–20 项") }
        for intent in intents { try intent.validate() }
        if let existing = snapshot.operations.first(where: { $0.sourceID == sourceID }) {
            guard existing.targetID == nil, existing.intents == intents else { throw RecordError.message("这次输入已经产生不同的操作，请核对记录后用新消息修改") }
            return existing.id
        }
        var next = snapshot
        let operation = RecordOperation(id: UUID().uuidString, sourceID: sourceID, intents: intents, rawText: rawText.isEmpty ? "手动记录" : rawText, targetID: nil)
        next.operations.append(operation)
        try persist(next)
        return operation.id
    }

    func update(id: String, amount: Double, performedOn: String, sourceID: String) async throws -> String {
        if let existing = snapshot.operations.first(where: { $0.sourceID == sourceID }) {
            guard existing.targetID == id, existing.intents.first?.amount == amount, existing.intents.first?.performedOn == performedOn else { throw RecordError.message("这次输入已有不同的修改，请核对后重新输入") }
            return existing.id
        }
        guard !isSyncing, activeReads == 0 else { throw RecordError.message("请等待同步完成后修改") }
        // An unsent local entry can be corrected offline. Once bytes have been
        // frozen for submission, its idempotency key and contents never change.
        for (operationIndex, operation) in snapshot.operations.enumerated() where operation.targetID == nil {
            if let itemIndex = operation.intents.indices.first(where: { operation.id + ":" + String($0) == id }) {
                guard operation.state == .pending, operation.body == nil, !(operation.deletedIndices ?? []).contains(itemIndex) else { throw RecordError.message("记录已删除或保存结果待核对，暂不能修改") }
                let intent = RecordIntent(activity: operation.intents[itemIndex].activity, amount: amount, performedOn: performedOn)
                try intent.validate()
                var next = snapshot
                next.operations[operationIndex].intents[itemIndex] = intent
                try persist(next)
                return operation.id
            }
        }
        // A successful fresh read is required before starting an edit.
        try await refresh()
        guard !isSyncing else { throw RecordError.message("请等待同步完成后修改") }
        if snapshot.operations.contains(where: { $0.sourceID == sourceID }) {
            return try await update(id: id, amount: amount, performedOn: performedOn, sourceID: sourceID)
        }
        guard let row = rows.first(where: { $0.id == id }), row.canEdit else { throw RecordError.message("记录不存在或结果待核对，暂不能修改") }
        let intent = RecordIntent(activity: row.kind, amount: amount, performedOn: performedOn)
        try intent.validate()
        let body = try JSONSerialization.data(withJSONObject: ["amount": amount, "performedOn": performedOn], options: [.sortedKeys])
        let operation = RecordOperation(id: UUID().uuidString, sourceID: sourceID, intents: [intent], rawText: "修改记录", targetID: id, body: body)
        var next = snapshot
        next.operations.append(operation)
        try persist(next)
        await sync()
        return operation.id
    }

    func delete(id: String) async throws {
        guard !isSyncing, activeReads == 0 else { throw RecordError.message("请等待同步完成后删除") }
        guard let row = rows.first(where: { $0.id == id }), row.canEdit else { throw RecordError.message("记录不存在或保存结果待核对，暂不能删除") }
        for (index, operation) in snapshot.operations.enumerated() where operation.targetID == nil && operation.state == .pending && operation.body == nil {
            if let item = operation.intents.indices.first(where: { operation.id + ":" + String($0) == id }) {
                var next = snapshot
                next.operations[index].deletedIndices = (operation.deletedIndices ?? []) + [item]
                if next.operations[index].activeIntents.isEmpty {
                    next.operations[index].state = .complete
                    next.operations[index].response = WriteResponse(entries: [], entry: nil, activitiesCreated: nil)
                }
                try persist(next)
                return
            }
        }
        guard let configuration else { throw RecordError.message("请先配置 heatmap 数据服务") }
        guard !snapshot.operations.contains(where: { $0.state == .inFlight }) else { throw RecordError.message("请先同步核对已有操作，再删除") }
        // Hold the synchronization lock throughout deletion. Never enqueue an automatic DELETE retry.
        isSyncing = true
        syncStatus = "正在删除记录…"
        defer { isSyncing = false; syncStatus = "" }
        do {
            struct Deleted: Decodable { let ok: Bool; let deleted: FitnessEntry }
            let data = try await transport.request(configuration, path: "api/entries/" + id, method: "DELETE", body: nil, operationID: nil)
            let result = try JSONDecoder().decode(Deleted.self, from: data)
            guard result.ok, result.deleted.id == id else { throw RecordError.message("删除响应与目标记录不一致") }
            var next = snapshot
            next.entries.removeAll { $0.id == id }
            try persist(next)
        } catch {
            throw RecordError.message("未能确认删除结果：\(error.localizedDescription)。请点“同步记录”核对后再操作。")
        }
    }

    func refresh() async throws {
        guard let configuration else { throw RecordError.message("请先配置 heatmap 数据服务") }
        guard !snapshot.operations.contains(where: { $0.state == .inFlight }) else { throw RecordError.message("有上传结果待核对，请先同步记录") }
        activeReads += 1
        defer { activeReads -= 1 }
        let endpoint = endpointID
        struct Activities: Decodable { let activities: [FitnessActivity] }
        struct Entries: Decodable { let entries: [FitnessEntry] }
        let activityData = try await transport.request(configuration, path: "api/activities", method: "GET", body: nil, operationID: nil)
        let entryData = try await transport.request(configuration, path: "api/entries", method: "GET", body: nil, operationID: nil)
        guard endpoint == endpointID else { return }
        var next = snapshot
        next.activities = try JSONDecoder().decode(Activities.self, from: activityData).activities
        next.entries = try JSONDecoder().decode(Entries.self, from: entryData).entries
        next.refreshedAt = Date()
        try persist(next)
    }

    private func payload(for operation: RecordOperation) throws -> Data {
        if let body = operation.body { return body }
        let entries: [[String: Any]] = try operation.activeIntents.map { intent in
            let matches = snapshot.activities.filter { $0.kind == intent.activity }
            guard matches.count <= 1 else { throw RecordError.message("远端有多个\(intent.activity.title)类别，请先在 heatmap 中整理") }
            var entry: [String: Any] = ["amount": intent.amount, "unit": intent.activity.unit, "performedOn": intent.performedOn]
            if let activity = matches.first { entry["activityId"] = activity.id }
            else { entry.merge(["label": intent.activity.title, "slug": intent.activity.title, "metricKind": intent.activity.metricKind]) { _, new in new } }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: ["rawText": operation.rawText, "performedOn": operation.intents[0].performedOn, "entries": entries], options: [.sortedKeys])
    }

    func sync() async {
        if let syncTask { syncAgain = true; await syncTask.value; return }
        if isSyncing { syncAgain = true; return }
        let task = Task { await performSync() }
        syncTask = task
        await task.value
        syncTask = nil
        let needsAnotherPass = syncAgain && error == nil && snapshot.operations.contains { $0.state == .pending }
        syncAgain = false
        if needsAnotherPass { await sync() }
    }

    func cancelSync() {
        syncAgain = false
        syncTask?.cancel()
    }

    private func performSync() async {
        guard activeReads == 0, let configuration, storageError == nil else { return }
        isSyncing = true
        error = nil
        defer {
            isSyncing = false
            syncStatus = ""
        }
        do {
            // Read category IDs before freezing requests, but reconcile unknown writes
            // before replacing the entry cache so provisional rows cannot be counted twice.
            struct Activities: Decodable { let activities: [FitnessActivity] }
            try Task.checkCancellation()
            syncStatus = "正在连接数据服务…"
            let activityData = try await transport.request(configuration, path: "api/activities", method: "GET", body: nil, operationID: nil)
            var categorized = snapshot
            categorized.activities = try JSONDecoder().decode(Activities.self, from: activityData).activities
            try persist(categorized)
            while let operation = snapshot.operations.first(where: { $0.state == .pending || $0.state == .inFlight }) {
                try Task.checkCancellation()
                do {
                    var result: WriteResponse?
                    syncStatus = "正在核对保存结果…"
                    do {
                        struct Receipt: Decodable { let response: WriteResponse }
                        let receipt = try await transport.request(configuration, path: "api/operations/" + operation.id, method: "GET", body: nil, operationID: nil)
                        result = try JSONDecoder().decode(Receipt.self, from: receipt).response
                    } catch RecordError.http(404, "operation_not_found") {
                        // Only this exact response proves that the idempotency API is present.
                    } catch RecordError.http(404, _) {
                        throw RecordError.backendUpgradeRequired
                    } catch RecordError.http(500, let message) where message.lowercased().contains("no such table: write_operations") {
                        throw RecordError.backendUpgradeRequired
                    }
                    if result == nil {
                        let body = try payload(for: operation)
                        var next = snapshot
                        let index = next.operations.firstIndex { $0.id == operation.id }!
                        next.operations[index].body = body
                        next.operations[index].state = .inFlight
                        next.operations[index].error = nil
                        try persist(next) // freeze before sending; retries reuse identical bytes
                        syncStatus = "正在上传待同步记录…"
                        let data = try await transport.request(configuration, path: operation.path, method: operation.method, body: body, operationID: operation.id)
                        result = try JSONDecoder().decode(WriteResponse.self, from: data)
                    }
                    if let result { try complete(operation.id, result: result) }
                } catch {
                    var next = snapshot
                    let index = next.operations.firstIndex { $0.id == operation.id }!
                    next.operations[index].error = error.localizedDescription
                    if case RecordError.http(let status, _) = error, [400, 409, 422].contains(status) { next.operations[index].state = .blocked }
                    try persist(next)
                    throw error
                }
            }
            try Task.checkCancellation()
            syncStatus = "正在读取记录…"
            try await refresh()
        } catch {
            // An old server can still provide existing records. Refresh only
            // when no submitted write has an unknown result, to avoid duplicates.
            if case RecordError.backendUpgradeRequired = error,
               !snapshot.operations.contains(where: { $0.state == .inFlight }) {
                try? await refresh()
            }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.error = "已停止同步，本机记录已保留。稍后可重新同步核对结果。"
            } else if (error as? URLError)?.code == .timedOut {
                self.error = "连接数据服务超时，请检查网络后重试。本机记录已保留。"
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func complete(_ id: String, result: WriteResponse) throws {
        var next = snapshot
        let index = next.operations.firstIndex { $0.id == id }!
        next.operations[index].state = .complete
        next.operations[index].response = result
        next.operations[index].error = nil
        for activity in result.activitiesCreated ?? [] where !next.activities.contains(where: { $0.id == activity.id }) { next.activities.append(activity) }
        for entry in result.allEntries {
            next.entries.removeAll { $0.id == entry.id }
            next.entries.append(entry)
        }
        try persist(next)
    }

    func operationResult(_ id: String) throws -> [String: Any] {
        guard let operation = snapshot.operations.first(where: { $0.id == id }) else { throw RecordError.message("操作不存在") }
        let saved = operation.response?.allEntries.map { entry -> [String: Any] in
            let kind = snapshot.activities.first { $0.id == entry.activityId }?.kind
            return ["id": entry.id, "activity": kind?.rawValue ?? "unknown", "amount": entry.amount, "performedOn": entry.performedOn]
        }
        let pending = operation.activeIntents.map { ["activity": $0.activity.rawValue, "amount": $0.amount, "performedOn": $0.performedOn] as [String: Any] }
        return ["operationID": id, "status": operation.state == .complete ? "saved" : operation.state == .blocked ? "failed" : "pending", "error": operation.error ?? "", "entries": saved ?? pending]
    }

    func query(from: String, to: String) throws -> [String: Any] {
        guard RecordDate.date(from) != nil, RecordDate.date(to) != nil, from <= to else { throw RecordError.message("查询日期范围无效") }
        let matches = rows.filter { $0.performedOn >= from && $0.performedOn <= to }
        return ["from": from, "to": to, "cachedAt": snapshot.refreshedAt?.ISO8601Format() ?? "尚未同步", "entries": matches.map { ["id": $0.id, "activity": $0.kind.rawValue, "amount": $0.amount, "performedOn": $0.performedOn, "status": $0.status] as [String: Any] }, "totals": Dictionary(uniqueKeysWithValues: RecordKind.allCases.map { kind in (kind.rawValue, matches.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount }) })]
    }
}
