import Foundation

struct ChatItem: Codable, Identifiable {
    var id = UUID().uuidString
    let role: String
    var text: String
    var result: String?
}

struct ChatArchive: Codable {
    var sessionID = UUID().uuidString
    var sessionDay: String? = RecordDate.key(Date())
    var draft = UserDefaults.standard.string(forKey: "personalAssistant.unassignedDraft") ?? ""
    var items: [ChatItem] = []
    var runtime = Data("[]".utf8)
    var pendingRequestID: String?
    var pendingText: String?

    /// Retain retry identity independently of conversation history so a failed
    /// write cannot become a new write just because midnight passed.
    mutating func rollOver(at now: Date) -> Bool {
        let today = RecordDate.key(now)
        guard sessionDay != today else { return false }
        sessionID = UUID().uuidString
        sessionDay = today
        items = []
        runtime = Data("[]".utf8)
        return true
    }
}
