import Foundation
import SQLite3
import XCTest
@testable import AgentSessionManagerCore

final class CursorAdapterTests: XCTestCase {
    func testCursorAdapterUsesWorkspaceStorageMetadataAndStoredCursorTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/Library/CloudStorage/OneDrive-PTC/Projects/newton-env-manager"
        let sessionID = "a6c3a5ca-aa0f-4038-a3a4-24a1946b214c"
        let projectDirectory = projectsRoot.appendingPathComponent(
            "Users-pisoni-Library-CloudStorage-OneDrive-PTC-Projects-newton-env-manager",
            isDirectory: true
        )
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"Explain the terminal behavior."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the workspace metadata path."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("3303167c120fc2f8eb2bf262a31d5cc4", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try """
        {
          "folder": "file:///Users/pisoni/Library/CloudStorage/OneDrive-PTC/Projects/newton-env-manager"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )
        try createCursorStateDatabase(
            at: globalStorageRoot.appendingPathComponent("state.vscdb"),
            items: [
                "composer.composerHeaders": """
                {
                  "allComposers": [
                    {
                      "composerId": "\(sessionID)",
                      "name": "PR #1496 review and feedback"
                    }
                  ]
                }
                """
            ]
        )

        let records = try CursorAdapter(
            root: projectsRoot,
            workspaceStorageRoot: workspaceStorageRoot,
            globalStorageRoot: globalStorageRoot
        ).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].workspacePath, workspacePath)
        XCTAssertEqual(records[0].projectName, "newton-env-manager")
        XCTAssertEqual(records[0].title, "PR #1496 review and feedback")
        XCTAssertEqual(records[0].resumeKind, .openInCursor)
        XCTAssertEqual(records[0].resumePayload, workspacePath)
    }

    func testCursorAdapterFallsBackToSanitizedPromptTitleWithoutStoredCursorTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)

        let projectDirectory = projectsRoot.appendingPathComponent(
            "Users-pisoni-Development-LocalProjects-nonexistent-demo-app",
            isDirectory: true
        )
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Friday, May 8, 2026, 3:53 PM (UTC+5:30)</timestamp>\\n<user_query>Please review this diff.</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll review the filter UI next."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("session-2.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let records = try CursorAdapter(
            root: projectsRoot,
            workspaceStorageRoot: workspaceStorageRoot,
            globalStorageRoot: globalStorageRoot
        ).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].workspacePath)
        XCTAssertEqual(records[0].projectName, "nonexistent-demo-app")
        XCTAssertEqual(records[0].title, "Please review this diff.")
        XCTAssertEqual(records[0].resumeKind, .revealPath)
    }

    func testCursorAdapterPrefersMostRecentlyActiveGlobalPlanPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        let plansRoot = directory.appendingPathComponent(".cursor/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)

        let sessionID = "cursor-session-1"
        let projectDirectory = projectsRoot.appendingPathComponent(
            "Users-pisoni-Development-LocalProjects-agent-session-manager",
            isDirectory: true
        )
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"Link my plan."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll open the latest plan."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try "# Session-local fallback plan\n".write(
            to: sessionDirectory.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )

        let olderPlanURL = plansRoot.appendingPathComponent("older.plan.md")
        let newerPlanURL = plansRoot.appendingPathComponent("newer.plan.md")
        try "# Older plan\n".write(to: olderPlanURL, atomically: true, encoding: .utf8)
        try "# Newer plan\n".write(to: newerPlanURL, atomically: true, encoding: .utf8)

        try createCursorStateDatabase(
            at: globalStorageRoot.appendingPathComponent("state.vscdb"),
            items: [
                "composer.planRegistry": """
                {
                  "older-plan": {
                    "id": "older-plan",
                    "uri": {
                      "fsPath": "\(olderPlanURL.path)"
                    }
                  },
                  "newer-plan": {
                    "id": "newer-plan",
                    "uri": {
                      "fsPath": "\(newerPlanURL.path)"
                    }
                  }
                }
                """,
                "cursor/glass.tabs.v2/workspace-1/\(sessionID)/state.json": """
                {
                  "agentId": "\(sessionID)",
                  "planTabs": [
                    {
                      "lastActiveTime": 100,
                      "props": {
                        "planId": "older-plan",
                        "ownerAgentId": "\(sessionID)"
                      }
                    },
                    {
                      "lastActiveTime": 200,
                      "props": {
                        "planId": "newer-plan",
                        "ownerAgentId": "\(sessionID)"
                      }
                    }
                  ]
                }
                """
            ]
        )

        let records = try CursorAdapter(
            root: projectsRoot,
            workspaceStorageRoot: workspaceStorageRoot,
            globalStorageRoot: globalStorageRoot
        ).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].relatedPlanPath, newerPlanURL.path)
        XCTAssertTrue(records[0].fingerprint.contains(newerPlanURL.path))
    }

    func testCursorAdapterFallsBackToSessionDirectoryPlanWhenGlobalPlanLinkIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)

        let sessionID = "cursor-session-2"
        let projectDirectory = projectsRoot.appendingPathComponent(
            "Users-pisoni-Development-LocalProjects-nonexistent-demo-app",
            isDirectory: true
        )
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"Use the session plan."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll use the local plan."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let localPlanURL = sessionDirectory.appendingPathComponent("plan.md")
        try "# Local plan\n".write(to: localPlanURL, atomically: true, encoding: .utf8)

        try createCursorStateDatabase(
            at: globalStorageRoot.appendingPathComponent("state.vscdb"),
            items: [:]
        )

        let records = try CursorAdapter(
            root: projectsRoot,
            workspaceStorageRoot: workspaceStorageRoot,
            globalStorageRoot: globalStorageRoot
        ).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            records[0].relatedPlanPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            localPlanURL.resolvingSymlinksInPath().path
        )
    }
}

private func createCursorStateDatabase(at url: URL, items: [String: String]) throws {
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
