import Foundation
import XCTest
@testable import AgentSessionManager

final class SessionCatalogRefreshTests: XCTestCase {
    func testIncrementalRefreshOnlyParsesNewOrChangedSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let unchanged = try makeRecord(
            sessionID: "unchanged",
            title: "Unchanged",
            fingerprint: "same",
            directory: directory,
            transcriptText: "Keep the existing transcript entry."
        )
        let changed = try makeRecord(
            sessionID: "changed",
            title: "Changed old",
            fingerprint: "old",
            directory: directory,
            transcriptText: "Original transcript contents."
        )
        let removed = try makeRecord(
            sessionID: "removed",
            title: "Removed",
            fingerprint: "gone",
            directory: directory,
            transcriptText: "Removed transcript contents."
        )
        try store.replaceAll(
            records: [unchanged, changed, removed],
            transcriptEntriesBySessionID: [
                unchanged.id: try TranscriptPreviewExtractor.searchableEntries(for: unchanged),
                changed.id: try TranscriptPreviewExtractor.searchableEntries(for: changed),
                removed.id: try TranscriptPreviewExtractor.searchableEntries(for: removed)
            ]
        )

        var parseCount = 0
        let changedNewRecord = try makeRecord(
            sessionID: "changed",
            title: "Changed new",
            fingerprint: "new",
            directory: directory,
            transcriptText: "Updated transcript contents for search."
        )
        let addedRecord = try makeRecord(
            sessionID: "added",
            title: "Added",
            fingerprint: "fresh",
            directory: directory,
            transcriptText: "Freshly added transcript contents."
        )

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
        let transcriptHits = try store.searchTranscriptEntries(
            sessionIDs: persisted.map(\.id),
            query: "updated transcript"
        )

        XCTAssertEqual(parseCount, 2)
        XCTAssertEqual(Set(refreshed.map(\.sourceSessionId)), ["unchanged", "changed", "added"])
        XCTAssertEqual(Set(persisted.map(\.sourceSessionId)), ["unchanged", "changed", "added"])
        XCTAssertEqual(persisted.first(where: { $0.sourceSessionId == "unchanged" })?.title, "Unchanged")
        XCTAssertEqual(persisted.first(where: { $0.sourceSessionId == "changed" })?.title, "Changed new")
        XCTAssertNil(persisted.first(where: { $0.sourceSessionId == "removed" }))
        XCTAssertEqual(Set(transcriptHits.map(\.sessionRecordID)), [changedNewRecord.id])
    }

    private func makeRecord(
        sessionID: String,
        title: String,
        fingerprint: String,
        directory: URL,
        transcriptText: String
    ) throws -> SessionRecord {
        let transcriptURL = directory.appendingPathComponent("\(sessionID).jsonl")
        try """
        {"type":"user.message","data":{"content":"\(transcriptText)"},"id":"\(sessionID)-1","timestamp":"2026-05-07T06:19:00.000Z"}
        {"type":"assistant.message","data":{"content":"Assistant reply for \(sessionID)."},"id":"\(sessionID)-2","timestamp":"2026-05-07T06:19:10.000Z"}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        return SessionRecord(
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
            rawTranscriptPath: transcriptURL.path,
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
