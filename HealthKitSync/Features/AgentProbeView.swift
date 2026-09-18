#if DEBUG
import SwiftUI
import WebKit

/// Isolated compatibility gate. All network and record results are fixtures.
struct AgentProbeView: View {
    @State private var bridge = PiBridge()
    @State private var report = "准备验证…"
    @State private var messages: [[String: Any]] = []
    @State private var records: RecordStore?
    @State private var transport = ProbeRecordTransport()
    @State private var folder = FileManager.default.temporaryDirectory.appendingPathComponent("PiProbe-" + UUID().uuidString)
    @State private var requestID = "probe-create"
    @State private var calls = 0
    @State private var chunks = 0

    var body: some View {
        VStack {
            Text("Pi 本机兼容性验证").font(.title2)
            ScrollView { Text(report).font(.system(.body, design: .monospaced)) }
            ProbeWebView(webView: bridge.webView).frame(width: 1, height: 1).opacity(0.01)
        }.padding().task { await run() }
    }

    private func run() async {
        do {
            let store = RecordStore(directory: folder, transport: transport)
            try store.configure(probeConfiguration)
            records = store
            installCallbacks()
            try bridge.load()
            try await ready()
            report = "运行时已加载，初始化…"
            try await initialize()
            report = "初始化完成，验证新增…"
            try await bridge.prompt("今天20个俯卧撑，平板90秒", requestID: "probe-create")
            guard store.rows.count == 2, store.snapshot.operations.first?.state == .inFlight, calls == 1, chunks > 0 else { throw PiError.message("新增或流式输出验证失败") }
            await store.sync()
            guard store.snapshot.operations.first?.state == .complete, await transport.writes == 1 else { throw PiError.message("丢失响应去重失败") }
            report = "PASS：Pi 浏览器打包 / Swift 工具调用 / 中文流式回复\n"
            report += "PASS：原生记录操作 / 本地持久化 / 丢失响应核对无重复\n"
            // Recreate the WebKit process-facing runtime, restore the saved transcript.
            bridge.dispose()
            bridge = PiBridge()
            let restored = RecordStore(directory: folder, transport: transport)
            try restored.configure(probeConfiguration)
            records = restored
            messages = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("conversation.json"))) as? [[String: Any]] ?? []
            installCallbacks()
            try bridge.load()
            try await ready()
            try await initialize()
            requestID = "probe-update"
            try await bridge.prompt("刚才俯卧撑改成30个", requestID: "probe-update")
            guard restored.rows.first(where: { $0.kind == .pushups })?.amount == 30, restored.rows.first(where: { $0.kind == .plank })?.amount == 90, calls == 2 else { throw PiError.message("恢复后纠正验证失败") }
            report += "PASS：运行环境重建 / 对话恢复 / 多轮纠正 / 无重复执行\n"
            requestID = "probe-query"
            try await bridge.prompt("查本周合计", requestID: requestID)
            let totals = try restored.query(from: "2026-09-14", to: "2026-09-20")["totals"] as? [String: Double]
            guard totals == ["pushups": 30, "plank": 90], calls == 3 else { throw PiError.message("查询统计验证失败") }
            report += "PASS：查询与原生统计\n"
            bridge.mockResponse = { _ in try await Task.sleep(for: .seconds(30)); return "" }
            let task = Task { try await bridge.prompt("取消验证", requestID: "probe-cancel") }
            try await Task.sleep(for: .milliseconds(300))
            bridge.cancel()
            do { try await task.value; throw PiError.message("取消没有中断请求") }
            catch { if case PiError.message("取消没有中断请求") = error { throw error } }
            report += "PASS：取消\nPI_PROBE_PASS"
            finish(success: true)
        } catch {
            report += "\nPI_PROBE_FAIL：\(error.localizedDescription)\n\((error as NSError).userInfo)"
            finish(success: false)
        }
    }

    private func installCallbacks() {
        bridge.onCheckpoint = { body in
            messages = body["messages"] as? [[String: Any]] ?? []
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: messages).write(to: folder.appendingPathComponent("conversation.json"), options: .atomic)
        }
        bridge.onEvent = { event in
            if event["type"] as? String == "text" { chunks += 1 }
            if event["type"] as? String == "transport_error" { print("Probe transport: \(event["text"] ?? "")") }
        }
        bridge.onTool = { body in
            calls += 1
            let args = body["args"] as? [String: Any] ?? [:]
            guard let records, let name = body["name"] as? String else { throw PiError.message("Missing probe tool") }
            return try await RecordToolService.execute(name: name, args: args, requestID: requestID, rawText: "今天20个俯卧撑，平板90秒", records: records)
        }
        bridge.mockResponse = { payload in
            let history = payload["messages"] as? [[String: Any]] ?? []
            if history.last?["role"] as? String == "tool" {
                return try sse(delta: ["content": "记录状态见结果卡片。"], finish: "stop")
            }
            if requestID == "probe-query" { return try sseTool(name: "query_entries", id: "call-query", args: ["from": "2026-09-14", "to": "2026-09-20"]) }
            if history.contains(where: { ($0["role"] as? String) == "tool" }) {
                return try sseTool(name: "update_entry", id: "call-update", args: ["id": "probe-pushups", "amount": 30, "performedOn": "2026-09-19"])
            }
            return try sseTool(name: "record_entries", id: "call-create", args: ["rawText": "今天20个俯卧撑，平板90秒", "entries": [["activity": "pushups", "amount": 20, "performedOn": "2026-09-19"], ["activity": "plank", "amount": 90, "performedOn": "2026-09-19"]]])
        }
    }

    private func initialize() async throws {
        try await bridge.initialize(baseURL: URL(string: "https://probe.invalid/v1")!, apiKey: "", model: "probe", today: "2026-09-19", sessionID: "probe", messages: messages)
    }

    private var probeConfiguration: RecordConfiguration {
        RecordConfiguration(endpoint: URL(string: "https://probe.invalid")!, token: "fixture", accessClientID: "", accessClientSecret: "")
    }

    private func ready() async throws {
        for _ in 0..<100 {
            if bridge.isReady { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PiError.message("Pi 运行时 10 秒内未启动")
    }

    private func sseTool(name: String, id: String, args: [String: Any]) throws -> String {
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return try sse(delta: ["tool_calls": [["index": 0, "id": id, "type": "function", "function": ["name": name, "arguments": raw]]]], finish: "tool_calls")
    }

    private func sse(delta: [String: Any], finish: String) throws -> String {
        let first: [String: Any] = ["id": "probe", "object": "chat.completion.chunk", "created": 1, "model": "probe", "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]]
        let last: [String: Any] = ["id": "probe", "object": "chat.completion.chunk", "created": 1, "model": "probe", "choices": [["index": 0, "delta": [:], "finish_reason": finish]]]
        return try [first, last].map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined() + "data: [DONE]\n\n"
    }

    private func finish(success: Bool) {
        print(report)
        let result: [String: Any] = ["success": success, "report": report, "toolCalls": calls, "textChunks": chunks, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion]
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("pi-probe-result.json"), options: .atomic)
        }
    }
}

