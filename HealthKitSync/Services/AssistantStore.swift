import Foundation
import Observation

@MainActor
@Observable
final class AssistantStore {
    private(set) var bridge: PiBridge?
    private(set) var items: [ChatItem] = []
    private(set) var isBusy = false
    private(set) var error: String?
    var draft = ""
    private(set) var selectedRecord: RecordRow?
    private(set) var modelConfigured = false
    @ObservationIgnored private var archive = ChatArchive()
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var identity = ""
    @ObservationIgnored private var currentReplyID: String?
    @ObservationIgnored private var records: RecordStore?
    @ObservationIgnored private var settings = PersonalSettings()
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var cancellationVersion = 0
    @ObservationIgnored private var archiveError: String?

    func open(records: RecordStore) async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        defer { isBusy = false; clearPreviousDayIfNeeded() }
        await prepare(records: records)
    }

    func loadConversation(records: RecordStore) async {
        guard !isBusy else { return }
        updateConfigurationStatus(.load())
        if records.endpointID.isEmpty {
            draft = UserDefaults.standard.string(forKey: "personalAssistant.unassignedDraft") ?? draft
            return
        }
        await prepare(records: records, loadOnly: true)
    }

    func selectRecord(_ row: RecordRow?, records: RecordStore) async {
        guard !isBusy else { return }
        await loadConversation(records: records)
        guard error == nil else { return }
        selectedRecord = row
        saveDraft()
    }

    private func prepare(records: RecordStore, loadOnly: Bool = false) async {
        while isOpening {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        isOpening = true
        defer { isOpening = false }
        error = nil
        do {
            self.records = records
            settings = .load()
            updateConfigurationStatus(settings)
            guard loadOnly || (!settings.modelBaseURL.isEmpty && !settings.modelKey.isEmpty && !settings.modelName.isEmpty) else {
                throw PiError.message("请先在设置中配置模型地址、API Key 和模型名。")
            }
            guard !records.endpointID.isEmpty else { throw PiError.message("请先配置 heatmap 数据服务。") }
            let nextIdentity = RecordStore.digest(records.endpointID + settings.modelBaseURL + settings.modelName)
            if nextIdentity != identity {
                let initialDraft = identity.isEmpty ? draft : ""
                bridge?.dispose()
                bridge = nil
                identity = nextIdentity
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PersonalAssistant")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                file = folder.appendingPathComponent(identity + ".json")
                archiveError = nil
                do { archive = FileManager.default.fileExists(atPath: file!.path) ? try JSONDecoder().decode(ChatArchive.self, from: Data(contentsOf: file!)) : ChatArchive() }
                catch { archiveError = "会话文件读取失败，已保留原文件：\(error.localizedDescription)"; throw PiError.message(archiveError!) }
                if archive.sessionDay == nil,
                   let modified = try file!.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    archive.sessionDay = RecordDate.key(modified)
                }
                items = archive.items
                selectedRecord = archive.selectedRecord
                draft = initialDraft.isEmpty ? archive.draft : initialDraft
                UserDefaults.standard.removeObject(forKey: "personalAssistant.unassignedDraft")
            }
            if let archiveError { throw PiError.message(archiveError) }
            try rollOverIfNeeded()
            if loadOnly { return }
            if bridge?.isReady == true { return }
            bridge?.dispose()
            let runtime = PiBridge()
            bridge = runtime
            let runtimeSessionID = archive.sessionID
            runtime.onCheckpoint = { [weak self] body in
                guard let self, self.archive.sessionID == runtimeSessionID else { return }
                self.archive.runtime = try JSONSerialization.data(withJSONObject: body["messages"] ?? [])
                try self.save()
            }
            runtime.onEvent = { [weak self] event in
                guard let self, self.archive.sessionID == runtimeSessionID else { return }
                self.receive(event)
            }
            runtime.onTool = { [weak self] body in
                guard let self, self.archive.sessionID == runtimeSessionID else { throw PiError.message("助手已关闭") }
                return try await self.execute(body)
            }
            try runtime.load()
            for _ in 0..<100 {
                if runtime.isReady { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard runtime.isReady else { throw PiError.message("助手运行时启动失败") }
            let messages = try JSONSerialization.jsonObject(with: archive.runtime) as? [[String: Any]] ?? []
            try await runtime.initialize(baseURL: PersonalSettings.url(settings.modelBaseURL), apiKey: settings.modelKey, model: settings.modelName, today: RecordDate.key(Date()), sessionID: archive.sessionID, messages: messages)
        } catch { self.error = error.localizedDescription }
    }

    func saveDraft() {
        do { try save() } catch { self.error = error.localizedDescription }
    }

    func resetConversation(records: RecordStore) async throws {
        guard !isBusy else { throw PiError.message("请先停止当前请求再重置对话。") }
        isBusy = true
        defer { isBusy = false }
        // Load the correct persisted conversation even when reset is tapped
        // from the records page before the assistant panel has been opened.
        await prepare(records: records, loadOnly: true)
        if let error { throw PiError.message(error) }
        guard let file, archiveError == nil else { throw PiError.message("会话尚未就绪") }
        var next = archive
        next.draft = draft
        next.resetConversation(at: Date())
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        archive = next
        items = []
        selectedRecord = nil
        currentReplyID = nil
        error = nil
        bridge?.dispose()
        bridge = nil
    }

    func clearPreviousDayIfNeeded() {
        // Finish an in-flight turn first; the next turn must use the new day.
        guard !isBusy, !isOpening else { return }
        do { try rollOverIfNeeded() }
        catch { self.error = error.localizedDescription }
    }

    private func rollOverIfNeeded() throws {
        guard let file, archiveError == nil else { return }
        var next = archive
        next.draft = draft
        let newDay = next.rollOver(at: Date())
        let newTools = next.refreshToolset()
        guard newDay || newTools else { return }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        archive = next
        items = next.items
        selectedRecord = next.selectedRecord
        currentReplyID = nil
        error = nil
        bridge?.dispose()
        bridge = nil
    }

    private func save() throws {
        if let archiveError { throw PiError.message(archiveError) }
        guard let file else { UserDefaults.standard.set(draft, forKey: "personalAssistant.unassignedDraft"); return }
        archive.items = items
        archive.draft = draft
        archive.selectedRecord = selectedRecord
        try JSONEncoder().encode(archive).write(to: file, options: .atomic)
    }

    func send(records: RecordStore, textOverride: String? = nil, queryOverride: RecordQueryRequest? = nil) async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        defer { isBusy = false; clearPreviousDayIfNeeded() }
        let version = cancellationVersion
        let text = (textOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { error = "请输入 1–4000 字的记录或查询"; return }
        await prepare(records: records)
        guard !Task.isCancelled, version == cancellationVersion, error == nil, let bridge, bridge.isReady else { return }
        do {
            var prompt = text
            if textOverride == nil, let reference = selectedRecord {
                if reference.status != "待同步" { await records.sync() }
                let current = try records.referencedRecord(id: reference.id)
                guard records.error == nil || current.status == "待同步" else {
                    throw PiError.message("无法核对引用记录，请恢复网络并同步后再试。")
                }
                let context: [String: Any] = ["id": current.id, "activity": current.kind.rawValue, "amount": current.amount, "performedOn": current.performedOn]
                let json = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
                prompt += "\n用户在界面中引用的记录（仅用于定位目标，是否操作以用户指令为准）：" + String(decoding: json, as: UTF8.self)
            }
            guard !Task.isCancelled, version == cancellationVersion else { throw CancellationError() }
            // Refresh the date and sanitize any interrupted transcript before a new turn.
            let messages = try JSONSerialization.jsonObject(with: archive.runtime) as? [[String: Any]] ?? []
            try await bridge.initialize(baseURL: PersonalSettings.url(settings.modelBaseURL), apiKey: settings.modelKey, model: settings.modelName, today: RecordDate.key(Date()), sessionID: archive.sessionID, messages: messages)
            guard !Task.isCancelled, version == cancellationVersion else { throw CancellationError() }
            let referenceID = textOverride == nil ? selectedRecord?.id : nil
            let retry = archive.pendingText == text && archive.pendingRequestID != nil && archive.pendingReferenceID == referenceID && archive.pendingQuery == queryOverride
            let requestID = retry ? archive.pendingRequestID! : UUID().uuidString
            archive.pendingRequestID = requestID
            archive.pendingText = text
            archive.pendingReferenceID = referenceID
            archive.pendingQuery = queryOverride
            if !retry { items.append(ChatItem(role: "user", text: text)) }
            let reply = ChatItem(role: "assistant", text: "")
            currentReplyID = reply.id
            items.append(reply)
            try save()
            try await bridge.prompt(prompt, requestID: requestID)
            archive.pendingRequestID = nil
            archive.pendingText = nil
            archive.pendingReferenceID = nil
            archive.pendingQuery = nil
            if textOverride == nil, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draft = ""
                selectedRecord = nil
            }
            try save()
        } catch {
            self.error = error.localizedDescription
            if let id = currentReplyID, let index = items.firstIndex(where: { $0.id == id }), items[index].text.isEmpty {
                items[index].text = "处理未完成。输入已保留；已执行的记录可在趋势页核对。"
            }
            try? save()
        }
    }

    func suspend() {
        cancellationVersion += 1
        bridge?.cancel()
        saveDraft()
    }

    func resetRuntime(for records: RecordStore) {
        guard !isBusy else { return }
        bridge?.dispose()
        bridge = nil
        let settings = PersonalSettings.load()
        updateConfigurationStatus(settings)
        let nextIdentity = RecordStore.digest(records.endpointID + settings.modelBaseURL + settings.modelName)
        if !identity.isEmpty, nextIdentity != identity {
            saveDraft()
            identity = ""
            file = nil
            archive = ChatArchive()
            archiveError = nil
            items = []
            draft = ""
            selectedRecord = nil
            UserDefaults.standard.removeObject(forKey: "personalAssistant.unassignedDraft")
        }
    }

    private func updateConfigurationStatus(_ settings: PersonalSettings) {
        modelConfigured = !settings.modelBaseURL.isEmpty && !settings.modelKey.isEmpty && !settings.modelName.isEmpty
    }

    private func receive(_ event: [String: Any]) {
        if event["type"] as? String == "text", let text = event["text"] as? String,
           let id = currentReplyID, let index = items.firstIndex(where: { $0.id == id }) {
            items[index].text += text
        }
        if event["type"] as? String == "tool_result", let result = event["result"] as? [String: Any] {
            let details = result["details"] as? [String: Any]
            let encoded = details.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            items.append(ChatItem(role: "tool", text: text, result: encoded.map { String(decoding: $0, as: UTF8.self) }))
        }
    }

    #if DEBUG
    func previewResult(_ result: [String: Any]) {
        guard records?.endpointID == RecordStore.digest("https://visual-fixture.invalid") else { return }
        items = [ChatItem(role: "user", text: "过去一周练得怎么样？"), ChatItem(role: "tool", text: "", result: String(decoding: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), as: UTF8.self))]
    }
    #endif

    private func execute(_ body: [String: Any]) async throws -> [String: Any] {
        guard let records, let requestID = archive.pendingRequestID, let name = body["name"] as? String,
              let args = body["args"] as? [String: Any] else { throw PiError.message("工具请求无效") }
        if let query = archive.pendingQuery {
            guard name == "query_entries" else { throw PiError.message("刷新查询只能读取原日期范围，不能修改记录。") }
            return try await RecordToolService.execute(name: name, args: query.arguments, requestID: requestID, rawText: archive.pendingText ?? "刷新查询", records: records)
        }
        if let referenceID = archive.pendingReferenceID, ["update_entry", "delete_entry"].contains(name), args["id"] as? String != referenceID {
            throw PiError.message("操作目标与用户引用的记录不一致，请重新核对；未操作其他记录。")
        }
        return try await RecordToolService.execute(name: name, args: args, requestID: requestID, rawText: archive.pendingText ?? "文本记录", records: records)
    }
}
