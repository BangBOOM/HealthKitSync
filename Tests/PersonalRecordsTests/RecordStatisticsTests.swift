import XCTest
@testable import PersonalRecords

final class RecordStatisticsTests: XCTestCase {
    private func row(_ id: String, _ kind: RecordKind, _ amount: Double, _ date: String, pending: Bool = false) -> RecordRow {
        RecordRow(id: id, kind: kind, amount: amount, performedOn: date, status: pending ? "待同步" : "已同步", canEdit: true, error: nil)
    }
    func testDailyAggregationKeepsUnitsMissingDaysAndPendingState() throws {
        let rows = [row("a", .pushups, 20, "2024-02-28"), row("b", .pushups, 30, "2024-02-28", pending: true), row("c", .plank, 90, "2024-02-28"), row("d", .pushups, 10, "2024-03-01")]
        let series = try RecordStatistics.series(rows: rows, from: "2024-02-28", to: "2024-03-01", activity: .pushups)
        XCTAssertEqual(series.days.map(\.date), ["2024-02-28", "2024-02-29", "2024-03-01"])
        XCTAssertEqual(series.days.map(\.amount), [50, 0, 10])
        XCTAssertEqual(series.days.map(\.count), [2, 0, 1])
        XCTAssertEqual(series.total, 60)
        XCTAssertEqual(series.recordedDays, 2)
        XCTAssertTrue(series.days[0].pending)
        XCTAssertEqual(series.level(series.days[0]), 4)
        XCTAssertEqual(series.level(series.days[1]), 0)
        XCTAssertEqual(series.level(series.days[2]), 1)
        let plank = try RecordStatistics.series(rows: rows, from: "2024-02-28", to: "2024-03-01", activity: .plank)
        XCTAssertEqual(plank.total, 90)
        XCTAssertFalse(plank.hasPending)
        XCTAssertEqual(RecordStatistics.amount(200, kind: .plank, compact: true), "3′20″")
    }
    func testShanghaiMonthBoundaryAndInvalidRanges() throws {
        let date = ISO8601DateFormatter().date(from: "2024-02-29T16:00:00Z")!
        let month = RecordStatistics.month(containing: date)
        XCTAssertEqual(RecordDate.key(month.start), "2024-03-01")
        XCTAssertEqual(RecordDate.key(month.end), "2024-03-31")
        XCTAssertThrowsError(try RecordStatistics.series(rows: [], from: "2024-02-30", to: "2024-03-01", activity: .pushups))
        XCTAssertThrowsError(try RecordStatistics.series(rows: [], from: "2024-03-02", to: "2024-03-01", activity: .pushups))
    }
    @MainActor func testQuerySnapshotDoesNotChangeAfterUpdateAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordStore(directory: directory)
        try store.configure(RecordConfiguration(endpoint: URL(string: "https://fixture.invalid")!, token: "test", accessClientID: "", accessClientSecret: ""))
        let op = try store.add([RecordIntent(activity: .pushups, amount: 20, performedOn: "2026-09-19"), RecordIntent(activity: .plank, amount: 90, performedOn: "2026-09-19")], rawText: "test", sourceID: "one")
        let snapshot = try store.query(from: "2026-09-13", to: "2026-09-19", presentation: .heatmap)
        let bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(snapshot["visualization"]))
        let chart = try JSONDecoder().decode(RecordVisualization.self, from: bytes)
        XCTAssertEqual(chart.series.count, 2)
        XCTAssertEqual(chart.series.first?.total, 20)
        _ = try await store.update(id: op + ":0", amount: 30, performedOn: "2026-09-19", sourceID: "edit")
        XCTAssertEqual(try store.referencedRecord(id: op + ":0").amount, 30)
        try await store.delete(id: op + ":1")
        XCTAssertThrowsError(try store.referencedRecord(id: op + ":1"))
        XCTAssertEqual(store.rows.count, 1)
        let current = try store.query(from: "2026-09-13", to: "2026-09-19", activity: .pushups, presentation: .bar)
        XCTAssertEqual(current["totals"] as? [String: Double], ["pushups": 30])
        XCTAssertEqual(chart.series.first?.total, 20)
        XCTAssertEqual(chart.series.last?.total, 90)
        let legacy = try store.query(from: "2026-09-13", to: "2026-09-19")
        XCTAssertNil(legacy["visualization"])
        XCTAssertNotNil(legacy["entries"])
        let invalid: [[String: Any]] = [
            ["from": "2026-09-13", "to": "2026-09-19", "presentation": "script"],
            ["from": "2026-09-13", "to": "2026-09-19", "activity": "weight"],
            ["from": "2026-09-99", "to": "2026-09-19"]
        ]
        for args in invalid {
            do {
                _ = try await RecordToolService.execute(name: "query_entries", args: args, requestID: "bad", rawText: "bad", records: store)
                XCTFail("Invalid query must be rejected before networking")
            } catch { }
        }
    }
    func testRecordReferencePersistsAndClearsOnReset() throws {
        var archive = ChatArchive()
        archive.selectedRecord = row("target", .pushups, 20, "2026-09-19")
        archive.draft = "改成30个"
        var restored = try JSONDecoder().decode(ChatArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(restored.selectedRecord?.id, "target")
        restored.resetConversation(at: Date())
        XCTAssertNil(restored.selectedRecord)
        XCTAssertEqual(restored.draft, "改成30个")
    }
}
