import Foundation

/// Shared by the assistant and the device integration probe. No model output
/// is treated as a saved record until the native operation log confirms it.
@MainActor
enum RecordToolService {
    static func execute(name: String, args: [String: Any], requestID: String, rawText: String, records: RecordStore) async throws -> [String: Any] {
        switch name {
        case "record_entries":
            await records.sync()
            guard !records.snapshot.operations.contains(where: { $0.state == .inFlight }) else { throw RecordError.message("有保存结果待核对，请恢复网络并同步后再新增。") }
            let data = try JSONSerialization.data(withJSONObject: args["entries"] ?? [])
            let intents = try JSONDecoder().decode([RecordIntent].self, from: data)
            let id = try records.add(intents, rawText: rawText, sourceID: requestID + ":create")
            await records.sync()
            return try records.operationResult(id)
        case "update_entry":
            guard let id = args["id"] as? String, let amount = args["amount"] as? Double, let date = args["performedOn"] as? String else { throw RecordError.message("修改参数无效") }
            let operation = try await records.update(id: id, amount: amount, performedOn: date, sourceID: requestID + ":update:" + id)
            return try records.operationResult(operation)
        case "query_entries":
            guard let from = args["from"] as? String, let to = args["to"] as? String else { throw RecordError.message("查询参数无效") }
            let activity = (args["activity"] as? String).flatMap(RecordKind.init(rawValue:))
            let presentation = (args["presentation"] as? String).flatMap(RecordPresentation.init(rawValue:)) ?? .list
            guard args["activity"] == nil || activity != nil,
                  args["presentation"] == nil || (args["presentation"] as? String).flatMap(RecordPresentation.init(rawValue:)) != nil else { throw RecordError.message("查询类别或展示方式无效") }
            guard RecordDate.date(from) != nil, RecordDate.date(to) != nil, from <= to else { throw RecordError.message("查询日期范围无效") }
            await records.sync()
            var result = try records.query(from: from, to: to, activity: activity, presentation: presentation)
            result["syncError"] = records.error ?? ""
            return result
        case "delete_entry":
            guard let id = args["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordError.message("删除参数无效，需要真实记录 ID") }
            let sourceID = requestID + ":delete:" + id
            if records.snapshot.deletionReceipts?.keys.contains(where: { $0.hasPrefix(requestID + ":delete:") && $0 != sourceID }) == true {
                throw RecordError.message("每次输入只支持删除一条记录，请另发消息指定下一条。")
            }
            let row = try await records.delete(id: id, sourceID: sourceID)
            return ["status": "deleted", "entries": [["id": row.id, "activity": row.kind.rawValue, "amount": row.amount, "performedOn": row.performedOn]], "error": ""]
        default: throw RecordError.message("不支持的工具")
        }
    }
}
