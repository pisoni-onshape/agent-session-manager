import Foundation
import SQLite3
import XCTest
@testable import AgentSessionManagerCore

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

    func testTranscriptIndexQueriesRespectSearchScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let record = makeRecord(sessionID: "session-1", title: "Scoped", fingerprint: "v1")

        try store.replaceAll(
            records: [record],
            transcriptEntriesBySessionID: [
                record.id: [
                    TranscriptIndexEntry(sessionRecordID: record.id, entryIndex: 0, text: "Find the terminal drag bug."),
                    TranscriptIndexEntry(sessionRecordID: record.id, entryIndex: -1, text: "Plan the drag bug search flow.")
                ]
            ]
        )

        let allHits = try store.searchTranscriptEntries(sessionIDs: [record.id], query: "drag", scope: .all)
        let transcriptHits = try store.searchTranscriptEntries(sessionIDs: [record.id], query: "drag", scope: .transcript)
        let planHits = try store.searchTranscriptEntries(sessionIDs: [record.id], query: "drag", scope: .plan)

        XCTAssertEqual(allHits.map(\.entryIndex), [-1, 0])
        XCTAssertEqual(transcriptHits.map(\.entryIndex), [0])
        XCTAssertEqual(planHits.map(\.entryIndex), [-1])
    }

    func testStarredSessionPreferencesPersistAcrossStoreReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")
        let record = makeRecord(sessionID: "session-1", title: "Star me", fingerprint: "v1")

        do {
            let store = try SQLiteSessionStore(databaseURL: databaseURL)
            try store.replaceAll(records: [record])
            try store.setSessionStarred(true, for: record.id)
        }

        do {
            let reopenedStore = try SQLiteSessionStore(databaseURL: databaseURL)
            XCTAssertEqual(try reopenedStore.fetchStarredSessionIDs(), Set([record.id]))

            try reopenedStore.replaceAll(records: [record])
            XCTAssertEqual(try reopenedStore.fetchStarredSessionIDs(), Set([record.id]))

            try reopenedStore.setSessionStarred(false, for: record.id)
            XCTAssertTrue(try reopenedStore.fetchStarredSessionIDs().isEmpty)
        }
    }

    func testCatalogExclusionsPersistAcrossStoreReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let exclusions: [SessionCatalogExclusion] = [
            SessionCatalogExclusion.session(
                SessionRecord(
                    source: .copilotCLI,
                    sourceSessionId: "session-1",
                    workspacePath: "/Users/pisoni/repos/newton5",
                    projectName: "newton5",
                    branch: "main",
                    conversationModel: nil,
                    startedAt: nil,
                    updatedAt: nil,
                    title: "Session 1",
                    summary: nil,
                    firstUserPreview: nil,
                    firstAssistantPreview: nil,
                    rawTranscriptPath: nil,
                    rawMetadataPath: nil,
                    relatedPlanPath: nil,
                    fingerprint: "v1",
                    resumeKind: .copilotConnect,
                    resumePayload: "session-1",
                    isNewtonProject: true
                )
            ),
            SessionCatalogExclusion.project(named: "newton6"),
            SessionCatalogExclusion.branch("feature/hide-me", inProject: "newton7")
        ]

        do {
            let store = try SQLiteSessionStore(databaseURL: databaseURL)
            try exclusions.forEach(store.upsertExclusion)
        }

        do {
            let reopenedStore = try SQLiteSessionStore(databaseURL: databaseURL)
            let loaded = try reopenedStore.fetchExclusions()
            XCTAssertEqual(Set(loaded.map(\.id)), Set(exclusions.map(\.id)))
        }
    }

    func testRemoveSessionsDeletesTranscriptEntriesForMatchingIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let keep = makeRecord(sessionID: "keep", title: "Keep", fingerprint: "v1")
        let remove = makeRecord(sessionID: "remove", title: "Remove", fingerprint: "v1")
        try store.replaceAll(
            records: [keep, remove],
            transcriptEntriesBySessionID: [
                keep.id: [TranscriptIndexEntry(sessionRecordID: keep.id, entryIndex: 0, text: "keep me")],
                remove.id: [TranscriptIndexEntry(sessionRecordID: remove.id, entryIndex: 0, text: "remove me")]
            ]
        )

        try store.removeSessions(withIDs: [remove.id])

        XCTAssertEqual(try store.fetchAll().map(\.id), [keep.id])
        XCTAssertEqual(try store.searchTranscriptEntries(sessionIDs: [keep.id, remove.id], query: "remove").count, 0)
    }

    func testSQLiteContentionPolicyClassifiesBusyAndLockedCodesAsTransient() {
        let extendedBusyCode = SQLITE_BUSY | Int32(1 << 8)

        XCTAssertTrue(SQLiteContentionPolicy.isTransientLock(code: SQLITE_BUSY))
        XCTAssertTrue(SQLiteContentionPolicy.isTransientLock(code: extendedBusyCode))
        XCTAssertTrue(SQLiteContentionPolicy.isTransientLock(code: SQLITE_LOCKED))
        XCTAssertFalse(SQLiteContentionPolicy.isTransientLock(code: SQLITE_CONSTRAINT))
    }

    func testSQLiteContentionRetryRetriesTransientBusyFailures() throws {
        var attempts = 0

        let result = try withSQLiteContentionRetry(maxAttempts: 3, retryDelayNanoseconds: 0) {
            attempts += 1
            if attempts < 3 {
                throw SQLiteStoreError.stepFailed(code: SQLITE_BUSY, message: "database is locked")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 3)
    }

    func testSQLiteContentionRetryStopsAfterRetryBudgetIsExhausted() {
        var attempts = 0

        XCTAssertThrowsError(
            try withSQLiteContentionRetry(maxAttempts: 2, retryDelayNanoseconds: 0) {
                attempts += 1
                throw SQLiteStoreError.stepFailed(code: SQLITE_LOCKED, message: "database is locked")
            }
        ) { error in
            let sqliteError = error as? SQLiteStoreError
            XCTAssertTrue(sqliteError?.isTransientLockContention == true)
        }

        XCTAssertEqual(attempts, 2)
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
