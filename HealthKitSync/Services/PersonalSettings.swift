import Foundation

struct PersonalSettings: Codable {
    var heatmapURL = ""
    var heatmapToken = ""
    var accessClientID = ""
    var accessClientSecret = ""
    var modelBaseURL = ""
    var modelKey = ""
    var modelName = ""

    static func load() -> Self {
        (try? JSONDecoder().decode(Self.self, from: Data(KeychainStore.read(account: "personal-settings").utf8))) ?? Self()
    }

    func save() throws {
        if !heatmapURL.isEmpty {
            _ = try recordConfiguration()
            guard !heatmapToken.isEmpty else { throw RecordError.message("请输入 heatmap API Token") }
        }
        guard accessClientID.isEmpty == accessClientSecret.isEmpty else { throw RecordError.message("Cloudflare Access ID 和 Secret 需要同时填写") }
        if !modelBaseURL.isEmpty {
            _ = try Self.url(modelBaseURL)
            guard !modelKey.isEmpty, !modelName.isEmpty else { throw RecordError.message("请填写模型 API Key 和模型名") }
        }
        try KeychainStore.save(String(decoding: JSONEncoder().encode(self), as: UTF8.self), account: "personal-settings")
    }

    func recordConfiguration() throws -> RecordConfiguration? {
        guard !heatmapURL.isEmpty else { return nil }
        return RecordConfiguration(endpoint: try Self.url(heatmapURL), token: heatmapToken, accessClientID: accessClientID, accessClientSecret: accessClientSecret)
    }

    static func url(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw RecordError.message("请输入不含用户名、查询参数的 HTTPS 基础地址")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw RecordError.message("服务地址无效") }
        return url
    }
}
