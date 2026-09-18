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

    private func prepare(records: RecordStore) async {
        while isOpening {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        isOpening = true
        defer { isOpening = false }
        error = nil
        do {
            self.records = records
            settings = .load()
            guard !settings.modelBaseURL.isEmpty, !settings.modelKey.isEmpty, !settings.modelName.isEmpty else {
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
                draft = initialDraft.isEmpty ? archive.draft : initialDraft
                UserDefaults.standard.removeObject(forKey: "personalAssistant.unassignedDraft")
            }
            if let archiveError { throw PiError.message(archiveError) }
            try rollOverIfNeeded()
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
        guard next.rollOver(at: Date()) else { return }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        archive = next
        items = []
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
        try JSONEncoder().encode(archive).write(to: file, options: .atomic)
    }

    func send(records: RecordStore) async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        defer { isBusy = false; clearPreviousDayIfNeeded() }
        let version = cancellationVersion
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { error = "请输入 1–4000 字的记录或查询"; return }
        await prepare(records: records)
        guard !Task.isCancelled, version == cancellationVersion, error == nil, let bridge, bridge.isReady else { return }
        do {
            // Refresh the date and sanitize any interrupted transcript before a new turn.
            let messages = try JSONSerialization.jsonObject(with: archive.runtime) as? [[String: Any]] ?? []
            try await bridge.initialize(baseURL: PersonalSettings.url(settings.modelBaseURL), apiKey: settings.modelKey, model: settings.modelName, today: RecordDate.key(Date()), sessionID: archive.sessionID, messages: messages)
            let retry = archive.pendingText == text && archive.pendingRequestID != nil
            let requestID = retry ? archive.pendingRequestID! : UUID().uuidString
            archive.pendingRequestID = requestID
            archive.pendingText = text
            if !retry { items.append(ChatItem(role: "user", text: text)) }
            let reply = ChatItem(role: "assistant", text: "")
            currentReplyID = reply.id
            items.append(reply)
            try save()
            try await bridge.prompt(text, requestID: requestID)
            archive.pendingRequestID = nil
            archive.pendingText = nil
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            try save()
        } catch {
            self.error = error.localizedDescription
            if let id = currentReplyID, let index = items.firstIndex(where: { $0.id == id }), items[index].text.isEmpty {
                items[index].text = "处理未完成。输入已保留；已执行的记录可在记录页核对。"
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
        let nextIdentity = RecordStore.digest(records.endpointID + settings.modelBaseURL + settings.modelName)
        if !identity.isEmpty, nextIdentity != identity {
            saveDraft()
            identity = ""
            file = nil
            archive = ChatArchive()
            archiveError = nil
            items = []
            draft = ""
            UserDefaults.standard.removeObject(forKey: "personalAssistant.unassignedDraft")
        }
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

    private func execute(_ body: [String: Any]) async throws -> [String: Any] {
        guard let records, let requestID = archive.pendingRequestID, let name = body["name"] as? String,
              let args = body["args"] as? [String: Any] else { throw PiError.message("工具请求无效") }
        return try await RecordToolService.execute(name: name, args: args, requestID: requestID, rawText: archive.pendingText ?? "文本记录", records: records)
    }
}
