import Foundation

protocol RecordTransport: Sendable {
    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data
}

struct HTTPRecordTransport: RecordTransport {
    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 25
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let operationID { request.setValue(operationID, forHTTPHeaderField: "Idempotency-Key") }
        if !configuration.accessClientID.isEmpty {
            request.setValue(configuration.accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(configuration.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        let session = URLSession(configuration: .ephemeral, delegate: RecordRedirectBlocker(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RecordError.message("数据服务响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw RecordError.http(http.statusCode, object?["error"] as? String ?? "请检查服务地址、Token 和 Cloudflare Access 配置")
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true else {
            throw RecordError.message("服务没有返回 JSON，请检查 Cloudflare Access 配置")
        }
        return data
    }
}

private final class RecordRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
