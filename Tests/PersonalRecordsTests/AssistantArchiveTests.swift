import XCTest
@testable import PersonalRecords

final class AssistantArchiveTests: XCTestCase {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testShanghaiMidnightClearsContextButRetainsDraftAndRetryIdentity() throws {
        var archive = ChatArchive()
        archive.sessionDay = "2026-09-19"
        archive.draft = "还没写完"
        archive.items = [ChatItem(role: "user", text: "20个俯卧撑")]
        archive.runtime = Data("[{\"role\":\"user\"}]".utf8)
        archive.pendingRequestID = "stable-request"
        archive.pendingText = "20个俯卧撑"
        let oldSession = archive.sessionID

        XCTAssertFalse(archive.rollOver(at: date("2026-09-19T15:59:59Z")))
        XCTAssertEqual(archive.items.count, 1)
        XCTAssertTrue(archive.rollOver(at: date("2026-09-19T16:00:00Z")))
        XCTAssertEqual(archive.sessionDay, "2026-09-20")
        XCTAssertNotEqual(archive.sessionID, oldSession)
        XCTAssertTrue(archive.items.isEmpty)
        XCTAssertEqual(archive.runtime, Data("[]".utf8))
        XCTAssertEqual(archive.draft, "还没写完")
        XCTAssertEqual(archive.pendingRequestID, "stable-request")
        XCTAssertEqual(archive.pendingText, "20个俯卧撑")

        var restored = try JSONDecoder().decode(ChatArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertFalse(restored.rollOver(at: date("2026-09-20T02:00:00Z")))
        XCTAssertEqual(restored.sessionID, archive.sessionID)
        XCTAssertTrue(restored.rollOver(at: date("2026-09-23T02:00:00Z")))
    }

    func testLegacyArchiveWithoutDayRemainsDecodable() throws {
        var archive = ChatArchive()
        archive.items = [ChatItem(role: "assistant", text: "已保存")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        object.removeValue(forKey: "sessionDay")
        var decoded = try JSONDecoder().decode(ChatArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sessionDay)
        // The store infers the legacy day from the archive's modification date.
        decoded.sessionDay = "2026-09-18"
        XCTAssertTrue(decoded.rollOver(at: date("2026-09-19T02:00:00Z")))
        XCTAssertTrue(decoded.items.isEmpty)
    }
}
