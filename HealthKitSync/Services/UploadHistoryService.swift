import Foundation
import Observation

struct ActivityExistenceClient: Sendable {
    let endpoint: URL
    let token: String

    func existingIDs(in ids: [UUID]) async throws -> Set<UUID> {
        var existing = Set<UUID>()
        for batch in ids.chunked(maxCount: 500) {
            var request = URLRequest(url: existenceURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                ExistenceRequest(healthKitUUIDs: batch.map(\.uuidString))
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw ExistenceError.rejected((response as? HTTPURLResponse)?.statusCode)
            }
            let decoded = try JSONDecoder().decode(ExistenceResponse.self, from: data)
            existing.formUnion(decoded.healthKitUUIDs.compactMap(UUID.init(uuidString:)))
        }
        return existing
    }

    private var existenceURL: URL {
        let uploadURL = (endpoint.path.isEmpty || endpoint.path == "/")
            ? endpoint.appendingPathComponent("v1/activities")
            : endpoint
        return uploadURL.appendingPathComponent("existence")
    }

    private struct ExistenceRequest: Encodable {
        let healthKitUUIDs: [String]

        enum CodingKeys: String, CodingKey {
            case healthKitUUIDs = "healthkit_uuids"
        }
    }

    private struct ExistenceResponse: Decodable {
        let healthKitUUIDs: [String]

        enum CodingKeys: String, CodingKey {
            case healthKitUUIDs = "healthkit_uuids"
        }
    }

    enum ExistenceError: LocalizedError {
        case rejected(Int?)

        var errorDescription: String? {
            switch self {
            case .rejected(let code):
                let status = code.map { "HTTP \($0)" } ?? "未知状态"
                return "无法检查远端上传记录：\(status)"
            }
        }
    }
}

@MainActor
@Observable
final class UploadHistoryService {
    private(set) var uploadedIDs = Set<UUID>()
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var syncError: String?

    private let defaults = UserDefaults.standard
    private let endpointCacheKey = "uploadHistoryEndpoint"
    private let idsCacheKey = "uploadedHealthKitUUIDs"

    func contains(_ id: UUID) -> Bool {
        uploadedIDs.contains(id)
    }

    func refresh(localIDs: [UUID]) async {
        let endpointText = KeychainStore.read(account: "endpoint")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = KeychainStore.read(account: "token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: endpointText), !token.isEmpty else {
            uploadedIDs = []
            syncError = nil
            return
        }

        loadCache(for: endpoint.absoluteString)
        guard !localIDs.isEmpty else {
            uploadedIDs = []
            syncError = nil
            return
        }

        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let client = ActivityExistenceClient(endpoint: endpoint, token: token)
            uploadedIDs = try await client.existingIDs(in: localIDs)
            lastSyncedAt = Date()
            saveCache(for: endpoint.absoluteString)
        } catch is CancellationError {
            return
        } catch {
            syncError = error.localizedDescription
        }
    }

    func markUploaded(_ id: UUID) {
        uploadedIDs.insert(id)
        let endpoint = KeychainStore.read(account: "endpoint")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty { saveCache(for: endpoint) }
    }

    private func loadCache(for endpoint: String) {
        guard defaults.string(forKey: endpointCacheKey) == endpoint else {
            uploadedIDs = []
            return
        }
        uploadedIDs = Set(
            defaults.stringArray(forKey: idsCacheKey)?.compactMap(UUID.init(uuidString:)) ?? []
        )
    }

    private func saveCache(for endpoint: String) {
        defaults.set(endpoint, forKey: endpointCacheKey)
        defaults.set(uploadedIDs.map(\.uuidString).sorted(), forKey: idsCacheKey)
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maxCount).map {
            Array(self[$0..<Swift.min($0 + maxCount, count)])
        }
    }
}
