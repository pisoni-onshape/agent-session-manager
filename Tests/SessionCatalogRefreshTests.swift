import Foundation
import XCTest
@testable import AgentSessionManager

final class SessionCatalogRefreshTests: XCTestCase {
    func testIncrementalRefreshOnlyParsesNewOrChangedSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let unchanged = makeRecord(sessionID: "unchanged", title: "Unchanged", fingerprint: "same")
        let changed = makeRecord(sessionID: "changed", title: "Changed old", fingerprint: "old")
        let removed = makeRecord(sessionID: "removed", title: "Removed", fingerprint: "gone")
        try store.replaceAll(records: [unchanged, changed, removed])

        var parseCount = 0
        let changedNewRecord = makeRecord(sessionID: "changed", title: "Changed new", fingerprint: "new")
        let addedRecord = makeRecord(sessionID: "added", title: "Added", fingerprint: "fresh")

        let adapter = FakeSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: unchanged.id,
                    fingerprint: unchanged.fingerprint,
                    loadRecord: {
                        XCTFail("Unchanged sessions should be reused without reparsing.")
                        return unchanged
                    }
                ),
                SessionScanCandidate(
                    id: changed.id,
                    fingerprint: changedNewRecord.fingerprint,
                    loadRecord: {
                        parseCount += 1
                        return changedNewRecord
                    }
                ),
                SessionScanCandidate(
                    id: addedRecord.id,
                    fingerprint: addedRecord.fingerprint,
                    loadRecord: {
                        parseCount += 1
                        return addedRecord
                    }
                )
            ]
        )

        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        let refreshed = try catalog.refreshSessions()
        let persisted = try store.fetchAll()

        XCTAssertEqual(parseCount, 2)
        XCTAssertEqual(Set(refreshed.map(\.sourceSessionId)), ["unchanged", "changed", "added"])
        XCTAssertEqual(Set(persisted.map(\.sourceSessionId)), ["unchanged", "changed", "added"])
        XCTAssertEqual(persisted.first(where: { $0.sourceSessionId == "unchanged" })?.title, "Unchanged")
        XCTAssertEqual(persisted.first(where: { $0.sourceSessionId == "changed" })?.title, "Changed new")
        XCTAssertNil(persisted.first(where: { $0.sourceSessionId == "removed" }))
    }

    private func makeRecord(sessionID: String, title: String, fingerprint: String) -> SessionRecord {
        SessionRecord(
            source: .copilotCLI,
            sourceSessionId: sessionID,
            workspacePath: "/Users/pisoni/repos/newton5",
            projectName: "newton5",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-07T06:30:14.516Z"),
            title: title,
            summary: "Summary",
            firstUserPreview: "Prompt",
            firstAssistantPreview: "Response",
            rawTranscriptPath: "/tmp/\(sessionID).jsonl",
            rawMetadataPath: "/tmp/\(sessionID).yaml",
            relatedPlanPath: nil,
            fingerprint: fingerprint,
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: true
        )
    }
}

private struct FakeSessionAdapter: SessionSourceAdapter {
    let candidates: [SessionScanCandidate]

    func scanCandidates() throws -> [SessionScanCandidate] {
        candidates
    }
}
