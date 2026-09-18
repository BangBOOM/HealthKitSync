import XCTest
@testable import PersonalRecords

private actor WaitingTransport: RecordTransport {
    var calls = 0
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        calls += 1
        try await Task.sleep(for: delay)
        throw URLError(.timedOut)
    }
}

private actor FixtureTransport: RecordTransport {
    var dropResponse = true
    var writes = 0
    var legacyOperationAPI = false
    var entryReads = 0
    var deleteDropsResponse = false
    var submittedBody: Data?
    var operations: [String: Data] = [:]
    var entries: [[String: Any]] = []
    let activity: [String: Any] = ["id": "pushups", "slug": "俯卧撑", "label": "俯卧撑", "metricKind": "count", "unit": "reps", "createdAt": "2026-09-19T00:00:00Z"]

    func setLegacy(_ value: Bool) { legacyOperationAPI = value }
    func keepResponses() { dropResponse = false }
    func loseDeleteResponse() { deleteDropsResponse = true }

    func request(_ configuration: RecordConfiguration, path: String, method: String, body: Data?, operationID: String?) async throws -> Data {
        if path == "api/activities" { return try JSONSerialization.data(withJSONObject: ["activities": [activity]]) }
        if path == "api/entries" { entryReads += 1; return try JSONSerialization.data(withJSONObject: ["entries": entries]) }
        if method == "DELETE" {
            let deleted = entries.removeFirst()
            if deleteDropsResponse { throw URLError(.networkConnectionLost) }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "deleted": deleted])
        }
        if path.hasPrefix("api/operations/") {
            if legacyOperationAPI { throw RecordError.http(404, "Not found") }
            let id = String(path.dropFirst("api/operations/".count))
            guard let data = operations[id] else { throw RecordError.http(404, "operation_not_found") }
            return try JSONSerialization.data(withJSONObject: ["response": JSONSerialization.jsonObject(with: data)])
        }
        guard let operationID else { throw RecordError.message("Missing operation ID") }
        if let result = operations[operationID] { return result }
        writes += 1
        submittedBody = body
        let entry: [String: Any] = ["id": "entry-1", "batchId": "batch-1", "activityId": "pushups", "performedOn": "2026-09-19", "amount": 20, "isEstimated": false, "rawText": "20个俯卧撑", "createdAt": "2026-09-19T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"]
        entries = [entry]
        let data = try JSONSerialization.data(withJSONObject: ["entries": [entry]])
        operations[operationID] = data
        if dropResponse { dropResponse = false; throw URLError(.networkConnectionLost) }
        return data
    }
}

final class RecordStoreTests: XCTestCase {
    @MainActor func testAssistantDeletionUsesPersistentReceiptAndRejectsBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = RecordConfiguration(endpoint: URL(string: "https://agent-delete.invalid")!, token: "test", accessClientID: "", accessClientSecret: "")
        let transport = FixtureTransport()
        await transport.keepResponses()
        let store = RecordStore(directory: directory, transport: transport)
        try store.configure(config)
        _ = try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")], rawText: "test", sourceID: "one")
        await store.sync()
        let result = try await RecordToolService.execute(name: "delete_entry", args: ["id": "entry-1"], requestID: "delete-request", rawText: "删除这条", records: store)
        XCTAssertEqual(result["status"] as? String, "deleted")
        XCTAssertTrue(store.rows.isEmpty)
        let restored = RecordStore(directory: directory, transport: transport)
        try restored.configure(config)
        let replay = try await RecordToolService.execute(name: "delete_entry", args: ["id": "entry-1"], requestID: "delete-request", rawText: "删除这条", records: restored)
        XCTAssertEqual(replay["status"] as? String, "deleted")
        let local = try restored.add([RecordIntent(activity: .plank, amount: 90, performedOn: "2026-09-19")], rawText: "test", sourceID: "two") + ":0"
        do {
            _ = try await RecordToolService.execute(name: "delete_entry", args: ["id": local], requestID: "delete-request", rawText: "test", records: restored)
            XCTFail("A second target in the same input must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("一条")) }
        XCTAssertEqual(restored.rows.count, 1)
        let deletedLocal = try await RecordToolService.execute(name: "delete_entry", args: ["id": local], requestID: "next-request", rawText: "删除平板", records: restored)
        XCTAssertEqual(deletedLocal["status"] as? String, "deleted")
        XCTAssertTrue(restored.rows.isEmpty)
        do {
            _ = try await RecordToolService.execute(name: "delete_entry", args: [:], requestID: "invalid", rawText: "test", records: restored)
            XCTFail("Missing ID must be rejected")
        } catch { }
    }

    @MainActor func testConcurrentStartupSyncDoesNotRetryAfterTimeout() async throws {
        let transport = WaitingTransport(delay: .milliseconds(100))
        let store = RecordStore(transport: transport)
        try store.configure(RecordConfiguration(endpoint: URL(string: "https://timeout.invalid")!, token: "test", accessClientID: "", accessClientSecret: ""))
        let first = Task { await store.sync() }
        while !store.isSyncing { await Task.yield() }
        await store.sync()
        await first.value
        XCTAssertFalse(store.isSyncing)
        XCTAssertFalse(store.canCancelSync)
        XCTAssertTrue(store.error?.contains("超时") == true)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testCancelStalledSyncReleasesState() async throws {
        let transport = WaitingTransport(delay: .seconds(300))
        let store = RecordStore(transport: transport)
        try store.configure(RecordConfiguration(endpoint: URL(string: "https://cancel-sync.invalid")!, token: "test", accessClientID: "", accessClientSecret: ""))
        let work = Task { await store.sync() }
        while !store.isSyncing { await Task.yield() }
        store.cancelSync()
        await work.value
        XCTAssertFalse(store.isSyncing)
        XCTAssertFalse(store.canCancelSync)
        XCTAssertEqual(store.syncStatus, "")
        XCTAssertTrue(store.error?.contains("已停止") == true)
    }

    @MainActor func testLocalDeletionPersistsAndPreservesOtherItemIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureTransport()
        await transport.keepResponses()
        let config = RecordConfiguration(endpoint: URL(string: "https://delete.invalid")!, token: "test", accessClientID: "", accessClientSecret: "")
        let store = RecordStore(directory: directory, transport: transport)
        try store.configure(config)
        let intents = [RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19"), RecordIntent(activity: .plank, amount: 90, performedOn: "2026-09-19")]
        let operation = try store.add(intents, rawText: "test", sourceID: "one")
        try await store.delete(id: operation + ":0")
        let restored = RecordStore(directory: directory, transport: transport)
        try restored.configure(config)
        XCTAssertEqual(restored.rows.map(\.id), [operation + ":1"])
        XCTAssertEqual(try restored.add(intents, rawText: "test", sourceID: "one"), operation)
        XCTAssertEqual(restored.rows.count, 1)
        await restored.sync()
        let body = await transport.submittedBody
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["amount"] as? Double, 90)
    }

    @MainActor func testRemoteDeletionAndLostResponseReconciliation() async throws {
        for loseResponse in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let transport = FixtureTransport()
            await transport.keepResponses()
            let config = RecordConfiguration(endpoint: URL(string: "https://delete.invalid")!, token: "test", accessClientID: "", accessClientSecret: "")
            let store = RecordStore(directory: directory, transport: transport)
            try store.configure(config)
            _ = try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")], rawText: "test", sourceID: "one")
            await store.sync()
            if loseResponse { await transport.loseDeleteResponse() }
            do {
                try await store.delete(id: "entry-1")
                XCTAssertFalse(loseResponse)
                XCTAssertTrue(store.rows.isEmpty)
            } catch {
                XCTAssertTrue(loseResponse)
                XCTAssertEqual(store.rows.count, 1, "Do not claim deletion before confirmation")
            }
            await store.sync()
            XCTAssertTrue(store.rows.isEmpty)
            let restored = RecordStore(directory: directory, transport: transport)
            try restored.configure(config)
            XCTAssertTrue(restored.rows.isEmpty)
        }
    }

