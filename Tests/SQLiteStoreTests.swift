import Foundation
import XCTest
@testable import AgentSessionManager

final class SQLiteStoreTests: XCTestCase {
    func testReplaceAllPersistsAndReadsBackSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let record = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "session-1",
            workspacePath: "/Users/pisoni/repos/newton5",
            projectName: "newton5",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-07T06:30:14.516Z"),
            title: "Resume local session browser work",
            summary: "Refresh the local session index and show previews.",
            firstUserPreview: "Resume local session browser work",
            firstAssistantPreview: "I’ll refresh the catalog and inspect the previews.",
            rawTranscriptPath: "/tmp/events.jsonl",
            rawMetadataPath: "/tmp/workspace.yaml",
            relatedPlanPath: "/tmp/plan.md",
            fingerprint: "fingerprint-v1",
            resumeKind: .copilotConnect,
            resumePayload: "session-1",
            isNewtonProject: true
        )

        try store.replaceAll(records: [record])
        let loaded = try store.fetchAll()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.source, .copilotCLI)
        XCTAssertEqual(loaded.first?.sourceSessionId, "session-1")
        XCTAssertEqual(loaded.first?.title, "Resume local session browser work")
        XCTAssertEqual(loaded.first?.resumeKind, .copilotConnect)
        XCTAssertEqual(loaded.first?.conversationModel, "gpt-5.4")
        XCTAssertEqual(loaded.first?.relatedPlanPath, "/tmp/plan.md")
        XCTAssertEqual(loaded.first?.fingerprint, "fingerprint-v1")
        XCTAssertTrue(loaded.first?.isNewtonProject == true)
    }

    func testApplyIncrementalUpdateUpsertsAndDeletesSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let original = makeRecord(sessionID: "session-1", title: "Original", fingerprint: "v1")
        let removed = makeRecord(sessionID: "session-2", title: "Removed", fingerprint: "gone")

        try store.replaceAll(records: [original, removed])

        let updated = makeRecord(sessionID: "session-1", title: "Updated", fingerprint: "v2")
        let added = makeRecord(sessionID: "session-3", title: "Added", fingerprint: "v1")
        try store.applyIncrementalUpdate(records: [updated, added], removedIDs: [removed.id])

        let loaded = try store.fetchAll()
        XCTAssertEqual(loaded.map(\.sourceSessionId).sorted(), ["session-1", "session-3"])
        XCTAssertEqual(loaded.first(where: { $0.sourceSessionId == "session-1" })?.title, "Updated")
        XCTAssertEqual(loaded.first(where: { $0.sourceSessionId == "session-1" })?.fingerprint, "v2")
        XCTAssertEqual(loaded.first(where: { $0.sourceSessionId == "session-3" })?.title, "Added")
    }

    func testTranscriptIndexQueriesReturnOnlyCurrentSessionRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let matching = makeRecord(sessionID: "session-1", title: "Matching", fingerprint: "v1")
        let other = makeRecord(sessionID: "session-2", title: "Other", fingerprint: "v1")

        try store.replaceAll(
            records: [matching, other],
            transcriptEntriesBySessionID: [
                matching.id: [
                    TranscriptIndexEntry(sessionRecordID: matching.id, entryIndex: 0, text: "Find the terminal drag bug."),
                    TranscriptIndexEntry(sessionRecordID: matching.id, entryIndex: 1, text: "I’ll inspect the drag target next.")
                ],
                other.id: [
                    TranscriptIndexEntry(sessionRecordID: other.id, entryIndex: 0, text: "Please summarize the filter changes.")
                ]
            ]
        )

        let hits = try store.searchTranscriptEntries(sessionIDs: [matching.id, other.id], query: "drag")

        XCTAssertEqual(hits.map(\.sessionRecordID), [matching.id, matching.id])
        XCTAssertEqual(hits.map(\.entryIndex), [0, 1])
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
            relatedPlanPath: "/tmp/\(sessionID)-plan.md",
            fingerprint: fingerprint,
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: true
        )
    }
}
