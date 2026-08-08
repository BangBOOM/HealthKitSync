import Foundation

struct UploadClient: Sendable {
    let endpoint: URL
    let token: String

    func upload(_ workout: WorkoutUpload) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(workout)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let message = parseServerError(from: data)
            throw UploadError.rejected((response as? HTTPURLResponse)?.statusCode, message)
        }
    }

    private var uploadURL: URL {
        guard endpoint.path.isEmpty || endpoint.path == "/" else {
            return endpoint
        }
        return endpoint.appendingPathComponent("v1/activities")
    }

    enum UploadError: LocalizedError {
        case rejected(Int?, String?)
        var errorDescription: String? {
            switch self {
            case .rejected(let code, let message):
                let status = code.map { "HTTP \($0)" } ?? "未知状态"
                return [status, message].compactMap { $0 }.joined(separator: "：")
            }
        }
    }

    private func parseServerError(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let error = object["error"] as? String
        let fields = object["fields"] as? [String]
        if let fields, !fields.isEmpty {
            return [error, fields.joined(separator: ", ")].compactMap { $0 }.joined(separator: " — ")
        }
        return error
    }
}