    @MainActor func testDeletingLastPendingItemNeverUploadsAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureTransport()
        let config = RecordConfiguration(endpoint: URL(string: "https://cancel.invalid")!, token: "test", accessClientID: "", accessClientSecret: "")
        let store = RecordStore(directory: directory, transport: transport)
        try store.configure(config)
        let intents = [RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")]
        let id = try store.add(intents, rawText: "test", sourceID: "one")
        try await store.delete(id: id + ":0")
        let restored = RecordStore(directory: directory, transport: transport)
        try restored.configure(config)
        _ = try restored.add(intents, rawText: "test", sourceID: "one")
        await restored.sync()
        XCTAssertTrue(restored.rows.isEmpty)
        let writes = await transport.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testLegacyServerRetainsPendingWriteAndRetriesAfterUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureTransport()
        await transport.setLegacy(true)
        let config = RecordConfiguration(endpoint: URL(string: "https://legacy.invalid")!, token: "test", accessClientID: "", accessClientSecret: "")
        let store = RecordStore(directory: directory, transport: transport)
        try store.configure(config)
        let id = try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")], rawText: "20个俯卧撑", sourceID: "legacy-request")
        await store.sync()
        XCTAssertTrue(store.error?.contains("heatmap 服务尚未升级") == true)
        XCTAssertEqual(store.snapshot.operations.first?.state, .pending)
        XCTAssertNil(store.snapshot.operations.first?.body)
        XCTAssertNotNil(store.snapshot.refreshedAt, "Existing records remain readable")
        let beforeWrites = await transport.writes
        XCTAssertEqual(beforeWrites, 0, "Never submit without an idempotency API")
        await transport.setLegacy(false)
        await transport.keepResponses()
        let restored = RecordStore(directory: directory, transport: transport)
        try restored.configure(config)
        await restored.sync()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.snapshot.operations.first?.id, id)
        XCTAssertEqual(restored.snapshot.operations.first?.state, .complete)
        let afterWrites = await transport.writes
        XCTAssertEqual(afterWrites, 1)
        XCTAssertEqual(restored.rows.count, 1)
    }

    @MainActor func testServerRollbackDoesNotMergeUnknownWriteIntoCacheTwice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureTransport()
        let store = RecordStore(directory: directory, transport: transport)
        try store.configure(RecordConfiguration(endpoint: URL(string: "https://rollback.invalid")!, token: "test", accessClientID: "", accessClientSecret: ""))
        _ = try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19")], rawText: "20个", sourceID: "unknown")
        await store.sync() // The fixture commits but drops the response.
        await transport.setLegacy(true)
        await store.sync()
        XCTAssertTrue(store.error?.contains("heatmap 服务尚未升级") == true)
        XCTAssertEqual(store.snapshot.operations.first?.state, .inFlight)
        XCTAssertEqual(store.rows.count, 1)
        let reads = await transport.entryReads
        XCTAssertEqual(reads, 0, "Preserve the cache until the unknown write is reconciled")
        let writes = await transport.writes
        XCTAssertEqual(writes, 1)
    }

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
        do { try await first.delete(id: first.rows[0].id); XCTFail("Unknown writes cannot be deleted") }
        catch { }
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