private struct ProbeWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Deterministic server fixture. Never reads the user's configuration or data.
private actor ProbeRecordTransport: RecordTransport {
    private var receipts: [String: Data] = [:]
    private var entries: [[String: Any]] = []
    private(set) var writes = 0
    private let activities: [[String: Any]] = [
        ["id": "pushups", "slug": "俯卧撑", "label": "俯卧撑", "metricKind": "count", "unit": "reps", "createdAt": "2026-09-19T00:00:00Z"],
        ["id": "plank", "slug": "平板支撑", "label": "平板支撑", "metricKind": "duration", "unit": "seconds", "createdAt": "2026-09-19T00:00:00Z"],
    ]

    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        if path == "api/activities" { return try encode(["activities": activities]) }
        if path == "api/entries" { return try encode(["entries": entries]) }
        if path.hasPrefix("api/operations/") {
            guard let result = receipts[String(path.dropFirst("api/operations/".count))] else { throw RecordError.http(404, "operation_not_found") }
            return try encode(["response": JSONSerialization.jsonObject(with: result)])
        }
        guard let operationID, let body, let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw RecordError.message("Invalid fixture request") }
        if let result = receipts[operationID] { return result }
        writes += 1
        let result: Data
        if method == "PATCH" {
            let id = String(path.dropFirst("api/entries/".count))
            guard let index = entries.firstIndex(where: { $0["id"] as? String == id }) else { throw RecordError.http(404, "missing entry") }
            entries[index]["amount"] = payload["amount"]
            entries[index]["performedOn"] = payload["performedOn"]
            result = try encode(["entry": entries[index]])
        } else {
            let added = (payload["entries"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
                let activity = item["activityId"] as! String
                return ["id": "probe-" + activity, "batchId": operationID, "activityId": activity, "amount": item["amount"]!, "performedOn": item["performedOn"]!, "isEstimated": false, "rawText": payload["rawText"]!, "createdAt": "2026-09-19T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"]
            }
            entries += added
            result = try encode(["entries": added])
        }
        receipts[operationID] = result
        if writes == 1 { throw URLError(.networkConnectionLost) }
        return result
    }

    private func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
#endif
