import Foundation
import Observation
import WebKit

/// The only boundary between the bundled Pi runtime and native capabilities.
/// Nothing from a web page can choose credentials or arbitrary network hosts.
@MainActor
@Observable
final class PiBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private(set) var isReady = false
    private(set) var error: String?
    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored var onTool: (@MainActor ([String: Any]) async throws -> [String: Any])?
    @ObservationIgnored var onCheckpoint: (@MainActor ([String: Any]) throws -> Void)?
    @ObservationIgnored var onEvent: (@MainActor ([String: Any]) -> Void)?
    @ObservationIgnored var mockResponse: (@MainActor ([String: Any]) async throws -> String)?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var endpoint: URL?
    @ObservationIgnored private var apiKey = ""
    @ObservationIgnored private var session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        super.init()
        let configurationWK = WKWebViewConfiguration()
        configurationWK.websiteDataStore = .nonPersistent()
        configurationWK.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "pi")
        webView = WKWebView(frame: .zero, configuration: configurationWK)
        webView.navigationDelegate = self
    }

    func load() throws {
        isReady = false
        error = nil
        guard let url = Bundle.main.url(forResource: "runtime", withExtension: "js", subdirectory: "Agent")
                ?? Bundle.main.url(forResource: "runtime", withExtension: "js") else {
            throw PiError.message("缺少 Pi 运行时资源，请先运行 agent-runtime 的构建命令。")
        }
        let source = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "</script", with: "<\\/script")
        webView.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src 'none'">
        </head><body><script>\(source)</script></body></html>
        """, baseURL: nil)
    }

    func initialize(baseURL: URL, apiKey: String, model: String, today: String, sessionID: String, messages: [[String: Any]]) async throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw PiError.message("请输入有效的 HTTPS API 基础地址") }
        self.endpoint = baseURL.appendingPathComponent("chat/completions")
        self.apiKey = apiKey
        let config: [String: Any] = ["baseURL": baseURL.absoluteString, "model": model, "today": today, "sessionID": sessionID]
        _ = try await webView.callAsyncJavaScript("return PiRuntime.initialize(config, messages)", arguments: ["config": config, "messages": messages], in: nil, contentWorld: .page)
    }

    func prompt(_ text: String, requestID: String) async throws {
        _ = try await webView.callAsyncJavaScript("await PiRuntime.prompt(text, id); return true", arguments: ["text": text, "id": requestID], in: nil, contentWorld: .page)
    }

    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        webView.evaluateJavaScript("globalThis.PiRuntime?.abort()", completionHandler: nil)
    }

    func dispose() {
        cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pi", contentWorld: .page)
        session.invalidateAndCancel()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame, let raw = message.body as? String,
              let data = raw.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "Invalid bridge message")
        }
        do {
            let result = try await handle(body)
            let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return (String(decoding: encoded, as: UTF8.self), nil)
        } catch { return (nil, error.localizedDescription) }
    }

    private func handle(_ body: [String: Any]) async throws -> [String: Any] {
        switch body["type"] as? String {
        case "ready": isReady = true
        case "checkpoint": try onCheckpoint?(body)
        case "event": if let event = body["event"] as? [String: Any] { onEvent?(event) }
        case "tool":
            guard let onTool else { throw PiError.message("记录工具未连接") }
            return try await onTool(body)
        case "fetch_cancel":
            if let id = body["id"] as? String { tasks.removeValue(forKey: id)?.cancel() }
        case "fetch_start":
            guard let id = body["id"] as? String, tasks[id] == nil,
                  body["method"] as? String == "POST", let text = body["body"] as? String,
                  text.utf8.count <= 1_000_000, let urlText = body["url"] as? String,
                  let url = URL(string: urlText), url == endpoint else { throw PiError.message("拒绝未配置的模型请求") }
            tasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.tasks[id] = nil }
                do {
                    if let mockResponse {
                        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
                        let response = try await mockResponse(payload)
                        try Task.checkCancellation()
                        try await emit(["id": id, "kind": "head", "status": 200, "headers": ["content-type": "text/event-stream"]])
                        let bytes = Data(response.utf8)
                        for offset in stride(from: 0, to: bytes.count, by: 37) {
                            try Task.checkCancellation()
                            try await emit(["id": id, "kind": "chunk", "data": bytes.subdata(in: offset..<min(offset + 37, bytes.count)).base64EncodedString()])
                        }
                    } else {
                        guard !apiKey.isEmpty else { throw PiError.message("请配置模型 API Key") }
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.httpBody = Data(text.utf8)
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw PiError.message("模型响应无效") }
                        try await emit(["id": id, "kind": "head", "status": http.statusCode, "headers": ["content-type": http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"]])
                        var count = 0
                        var chunk = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            count += 1
                            guard count <= 4_000_000 else { throw PiError.message("模型响应超出大小限制") }
                            chunk.append(byte)
                            if byte == 10 || chunk.count >= 8192 {
                                try await emit(["id": id, "kind": "chunk", "data": chunk.base64EncodedString()])
                                chunk.removeAll(keepingCapacity: true)
                            }
                        }
                        if !chunk.isEmpty { try await emit(["id": id, "kind": "chunk", "data": chunk.base64EncodedString()]) }
                    }
                    try await emit(["id": id, "kind": "end"])
                } catch {
                    try? await emit(["id": id, "kind": "error", "error": error is CancellationError ? "请求已取消" : error.localizedDescription])
                }
            }
        default: throw PiError.message("未知桥接操作")
        }
        return ["ok": true]
    }

    private func emit(_ packet: [String: Any]) async throws {
        _ = try await webView.callAsyncJavaScript("PiRuntime.receive(packet); return true", arguments: ["packet": packet], in: nil, contentWorld: .page)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancel()
        isReady = false
        error = "助手运行环境已中断，重新打开助手可恢复历史。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
}

enum PiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { "助手发生错误" } }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
