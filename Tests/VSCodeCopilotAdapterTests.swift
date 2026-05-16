import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class VSCodeCopilotAdapterTests: XCTestCase {
    func testVSCodeAdapterDiscoversChatSessionsAndPrefersCustomTitles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceStorageRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "22db53bd-e035-446e-b2e5-eb49d4736909"
        let sessionFiles = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: sessionID,
            customTitle: "Reviewing display data design and code commits",
            userText: "<timestamp>Friday, May 8, 2026, 3:53 PM (UTC+5:30)</timestamp>\nPlease review this diff.",
            assistantFragments: ["I checked the ", "**transition**", " path."],
            modelID: "copilot/gpt-5.1-codex-max",
            includeJSONSnapshot: false
        )

        let records = try VSCodeCopilotAdapter(root: workspaceStorageRoot).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceSessionId, sessionID)
        XCTAssertEqual(records[0].workspacePath, workspacePath)
        XCTAssertEqual(records[0].projectName, "newton5")
        XCTAssertEqual(records[0].title, "Reviewing display data design and code commits")
        XCTAssertEqual(records[0].firstUserPreview, "Please review this diff.")
        XCTAssertEqual(records[0].firstAssistantPreview, "I checked the transition path.")
        XCTAssertEqual(records[0].conversationModel, "gpt-5.1-codex-max")
        XCTAssertEqual(records[0].resumeKind, .openInVSCode)
        XCTAssertEqual(
            records[0].rawTranscriptPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            sessionFiles.jsonlURL.standardizedFileURL.path
        )
    }

    func testVSCodeAdapterPrefersJSONSnapshotOverJSONLPatchWhenBothExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceStorageRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "f2bb8379-47d1-4ea3-a081-7c4d78a2d53d"
        let sessionFiles = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: sessionID,
            customTitle: "Prefer snapshot JSON when both chat session files exist",
            userText: "Review the snapshot precedence.",
            assistantFragments: ["The ", "**JSON**", " snapshot wins."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: true
        )

        let records = try VSCodeCopilotAdapter(root: workspaceStorageRoot).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceSessionId, sessionID)
        XCTAssertEqual(records[0].title, "Prefer snapshot JSON when both chat session files exist")
        XCTAssertEqual(records[0].firstUserPreview, "Review the snapshot precedence.")
        XCTAssertEqual(records[0].firstAssistantPreview, "The JSON snapshot wins.")
        XCTAssertEqual(
            records[0].rawTranscriptPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            sessionFiles.jsonURL?.standardizedFileURL.path
        )
    }

    func testVSCodeAdapterPrefersChatSessionsOverLegacyTranscriptForSameSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceStorageRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        let legacyTranscriptsDirectory = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTranscriptsDirectory, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "2e75ec67-4ee3-4334-9623-f6d84bdd4117"
        try createVSCodeLegacyTranscript(
            in: legacyTranscriptsDirectory,
            sessionID: sessionID,
            userText: "This is the legacy transcript.",
            assistantText: "Legacy assistant reply."
        )
        let sessionFiles = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: sessionID,
            customTitle: "Prefer chat sessions over legacy transcripts",
            userText: "Use the richer chat session.",
            assistantFragments: ["Chat ", "**session**", " content wins."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: true
        )

        let records = try VSCodeCopilotAdapter(root: workspaceStorageRoot).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceSessionId, sessionID)
        XCTAssertEqual(records[0].title, "Prefer chat sessions over legacy transcripts")
        XCTAssertEqual(records[0].firstUserPreview, "Use the richer chat session.")
        XCTAssertEqual(records[0].firstAssistantPreview, "Chat session content wins.")
        XCTAssertEqual(
            records[0].rawTranscriptPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            sessionFiles.jsonURL?.standardizedFileURL.path
        )
    }

    func testVSCodeAdapterRefreshesChangedChatSessionMetadataAcrossRepeatedDiscover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceStorageRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "cache-refresh-session"
        _ = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: sessionID,
            customTitle: "Before refresh invalidation",
            userText: "Original user prompt.",
            assistantFragments: ["Original ", "**assistant**", " response."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: false
        )

        let adapter = VSCodeCopilotAdapter(root: workspaceStorageRoot)
        let firstRecords = try adapter.discover()

        XCTAssertEqual(firstRecords.count, 1)
        XCTAssertEqual(firstRecords[0].title, "Before refresh invalidation")
        XCTAssertEqual(firstRecords[0].firstUserPreview, "Original user prompt.")
        XCTAssertEqual(firstRecords[0].firstAssistantPreview, "Original assistant response.")

        _ = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: sessionID,
            customTitle: "After refresh invalidation with updated title",
            userText: "Updated user prompt with more text.",
            assistantFragments: ["Updated ", "**assistant**", " response with more detail."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: false
        )

        let secondRecords = try adapter.discover()

        XCTAssertEqual(secondRecords.count, 1)
        XCTAssertEqual(secondRecords[0].title, "After refresh invalidation with updated title")
        XCTAssertEqual(secondRecords[0].firstUserPreview, "Updated user prompt with more text.")
        XCTAssertEqual(secondRecords[0].firstAssistantPreview, "Updated assistant response with more detail.")
    }

    func testVSCodeAdapterDetectsAddedAndDeletedChatSessionsAcrossRepeatedDiscover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceStorageRoot = directory.appendingPathComponent("Code/User/workspaceStorage", isDirectory: true)
        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("workspace-id", isDirectory: true)
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/repos/newton5"
        try """
        {
          "folder": "file://\(workspacePath)"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = VSCodeCopilotAdapter(root: workspaceStorageRoot)
        let firstSessionID = "cache-add-delete-1"
        let secondSessionID = "cache-add-delete-2"

        let firstSessionFiles = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: firstSessionID,
            customTitle: "First session",
            userText: "First session prompt.",
            assistantFragments: ["First ", "**assistant**", " reply."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: false
        )

        XCTAssertEqual(try adapter.discover().map(\.sourceSessionId), [firstSessionID])

        _ = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: secondSessionID,
            customTitle: "Second session",
            userText: "Second session prompt.",
            assistantFragments: ["Second ", "**assistant**", " reply."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: false
        )

        XCTAssertEqual(
            Set(try adapter.discover().map(\.sourceSessionId)),
            Set([firstSessionID, secondSessionID])
        )

        try FileManager.default.removeItem(at: firstSessionFiles.jsonlURL)

        XCTAssertEqual(try adapter.discover().map(\.sourceSessionId), [secondSessionID])
    }

    func testTranscriptLoaderBuildsVSCodeChatSessionTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let chatSessionsDirectory = directory.appendingPathComponent("chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatSessionsDirectory, withIntermediateDirectories: true)

        let sessionFiles = try createVSCodeChatSessionFiles(
            in: chatSessionsDirectory,
            sessionID: "vscode-chat-1",
            customTitle: "Jira MCP server OAuth SETUP assistance",
            userText: "Please help me set up Jira OAuth.",
            assistantFragments: ["Open ", "**Settings**", " and add the callback URL."],
            modelID: "copilot/gpt-5.4",
            includeJSONSnapshot: false
        )

        let record = SessionRecord(
            source: .vscodeCopilot,
            sourceSessionId: "vscode-chat-1",
            workspacePath: "/Users/pisoni/repos/newton5",
            projectName: "newton5",
            branch: nil,
            conversationModel: nil,
            startedAt: nil,
            updatedAt: nil,
            title: "Jira MCP server OAuth SETUP assistance",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: sessionFiles.jsonlURL.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint-vscode-chat",
            resumeKind: .openInVSCode,
            resumePayload: "/Users/pisoni/repos/newton5",
            isNewtonProject: true
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)
        let searchableEntries = try TranscriptPreviewExtractor.searchableEntries(for: record)

        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertFalse(transcript.timestampsAreComplete)
        XCTAssertNotNil(transcript.timestampNotice)
        XCTAssertEqual(transcript.entries[0].title, "User")
        XCTAssertEqual(transcript.entries[0].body, "Please help me set up Jira OAuth.")
        XCTAssertNotNil(transcript.entries[0].timestamp)
        XCTAssertEqual(transcript.entries[1].title, "Assistant")
        XCTAssertEqual(transcript.entries[1].body, "Open Settings and add the callback URL.")
        XCTAssertNil(transcript.entries[1].timestamp)
        XCTAssertEqual(
            searchableEntries.map(\.text),
            ["Please help me set up Jira OAuth.", "Open Settings and add the callback URL."]
        )
    }
}

private func createVSCodeChatSessionFiles(
    in directory: URL,
    sessionID: String,
    customTitle: String,
    userText: String,
    assistantFragments: [String],
    modelID: String,
    includeJSONSnapshot: Bool = true
) throws -> (jsonURL: URL?, jsonlURL: URL) {
    var root: [String: Any] = [
        "version": 3,
        "responderUsername": "GitHub Copilot",
        "initialLocation": "panel",
        "sessionId": sessionID,
        "creationDate": 1_769_787_480_334,
        "requests": [
            [
                "requestId": "request-1",
                "timestamp": 1_769_787_885_941,
                "modelId": modelID,
                "message": [
                    "text": userText
                ],
                "response": assistantFragments.map { ["value": $0] }
            ]
        ]
    ]
    root["customTitle"] = customTitle

    let jsonURL: URL?
    if includeJSONSnapshot {
        let snapshotURL = directory.appendingPathComponent("\(sessionID).json")
        let jsonData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: snapshotURL)
        jsonURL = snapshotURL
    } else {
        jsonURL = nil
    }

    let jsonlURL = directory.appendingPathComponent("\(sessionID).jsonl")
    let patchRecords: [[String: Any]] = [
        [
            "kind": 0,
            "v": [
                "version": 3,
                "creationDate": 1_769_787_480_334,
                "initialLocation": "panel",
                "responderUsername": "GitHub Copilot",
                "sessionId": sessionID,
                "hasPendingEdits": false,
                "requests": [],
                "pendingRequests": [],
                "inputState": [
                    "attachments": [],
                    "selectedModel": [
                        "identifier": modelID
                    ]
                ]
            ]
        ],
        [
            "kind": 1,
            "k": ["customTitle"],
            "v": customTitle
        ],
        [
            "kind": 2,
            "k": ["requests"],
            "v": [[
                "requestId": "request-1",
                "timestamp": 1_769_787_885_941,
                "modelId": modelID,
                "message": [
                    "text": userText
                ],
                "response": []
            ]]
        ],
        [
            "kind": 2,
            "k": ["requests", 0, "response"],
            "v": assistantFragments.map { ["value": $0] }
        ]
    ]
    let jsonlText = try patchRecords
        .map { record in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        .joined(separator: "\n")
    try jsonlText.write(to: jsonlURL, atomically: true, encoding: .utf8)

    return (jsonURL, jsonlURL)
}

private func createVSCodeLegacyTranscript(
    in directory: URL,
    sessionID: String,
    userText: String,
    assistantText: String
) throws {
    let transcriptURL = directory.appendingPathComponent("\(sessionID).jsonl")
    let events: [[String: Any]] = [
        [
            "id": "session-start",
            "type": "session.start",
            "data": [
                "sessionId": sessionID,
                "startTime": "2026-05-08T10:00:00Z"
            ]
        ],
        [
            "id": "user-message",
            "type": "user.message",
            "data": [
                "content": userText
            ]
        ],
        [
            "id": "assistant-message",
            "type": "assistant.message",
            "data": [
                "content": assistantText
            ]
        ]
    ]

    let transcriptText = try events
        .map { event in
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        .joined(separator: "\n")
    try transcriptText.write(to: transcriptURL, atomically: true, encoding: .utf8)
}
