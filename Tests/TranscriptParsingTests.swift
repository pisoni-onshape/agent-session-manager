import Foundation
import XCTest
@testable import AgentSessionManager

final class TranscriptParsingTests: XCTestCase {
    func testEventTranscriptExtractionFindsSessionAndPreview() throws {
        let url = try temporaryFile(
            named: "event.jsonl",
            contents: """
            {"type":"session.start","data":{"sessionId":"abc-123","startTime":"2026-05-07T06:18:14.516Z"}}
            {"type":"user.message","data":{"content":"<user_query>Find the terminal drag/drop bug.</user_query>"}}
            {"type":"assistant.message","data":{"content":"I’ll trace the terminal initialization path first."}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: url)
        XCTAssertEqual(preview.sessionId, "abc-123")
        XCTAssertEqual(preview.firstUser, "Find the terminal drag/drop bug.")
        XCTAssertEqual(preview.firstAssistant, "I’ll trace the terminal initialization path first.")
        XCTAssertNotNil(preview.startedAt)
    }

    func testCursorTranscriptExtractionFindsFirstTurns() throws {
        let url = try temporaryFile(
            named: "cursor.jsonl",
            contents: """
            {"role":"user","message":{"content":[{"type":"text","text":"Please explain how body edges become quads."}]}}
            {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the edge rendering pipeline first."}]}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractCursorTranscript(from: url)
        XCTAssertEqual(preview.firstUser, "Please explain how body edges become quads.")
        XCTAssertEqual(preview.firstAssistant, "I’ll inspect the edge rendering pipeline first.")
    }

    func testTranscriptLoaderBuildsTimestampedEventTranscript() throws {
        let url = try temporaryFile(
            named: "event-full.jsonl",
            contents: """
            {"type":"session.start","data":{"sessionId":"abc-123","producer":"copilot-agent","copilotVersion":"1.0.43","startTime":"2026-05-07T06:18:14.516Z"},"id":"evt-1","timestamp":"2026-05-07T06:18:14.516Z"}
            {"type":"session.model_change","data":{"newModel":"copilot/gpt-5.4"},"id":"evt-2","timestamp":"2026-05-07T06:18:15.000Z"}
            {"type":"user.message","data":{"content":"<user_query>Find the terminal drag/drop bug.</user_query>"},"id":"evt-3","timestamp":"2026-05-07T06:19:00.000Z"}
            {"type":"tool.execution_start","data":{"toolCallId":"call-1","toolName":"view","arguments":{"path":"/tmp/file.swift"}},"id":"evt-4","timestamp":"2026-05-07T06:19:05.000Z"}
            {"type":"tool.execution_complete","data":{"toolCallId":"call-1","success":true,"result":{"content":"done"}},"id":"evt-5","timestamp":"2026-05-07T06:19:06.000Z"}
            {"type":"assistant.message","data":{"content":"I’ll trace the terminal initialization path first."},"id":"evt-6","timestamp":"2026-05-07T06:19:10.000Z"}
            """
        )

        let record = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "abc-123",
            workspacePath: nil,
            projectName: "agent-session-manager",
            branch: nil,
            conversationModel: nil,
            startedAt: nil,
            updatedAt: nil,
            title: "Find terminal bug",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: url.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            resumeKind: .copilotConnect,
            resumePayload: "abc-123",
            isNewtonProject: false
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)
        XCTAssertEqual(transcript.entries.count, 6)
        XCTAssertTrue(transcript.timestampsAreComplete)
        XCTAssertNil(transcript.timestampNotice)
        XCTAssertEqual(transcript.entries[1].body, "gpt-5.4")
        XCTAssertEqual(transcript.entries[3].title, "Started view")
        XCTAssertEqual(transcript.entries[4].title, "Completed view")
        XCTAssertEqual(transcript.entries[5].body, "I’ll trace the terminal initialization path first.")

        let displayItems = transcript.displayItems
        XCTAssertEqual(displayItems.count, 4)
        guard case let .collapsedEvents(_, leadingEvents) = displayItems[0] else {
            return XCTFail("Expected leading non-chat entries to be collapsed.")
        }
        XCTAssertEqual(leadingEvents.count, 2)
        guard case let .collapsedEvents(_, toolEvents) = displayItems[2] else {
            return XCTFail("Expected tool entries to be collapsed.")
        }
        XCTAssertEqual(toolEvents.count, 2)
    }

    func testTranscriptLoaderBuildsCursorTranscriptWithoutTimestamps() throws {
        let url = try temporaryFile(
            named: "cursor-full.jsonl",
            contents: """
            {"role":"user","message":{"content":[{"type":"text","text":"Please explain how body edges become quads."}]}}
            {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the edge rendering pipeline first."}]}}
            """
        )

        let record = SessionRecord(
            source: .cursor,
            sourceSessionId: "cursor-1",
            workspacePath: nil,
            projectName: "newton",
            branch: nil,
            conversationModel: nil,
            startedAt: nil,
            updatedAt: nil,
            title: "Cursor transcript",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: url.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            resumeKind: .revealPath,
            resumePayload: url.path,
            isNewtonProject: true
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)
        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertFalse(transcript.timestampsAreComplete)
        XCTAssertNotNil(transcript.timestampNotice)
        XCTAssertNil(transcript.entries[0].timestamp)
        XCTAssertEqual(transcript.entries[0].title, "User")
        XCTAssertEqual(transcript.entries[1].title, "Assistant")
    }

    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
