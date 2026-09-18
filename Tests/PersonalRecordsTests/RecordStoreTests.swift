import XCTest
@testable import PersonalRecords

private actor FixtureTransport: RecordTransport {
    var dropResponse = true
    var writes = 0
    var operations: [String: Data] = [:]
    var entries: [[String: Any]] = []
    let activity: [String: Any] = ["id": "pushups", "slug": "俯卧撑", "label": "俯卧撑", "metricKind": "count", "unit": "reps", "createdAt": "2026-09-19T00:00:00Z"]

    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        if path == "api/activities" { return try JSONSerialization.data(withJSONObject: ["activities": [activity]]) }
        if path == "api/entries" { return try JSONSerialization.data(withJSONObject: ["entries": entries]) }
        if path.hasPrefix("api/operations/") {
            let id = String(path.dropFirst("api/operations/".count))
            guard let data = operations[id] else { throw RecordError.http(404, "operation_not_found") }
            return try JSONSerialization.data(withJSONObject: ["response": JSONSerialization.jsonObject(with: data)])
        }
        guard let operationID else { throw RecordError.message("Missing operation ID") }
        if let result = operations[operationID] { return result }
        writes += 1
        let entry: [String: Any] = ["id": "entry-1", "batchId": "batch-1", "activityId": "pushups", "performedOn": "2026-09-19", "amount": 20, "isEstimated": false, "rawText": "20个俯卧撑", "createdAt": "2026-09-19T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"]
        entries = [entry]
        let data = try JSONSerialization.data(withJSONObject: ["entries": [entry]])
        operations[operationID] = data
        if dropResponse { dropResponse = false; throw URLError(.networkConnectionLost) }
        return data
    }
}

final class RecordStoreTests: XCTestCase {
    @MainActor func testLostResponseSurvivesRestartWithoutDuplicateWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureTransport()
        let config = RecordConfiguration(endpoint: URL(string: "https://test.invalid")!, token: "test", accessClientID: "", accessClientSecret: "")
        let first = RecordStore(directory: directory, transport: transport)
        try first.configure(config)
        let intents = [RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")]
        let id = try first.add(intents, rawText: "20个俯卧撑", sourceID: "same-request")
        XCTAssertEqual(try first.add(intents, rawText: "20个俯卧撑", sourceID: "same-request"), id)
        XCTAssertThrowsError(try first.add([RecordIntent(activity: .pushups, amount: 30, performedOn: "2026-09-19")], rawText: "30个", sourceID: "same-request"))
        await first.sync()
        XCTAssertEqual(first.snapshot.operations.first?.state, .inFlight)
        XCTAssertEqual(first.rows.count, 1)
        do { _ = try await first.update(id: first.rows[0].id, amount: 30, performedOn: "2026-09-19", sourceID: "unsafe-update"); XCTFail("Must reconcile before editing") }
        catch { /* expected: the remote outcome is still unknown */ }
        let restored = RecordStore(directory: directory, transport: transport)
        try restored.configure(config)
        await restored.sync()
        XCTAssertEqual(restored.snapshot.operations.first?.state, .complete)
        XCTAssertEqual(restored.rows.count, 1)
        XCTAssertEqual(restored.rows.first?.id, "entry-1")
        let writes = await transport.writes
        XCTAssertEqual(writes, 1)
        let totals = try restored.query(from: "2026-09-19", to: "2026-09-19")["totals"] as? [String: Double]
        XCTAssertEqual(totals?["pushups"], 20)
    }

    @MainActor func testEndpointIsolationAndValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordStore(directory: directory, transport: FixtureTransport())
        let a = RecordConfiguration(endpoint: URL(string: "https://a.invalid")!, token: "a", accessClientID: "", accessClientSecret: "")
        let b = RecordConfiguration(endpoint: URL(string: "https://b.invalid")!, token: "b", accessClientID: "", accessClientSecret: "")
        try store.configure(a)
        _ = try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")], rawText: "20个", sourceID: "one")
        try store.configure(b)
        XCTAssertTrue(store.rows.isEmpty)
        try store.configure(a)
        XCTAssertEqual(store.rows.count, 1)
        _ = try await store.update(id: store.rows[0].id, amount: 25, performedOn: "2026-09-18", sourceID: "local-edit")
        XCTAssertEqual(store.rows.first?.amount, 25)
        XCTAssertEqual(store.rows.first?.performedOn, "2026-09-18")
        XCTAssertEqual(store.snapshot.operations.count, 1)
        XCTAssertThrowsError(try RecordIntent(activity: .pushups, amount: 1.5, performedOn: "2026-09-19").validate())
        XCTAssertThrowsError(try RecordIntent(activity: .plank, amount: 90, performedOn: "2026-02-30").validate())
        XCTAssertEqual(RecordDate.key(Date(timeIntervalSince1970: 1789747200)), "2026-09-19")
    }

    @MainActor func testCorruptCacheIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(string: "https://corrupt.invalid")!
        let file = directory.appendingPathComponent(RecordStore.digest(url.absoluteString) + ".json")
        let invalid = Data("incomplete-json".utf8)
        try invalid.write(to: file)
        let store = RecordStore(directory: directory, transport: FixtureTransport())
        try store.configure(RecordConfiguration(endpoint: url, token: "test", accessClientID: "", accessClientSecret: ""))
        XCTAssertNotNil(store.error)
        await store.sync()
        XCTAssertThrowsError(try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")], rawText: "20", sourceID: "new"))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
}
