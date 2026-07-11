import Foundation
import SQLite3
import XCTest
@testable import AgentSessionManagerCore

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
                    isInProgress: false,
                    loadRecord: {
                        XCTFail("Unchanged sessions should be reused without reparsing.")
                        return unchanged
                    }
                ),
                SessionScanCandidate(
                    id: changed.id,
                    fingerprint: changedNewRecord.fingerprint,
                    isInProgress: false,
                    loadRecord: {
                        parseCount += 1
                        return changedNewRecord
                    }
                ),
                SessionScanCandidate(
                    id: addedRecord.id,
                    fingerprint: addedRecord.fingerprint,
                    isInProgress: false,
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

    func testIncrementalRefreshBackfillsMissingTranscriptIndexForUnchangedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let record = try makeRecord(
            sessionID: "unchanged",
            title: "Unchanged",
            fingerprint: "same",
            directory: directory,
            transcriptText: "pickDefaultInferenceId should be indexed."
        )
        try store.replaceAll(records: [record])

        var parseCount = 0
        let adapter = FakeSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: record.id,
                    fingerprint: record.fingerprint,
                    isInProgress: false,
                    loadRecord: {
                        parseCount += 1
                        return record
                    }
                )
            ]
        )

        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        _ = try catalog.refreshSessions()

        let hits = try store.searchTranscriptEntries(sessionIDs: [record.id], query: "pickDefaultInferenceId")

        XCTAssertEqual(parseCount, 1)
        XCTAssertEqual(hits.map(\.sessionRecordID), [record.id])
    }

    func testIncrementalRefreshPreservesStarredPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let original = try makeRecord(
            sessionID: "starred",
            title: "Original",
            fingerprint: "v1",
            directory: directory,
            transcriptText: "Original transcript contents."
        )
        try store.replaceAll(
            records: [original],
            transcriptEntriesBySessionID: [original.id: try TranscriptPreviewExtractor.searchableEntries(for: original)]
        )
        try store.setSessionStarred(true, for: original.id)

        let refreshed = try makeRecord(
            sessionID: "starred",
            title: "Updated",
            fingerprint: "v2",
            directory: directory,
            transcriptText: "Updated transcript contents."
        )
        let adapter = FakeSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: original.id,
                    fingerprint: refreshed.fingerprint,
                    isInProgress: false,
                    loadRecord: { refreshed }
                )
            ]
        )

        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        _ = try catalog.refreshSessions()

        XCTAssertEqual(try catalog.starredSessionIDs(), Set([original.id]))
    }

    func testIncrementalRefreshReclassifiesUnchangedSessionsWithoutReparsingTranscripts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let original = try makeRecord(
            sessionID: "newton-session",
            title: "Newton Session",
            fingerprint: "same",
            directory: directory,
            transcriptText: "Original transcript contents."
        )
        try store.replaceAll(
            records: [original],
            transcriptEntriesBySessionID: [original.id: try TranscriptPreviewExtractor.searchableEntries(for: original)]
        )

        var parseCount = 0
        let adapter = FakeSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: original.id,
                    fingerprint: original.fingerprint,
                    isInProgress: false,
                    loadRecord: {
                        parseCount += 1
                        return original
                    }
                )
            ]
        )

        let catalog = try SessionCatalog(
            storeURL: databaseURL,
            settingsProvider: {
                AppSettingsSnapshot(
                    newtonReposRootPath: "/Users/pisoni/Development/LocalProjects",
                    autoSessionRefresh: .standard
                )
            },
            adaptersOverride: [adapter]
        )
        _ = try catalog.refreshSessions()

        let refreshed = try store.fetchAll()

        XCTAssertEqual(parseCount, 0)
        XCTAssertFalse(refreshed.first?.isNewtonProject == true)
    }

    func testIncrementalRefreshRepeatedNoOpDoesNotReparseIndexedSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        var parseCount = 0
        let record = try makeRecord(
            sessionID: "repeat-noop",
            title: "Repeat no-op",
            fingerprint: "stable",
            directory: directory,
            transcriptText: "This session should only parse once."
        )

        let adapter = FakeSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: record.id,
                    fingerprint: record.fingerprint,
                    isInProgress: false,
                    loadRecord: {
                        parseCount += 1
                        return record
                    }
                )
            ]
        )

        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        _ = try catalog.refreshSessions()
        _ = try catalog.refreshSessions()

        XCTAssertEqual(parseCount, 1)
        XCTAssertEqual(try store.fetchAll().map(\.sourceSessionId), ["repeat-noop"])
        XCTAssertEqual(
            try store.searchTranscriptEntries(sessionIDs: [record.id], query: "only parse once").map(\.sessionRecordID),
            [record.id]
        )
    }

    func testCursorGlobalPlanLinkIsPersistedAndIndexedDuringRebuildAndRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        let copilotRoot = directory.appendingPathComponent(".copilot/session-state", isDirectory: true)
        let vscodeRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copilotRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vscodeRoot, withIntermediateDirectories: true)

        let workspacePath = directory.appendingPathComponent("workspace-root", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true, attributes: nil)
        let projectDirectoryName = PathUtilities.cursorProjectDirectoryName(forWorkspacePath: workspacePath)
        let sessionID = "cursor-rebuild-refresh"
        let projectDirectory = projectsRoot.appendingPathComponent(projectDirectoryName, isDirectory: true)
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"Plan indexing should work."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll index the linked plan."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let plansRoot = directory.appendingPathComponent(".cursor/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        let planURL = plansRoot.appendingPathComponent("linked-plan.plan.md")
        try """
        # Cursor Plan

        Linked global plan content for refresh indexing.
        """.write(
            to: planURL,
            atomically: true,
            encoding: .utf8
        )

        try createCursorItemTableDatabase(
            at: globalStorageRoot.appendingPathComponent("state.vscdb"),
            items: [
                "composer.planRegistry": """
                {
                  "linked-plan": {
                    "id": "linked-plan",
                    "uri": {
                      "fsPath": "\(planURL.path)"
                    }
                  }
                }
                """,
                "cursor/glass.tabs.v2/workspace-id/\(sessionID)/state.json": """
                {
                  "agentId": "\(sessionID)",
                  "planTabs": [
                    {
                      "lastActiveTime": 250,
                      "props": {
                        "planId": "linked-plan",
                        "ownerAgentId": "\(sessionID)"
                      }
                    }
                  ]
                }
                """
            ]
        )

        let roots = SourceRoots(
            copilotCLI: copilotRoot,
            cursorProjects: projectsRoot,
            cursorWorkspaceStorage: workspaceStorageRoot,
            cursorGlobalStorage: globalStorageRoot,
            vscodeWorkspaceStorage: vscodeRoot,
            claudeProjects: directory.appendingPathComponent("claude-projects-empty", isDirectory: true),
            claudeCodeSessions: directory.appendingPathComponent("claude-code-sessions-empty", isDirectory: true),
            claudeSessions: directory.appendingPathComponent("claude-sessions-empty", isDirectory: true)
        )

        let rebuildDatabaseURL = directory.appendingPathComponent("catalog-rebuild.sqlite3")
        let rebuildCatalog = try SessionCatalog(storeURL: rebuildDatabaseURL, roots: roots)
        let rebuiltRecords = try rebuildCatalog.rebuildSessions()
        let rebuildStore = try SQLiteSessionStore(databaseURL: rebuildDatabaseURL)

        XCTAssertEqual(rebuiltRecords.count, 1)
        XCTAssertEqual(rebuiltRecords[0].relatedPlanPath, planURL.path)
        XCTAssertEqual(
            try rebuildStore.searchTranscriptEntries(
                sessionIDs: [rebuiltRecords[0].id],
                query: "global plan content",
                scope: .plan
            ).map(\.sessionRecordID),
            [rebuiltRecords[0].id]
        )

        let refreshDatabaseURL = directory.appendingPathComponent("catalog-refresh.sqlite3")
        let refreshCatalog = try SessionCatalog(storeURL: refreshDatabaseURL, roots: roots)
        let refreshedRecords = try refreshCatalog.refreshSessions()
        let refreshStore = try SQLiteSessionStore(databaseURL: refreshDatabaseURL)

        XCTAssertEqual(refreshedRecords.count, 1)
        XCTAssertEqual(refreshedRecords[0].relatedPlanPath, planURL.path)
        XCTAssertEqual(
            try refreshStore.searchTranscriptEntries(
                sessionIDs: [refreshedRecords[0].id],
                query: "refresh indexing",
                scope: .plan
            ).map(\.sessionRecordID),
            [refreshedRecords[0].id]
        )
    }

    func testCatalogRefreshKeepsGlobalCursorSessionStableWhenOnlyStateDatabaseMTimeChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")
        let copilotRoot = directory.appendingPathComponent(".copilot", isDirectory: true)
        let cursorProjectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let cursorWorkspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let cursorGlobalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        let vscodeRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: copilotRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorProjectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorWorkspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorGlobalStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vscodeRoot, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton4"
        let workspaceDirectory = cursorWorkspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "global-composer-refresh-stability"
        let expectedUpdatedAt = try XCTUnwrap(ISO8601DateCoding.parse("2026-02-10T12:06:45.887Z"))
        let stateDBURL = cursorGlobalStorageRoot.appendingPathComponent("state.vscdb")
        try createCursorStateDatabase(
            at: stateDBURL,
            items: [
                "composer.composerHeaders": """
                {
                  "allComposers": [
                    {
                      "composerId": "\(sessionID)",
                      "name": "Global composer refresh stability",
                      "createdAt": 1739189196826,
                      "workspaceIdentifier": {
                        "id": "workspace-id",
                        "uri": {
                          "fsPath": "\(workspacePath)"
                        }
                      }
                    }
                  ]
                }
                """
            ],
            cursorDiskKVItems: [
                "bubbleId:\(sessionID):bubble-1": """
                {
                  "bubbleId": "bubble-1",
                  "type": 1,
                  "text": "Why does this stale session look updated?",
                  "createdAt": "2026-02-10T12:06:36.826Z"
                }
                """,
                "bubbleId:\(sessionID):bubble-2": """
                {
                  "bubbleId": "bubble-2",
                  "type": 2,
                  "text": "Because the adapter is using shared database mtime.",
                  "createdAt": "2026-02-10T12:06:45.887Z"
                }
                """
            ]
        )

        let catalog = try SessionCatalog(
            storeURL: databaseURL,
            roots: SourceRoots(
                copilotCLI: copilotRoot,
                cursorProjects: cursorProjectsRoot,
                cursorWorkspaceStorage: cursorWorkspaceStorageRoot,
                cursorGlobalStorage: cursorGlobalStorageRoot,
                vscodeWorkspaceStorage: vscodeRoot,
                claudeProjects: directory.appendingPathComponent("claude-projects-empty", isDirectory: true),
                claudeCodeSessions: directory.appendingPathComponent("claude-code-sessions-empty", isDirectory: true),
                claudeSessions: directory.appendingPathComponent("claude-sessions-empty", isDirectory: true)
            )
        )

        let initialSessions = try catalog.refreshSessions()
        let initialRecord = try XCTUnwrap(initialSessions.first(where: { $0.sourceSessionId == sessionID }))
        XCTAssertEqual(initialRecord.updatedAt, expectedUpdatedAt)

        try FileManager.default.setAttributes(
            [.modificationDate: try XCTUnwrap(ISO8601DateCoding.parse("2026-06-01T14:23:00.956Z"))],
            ofItemAtPath: stateDBURL.path
        )

        let refreshedSessions = try catalog.refreshSessions()
        let refreshedRecord = try XCTUnwrap(refreshedSessions.first(where: { $0.sourceSessionId == sessionID }))
        XCTAssertEqual(refreshedRecord.updatedAt, expectedUpdatedAt)
        XCTAssertEqual(refreshedRecord.fingerprint, initialRecord.fingerprint)

        let storedRecord = try XCTUnwrap(SQLiteSessionStore(databaseURL: databaseURL).fetchAll().first(where: {
            $0.source == .cursor && $0.sourceSessionId == sessionID
        }))
        XCTAssertEqual(storedRecord.updatedAt, expectedUpdatedAt)
        XCTAssertEqual(storedRecord.fingerprint, initialRecord.fingerprint)
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

private func createCursorItemTableDatabase(at url: URL, items: [String: String]) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Failed to open SQLite database"
        sqlite3_close(database)
        XCTFail(message)
        return
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil) == SQLITE_OK else {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Failed to create ItemTable"
        XCTFail(message)
        return
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO ItemTable(key, value) VALUES(?, ?);", -1, &statement, nil) == SQLITE_OK else {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Failed to prepare insert"
        XCTFail(message)
        return
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for key in items.keys.sorted() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, items[key], -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Failed to insert SQLite item"
            XCTFail(message)
            return
        }
    }
}

private struct FakeSessionAdapter: SessionSourceAdapter {
    let candidates: [SessionScanCandidate]

    func scanCandidates() throws -> [SessionScanCandidate] {
        candidates
    }
}
