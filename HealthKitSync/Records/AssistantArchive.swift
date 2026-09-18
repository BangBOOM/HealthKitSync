import Foundation

struct ChatItem: Codable, Identifiable {
    var id = UUID().uuidString
    let role: String
    var text: String
    var result: String?
}

struct ChatArchive: Codable {
    static let currentToolsetVersion = 2
    var toolsetVersion: Int? = currentToolsetVersion
    var sessionID = UUID().uuidString
    var sessionDay: String? = RecordDate.key(Date())
    var draft = UserDefaults.standard.string(forKey: "personalAssistant.unassignedDraft") ?? ""
    var items: [ChatItem] = []
    var runtime = Data("[]".utf8)
    var pendingRequestID: String?
    var pendingText: String?
    var selectedRecord: RecordRow?
    var pendingQuery: RecordQueryRequest?
    var pendingReferenceID: String?

    /// Old replies about missing tools are not authoritative after an upgrade.
    /// Keep the visible transcript, draft and retry receipts; rebuild model context.
    mutating func refreshToolset() -> Bool {
        guard toolsetVersion != Self.currentToolsetVersion else { return false }
        toolsetVersion = Self.currentToolsetVersion
        sessionID = UUID().uuidString
        runtime = Data("[]".utf8)
        return true
    }

    /// Retain retry identity independently of conversation history so a failed
    /// write cannot become a new write just because midnight passed.
    mutating func rollOver(at now: Date) -> Bool {
        let today = RecordDate.key(now)
        guard sessionDay != today else { return false }
        resetConversation(at: now)
        return true
    }

    mutating func resetConversation(at now: Date) {
        sessionID = UUID().uuidString
        sessionDay = RecordDate.key(now)
        toolsetVersion = Self.currentToolsetVersion
        items = []
        runtime = Data("[]".utf8)
        selectedRecord = nil
    }
}
