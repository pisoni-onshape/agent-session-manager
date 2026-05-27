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

    func testCursorAdapterDiscoversGlobalComposerBubbleSessionsWithoutAgentTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
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

        let sessionID = "6526fac6-5693-4f80-b5b4-4d6157f67960"
        let stateDBURL = globalStorageRoot.appendingPathComponent("state.vscdb")
        try createCursorStateDatabase(
            at: stateDBURL,
            items: [
                "composer.composerHeaders": """
                {
                  "allComposers": [
                    {
                      "composerId": "\(sessionID)",
                      "name": "WebGL2 feature implementation brainstorming",
                      "createdAt": 1739189196826,
                      "lastUpdatedAt": 1739189205887,
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
                  "text": "Now when we've transitioned to WebGL2 instead of WebGL1 in this project, please draft a meeting invite.",
                  "createdAt": "2026-02-10T12:06:36.826Z"
                }
                """,
                "bubbleId:\(sessionID):bubble-2": """
                {
                  "bubbleId": "bubble-2",
                  "type": 2,
                  "text": "Draft completion for your meeting invite.",
                  "createdAt": "2026-02-10T12:06:45.887Z"
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
        XCTAssertEqual(records[0].sourceSessionId, sessionID)
        XCTAssertEqual(records[0].workspacePath, workspacePath)
        XCTAssertEqual(records[0].projectName, "newton5")
        XCTAssertEqual(records[0].title, "WebGL2 feature implementation brainstorming")
        XCTAssertEqual(records[0].firstUserPreview, "Now when we've transitioned to WebGL2 instead of WebGL1 in this project, please draft a meeting invite.")
        XCTAssertEqual(records[0].firstAssistantPreview, "Draft completion for your meeting invite.")
        XCTAssertEqual(records[0].resumeKind, .openInCursor)
        XCTAssertEqual(records[0].resumePayload, workspacePath)
        XCTAssertEqual(
            records[0].rawTranscriptPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            stateDBURL.standardizedFileURL.path
        )
        XCTAssertEqual(
            records[0].rawMetadataPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            workspaceDirectory.appendingPathComponent("workspace.json").standardizedFileURL.path
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: records[0])
        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertTrue(transcript.timestampsAreComplete)
        XCTAssertEqual(transcript.entries[0].title, "User")
        XCTAssertEqual(transcript.entries[1].title, "Assistant")
    }

    func testCursorAdapterDiscoversWorkspaceChatSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "cursor-chat-session"
        try """
        {
          "version": 3,
          "customTitle": "Cursor workspace chat session",
          "initialLocation": "panel",
          "sessionId": "\(sessionID)",
          "creationDate": 1739189196826,
          "lastMessageDate": 1739189205887,
          "requests": [
            {
              "requestId": "request-1",
              "timestamp": 1739189205887,
              "modelId": "copilot/gpt-5-mini",
              "message": {
                "text": "Please review the workspace chat indexing path."
              },
              "response": [
                {
                  "kind": "markdownContent",
                  "content": {
                    "value": "I checked the **chat** storage path."
                  }
                }
              ]
            }
          ]
        }
        """.write(
            to: chatSessionsDirectory.appendingPathComponent("\(sessionID).json"),
            atomically: true,
            encoding: .utf8
        )

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
        XCTAssertEqual(records[0].sourceSessionId, sessionID)
        XCTAssertEqual(records[0].workspacePath, workspacePath)
        XCTAssertEqual(records[0].projectName, "newton5")
        XCTAssertEqual(records[0].title, "Cursor workspace chat session")
        XCTAssertEqual(records[0].firstUserPreview, "Please review the workspace chat indexing path.")
        XCTAssertEqual(records[0].firstAssistantPreview, "I checked the chat storage path.")
        XCTAssertEqual(records[0].conversationModel, "gpt-5-mini")
        XCTAssertEqual(records[0].resumeKind, .openInCursor)
        XCTAssertEqual(records[0].resumePayload, workspacePath)
        XCTAssertEqual(
            records[0].rawTranscriptPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            chatSessionsDirectory.appendingPathComponent("\(sessionID).json").standardizedFileURL.path
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: records[0])
        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertFalse(transcript.timestampsAreComplete)
        XCTAssertEqual(transcript.entries[0].title, "User")
        XCTAssertEqual(transcript.entries[1].title, "Assistant")
    }

    func testCursorAdapterPrefersAgentTranscriptOverGlobalComposerBubbleForSameSessionID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        let globalStorageRoot = directory.appendingPathComponent("Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalStorageRoot, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        let projectDirectory = projectsRoot.appendingPathComponent("Users-pisoni-repos-newton5", isDirectory: true)
        let sessionID = "dedupe-session"
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"File-backed user message."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"File-backed assistant message."}]}}
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

        try createCursorStateDatabase(
            at: globalStorageRoot.appendingPathComponent("state.vscdb"),
            items: [
                "composer.composerHeaders": """
                {
                  "allComposers": [
                    {
                      "composerId": "\(sessionID)",
                      "name": "Preferred external title",
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
                  "text": "Bubble-backed user message.",
                  "createdAt": "2026-02-10T12:06:36.826Z"
                }
                """,
                "bubbleId:\(sessionID):bubble-2": """
                {
                  "bubbleId": "bubble-2",
                  "type": 2,
                  "text": "Bubble-backed assistant message.",
                  "createdAt": "2026-02-10T12:06:45.887Z"
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
        XCTAssertEqual(records[0].title, "Preferred external title")
        XCTAssertEqual(records[0].firstUserPreview, "File-backed user message.")
        XCTAssertEqual(records[0].firstAssistantPreview, "File-backed assistant message.")
        XCTAssertEqual(
            records[0].rawTranscriptPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            sessionDirectory.appendingPathComponent("\(sessionID).jsonl").standardizedFileURL.path
        )
    }
}

private func createCursorStateDatabase(
    at url: URL,
    items: [String: String],
    cursorDiskKVItems: [String: String] = [:]
) throws {
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

    guard sqlite3_exec(database, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil) == SQLITE_OK else {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Failed to create cursorDiskKV"
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

    var cursorStatement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO cursorDiskKV(key, value) VALUES(?, ?);", -1, &cursorStatement, nil) == SQLITE_OK else {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Failed to prepare cursorDiskKV insert"
        XCTFail(message)
        return
    }
    defer { sqlite3_finalize(cursorStatement) }

    for key in cursorDiskKVItems.keys.sorted() {
        sqlite3_reset(cursorStatement)
        sqlite3_clear_bindings(cursorStatement)
        sqlite3_bind_text(cursorStatement, 1, key, -1, transient)
        sqlite3_bind_text(cursorStatement, 2, cursorDiskKVItems[key], -1, transient)

        guard sqlite3_step(cursorStatement) == SQLITE_DONE else {
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Failed to insert cursorDiskKV item"
            XCTFail(message)
            return
        }
    }
}
