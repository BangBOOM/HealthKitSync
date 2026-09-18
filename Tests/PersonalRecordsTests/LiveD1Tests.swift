import XCTest
@testable import PersonalRecords

private actor DropFirstCreate: RecordTransport {
    private var dropped = false
    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        let data = try await HTTPRecordTransport().request(configuration, path: path, method: method, body: body, operationID: operationID)
        if method == "POST", !dropped { dropped = true; throw URLError(.networkConnectionLost) }
        return data
    }
}

final class LiveD1Tests: XCTestCase {
    @MainActor func testNativeToolsAgainstDisposableD1() async throws {
        guard let value = ProcessInfo.processInfo.environment["PERSONAL_RECORDS_TEST_URL"] else { throw XCTSkip("Run heatmap/worker/test/local-server.mjs and set PERSONAL_RECORDS_TEST_URL") }
        let url = try XCTUnwrap(URL(string: value))
        // This test is destructive only to its explicitly supplied loopback fixture.
        XCTAssertEqual(url.host, "127.0.0.1")
        guard url.host == "127.0.0.1" else { return }
        let configuration = RecordConfiguration(endpoint: url, token: "native-test-token", accessClientID: "", accessClientSecret: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordStore(directory: directory, transport: DropFirstCreate())
        try store.configure(configuration)
        let args: [String: Any] = ["entries": [
            ["activity": "pushups", "amount": 20, "performedOn": "2026-09-19"],
            ["activity": "plank", "amount": 90, "performedOn": "2026-09-19"],
        ]]
        let pending = try await RecordToolService.execute(name: "record_entries", args: args, requestID: "initial", rawText: "20个俯卧撑，平板一分钟半", records: store)
        XCTAssertEqual(pending["status"] as? String, "pending")
        XCTAssertEqual(store.rows.count, 2)
        let restarted = RecordStore(directory: directory)
        try restarted.configure(configuration)
        await restarted.sync()
        XCTAssertNil(restarted.error)
        XCTAssertEqual(restarted.rows.count, 2)
        let replay = try await RecordToolService.execute(name: "record_entries", args: args, requestID: "initial", rawText: "20个俯卧撑，平板一分钟半", records: restarted)
        XCTAssertEqual(replay["status"] as? String, "saved")
        let id = try XCTUnwrap(restarted.rows.first { $0.kind == .pushups }?.id)
        let edit = try await RecordToolService.execute(name: "update_entry", args: ["id": id, "amount": 30.0, "performedOn": "2026-09-19"], requestID: "correction", rawText: "改成30个", records: restarted)
        XCTAssertEqual(edit["status"] as? String, "saved")
        _ = try restarted.add([RecordIntent(activity: .pushups, amount: 60, performedOn: "2026-09-18")], rawText: "昨天三组每组20个", sourceID: "yesterday")
        _ = try restarted.add([RecordIntent(activity: .pushups, amount: 10, performedOn: "2026-09-19")], rawText: "又做了10个", sourceID: "another")
        await restarted.sync()
        let result = try await RecordToolService.execute(name: "query_entries", args: ["from": "2026-09-14", "to": "2026-09-20"], requestID: "weekly", rawText: "本周合计", records: restarted)
        XCTAssertEqual(result["totals"] as? [String: Double], ["pushups": 100, "plank": 90])
        XCTAssertEqual(restarted.snapshot.activities.count, 2, "Reuse existing categories")
        let deniedDirectory = directory.appendingPathComponent("denied")
        let denied = RecordStore(directory: deniedDirectory)
        try denied.configure(RecordConfiguration(endpoint: url, token: "wrong-token", accessClientID: "", accessClientSecret: ""))
        _ = try denied.add([RecordIntent(activity: .pushups, amount: 999, performedOn: "2026-09-19")], rawText: "denied fixture", sourceID: "denied")
        await denied.sync()
        XCTAssertTrue(denied.error?.contains("401") == true)
        XCTAssertEqual(denied.snapshot.operations.first?.state, .pending)
        let remote = try await HTTPRecordTransport().request(configuration, path: "api/entries", method: "GET", body: nil, operationID: nil)
        struct Entries: Decodable { let entries: [FitnessEntry] }
        XCTAssertEqual(try JSONDecoder().decode(Entries.self, from: remote).entries.count, 4)
    }
}
