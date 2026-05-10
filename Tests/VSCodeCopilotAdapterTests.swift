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
            modelID: "copilot/gpt-5.1-codex-max"
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
            sessionFiles.jsonURL.standardizedFileURL.path
        )
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
            modelID: "copilot/gpt-5.4"
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
            rawTranscriptPath: sessionFiles.jsonURL.path,
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
    modelID: String
) throws -> (jsonURL: URL, jsonlURL: URL) {
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

    let jsonURL = directory.appendingPathComponent("\(sessionID).json")
    let jsonData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try jsonData.write(to: jsonURL)

    let jsonlURL = directory.appendingPathComponent("\(sessionID).jsonl")
    let wrappedData = try JSONSerialization.data(withJSONObject: ["kind": 0, "v": root], options: [.sortedKeys])
    try wrappedData.write(to: jsonlURL)

    return (jsonURL, jsonlURL)
}
